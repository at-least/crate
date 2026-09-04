package at.least.crate.android

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import at.least.crate.android.db.LibraryDao
import at.least.crate.android.db.CrateDatabase
import crate.core.EngineState
import crate.core.LocalFolderProvider
import crate.core.Scanner
import crate.core.SyncEngine
import java.io.File

/**
 * 音樂庫狀態：SyncEngine 首掃/增量 → 專輯/音軌/清單 UI 狀態。
 * 索引與庫根持久化於 Room（schema.sql v0.2）：冷啟動先還原（即時 UI）再 delta 同步
 * （rev 未變不重讀），每輪 sync 後落庫。換資料夾 = 換新引擎 + DB 全量置換（單庫語意）。
 * 釘選：available 或 pinned-done 的軌都進專輯清單（來源消失仍可播）；狀態由 PinManager 推送。
 */
class LibraryViewModel(app: Application) : AndroidViewModel(app) {

    data class UiState(
        val rootPath: String? = null,
        val scanning: Boolean = false,
        val albums: List<Scanner.Album> = emptyList(),
        val tracksByAlbum: Map<String, List<Scanner.Track>> = emptyMap(),
        val tracksById: Map<String, Scanner.Track> = emptyMap(),
        /** playlist → 依序音軌（未解析的 ref 略過）。 */
        val playlists: List<PlaylistUi> = emptyList(),
        /** trackId → 釘選狀態。 */
        val pinStates: Map<String, PinManager.PinState> = emptyMap(),
    ) {
        data class PlaylistUi(val name: String, val tracks: List<Scanner.Track>)
    }

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state

    private val database: CrateDatabase = (app as CrateApp).database
    private val dao: LibraryDao = database.libraryDao()
    private val pinManager: PinManager = (app as CrateApp).pinManager
    private val syncMutex = Mutex()

    @Volatile private var root: File? = null
    @Volatile private var engine: SyncEngine? = null

    /** 上一輪索引快照（rebuildUi 用；pin 變動不需重掃）。 */
    @Volatile private var lastIndex: EngineState? = null

    init {
        viewModelScope.launch(Dispatchers.IO) {
            syncMutex.lock()
            try {
                if (root == null) { // 使用者已手動開庫則不覆蓋
                    dao.root()?.let(::File)?.takeIf { it.isDirectory }
                        ?.let { syncLocked(it, hydrate = true) }
                }
            } finally {
                syncMutex.unlock()
            }
        }
        viewModelScope.launch {
            pinManager.pins.collect { rebuildUi() }
        }
    }

    fun open(root: File) {
        viewModelScope.launch(Dispatchers.IO) {
            syncMutex.lock() // 排隊而非丟棄：冷啟動還原中選新資料夾，等這輪完照樣生效
            try {
                syncLocked(root, hydrate = false)
            } finally {
                syncMutex.unlock()
            }
        }
    }

    /** 增量重掃（外部改檔後；delta：rev 未變的檔案不重讀）。 */
    fun rescan() {
        root?.let { open(it) }
    }

    /** 釘選整張專輯（可見軌 = available 或已釘）；rev 取自引擎索引（sync 後重驗用）。 */
    fun pinAlbum(albumId: String) {
        val reqs = _state.value.tracksByAlbum[albumId].orEmpty().map { t ->
            PinManager.PinReq(t.id, lastIndex?.tracks?.get(t.path)?.rev ?: "")
        }
        pinManager.pin(reqs)
    }

    fun unpinAlbum(albumId: String) {
        val ids = _state.value.tracksByAlbum[albumId].orEmpty().map { it.id }
        pinManager.unpin(ids)
    }

    /** 需持有 [syncMutex] 執行。 */
    private suspend fun syncLocked(rootFile: File, hydrate: Boolean) {
        if (this.root?.absolutePath != rootFile.absolutePath) {
            val e = SyncEngine(LocalFolderProvider(rootFile))
            engine = e
            root = rootFile
            pinManager.setRoot(rootFile) // 換庫記錄休眠（同庫冷啟動不清；suspend 等待完成）
            if (hydrate) {
                dao.loadEngineState()?.let { st ->
                    e.restoreState(st)
                    lastIndex = st
                    rebuildUi(scanning = true) // 還原即顯示，不等目錄 walk
                }
            }
        }
        val e = engine!!
        _state.value = _state.value.copy(scanning = true, rootPath = rootFile.absolutePath)
        try {
            e.sync()
        } catch (ex: crate.core.ProviderException) {
            // 本地 provider 不拋；雲端失敗 = 本輪跳過，狀態不動（sync-rules §3.2-8）
        }
        lastIndex = e.exportState()
        // done 釘選的來源 rev 已變 → 重抓（hash 即終極 rev；來源消失的軌不動）
        pinManager.revalidate(lastIndex!!.tracks.mapValues { it.value.rev })
        rebuildUi(scanning = false)
        dao.replaceLibrary(rootFile.absolutePath, lastIndex!!)
    }

    /** 由 lastIndex + pin 狀態導出 UI（sync 後與 pin 變動共用；不需重掃）。 */
    private fun rebuildUi(scanning: Boolean = _state.value.scanning) {
        val st = lastIndex ?: return
        val rootPath = root?.absolutePath ?: return
        val pins = pinManager.pins.value
        val report = SyncEngine.SyncReport(
            emptyList(), emptyList(), st.tracks, st.playlists, st.errors)
        // 專輯清單：available 或 pinned-done（來源消失仍可播）
        val tracks = report.tracks.values
            .filter { it.available || pins[it.track.id] == PinManager.PinState.DONE }
            .map { it.track }
            .sortedWith(compareBy { it.path })
        val byId = tracks.associateBy { it.id }
        val resolved = engine?.resolvedItems(report).orEmpty()
        _state.value = UiState(
            rootPath = rootPath,
            scanning = scanning,
            albums = Scanner.groupAlbums(tracks)
                .sortedWith(compareBy({ it.albumArtist }, { it.name })),
            tracksByAlbum = tracks.groupBy { it.albumId },
            tracksById = byId,
            playlists = resolved.keys.sorted().mapNotNull { p ->
                val raw = report.playlists[p] ?: return@mapNotNull null
                val ts = resolved.getValue(p).mapNotNull { byId[it] }
                UiState.PlaylistUi(raw.name, ts)
            },
            pinStates = pins,
        )
    }
}
