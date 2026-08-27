package music.mu.android

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import music.mu.android.db.LibraryDao
import mu.core.LocalFolderProvider
import mu.core.Scanner
import mu.core.SyncEngine
import java.io.File

/**
 * 音樂庫狀態：SyncEngine 首掃/增量 → 專輯/音軌/清單 UI 狀態。
 * 索引與庫根持久化於 Room（schema.sql v0.2）：冷啟動先還原（即時 UI）再 delta 同步
 * （rev 未變不重讀），每輪 sync 後落庫。換資料夾 = 換新引擎 + DB 全量置換（單庫語意）。
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
    ) {
        data class PlaylistUi(val name: String, val tracks: List<Scanner.Track>)
    }

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state

    private val dao: LibraryDao = (app as MuApp).database.libraryDao()
    private val syncMutex = Mutex()

    private var root: File? = null
    private var engine: SyncEngine? = null

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

    /** 需持有 [syncMutex] 執行。 */
    private suspend fun syncLocked(rootFile: File, hydrate: Boolean) {
        if (this.root?.absolutePath != rootFile.absolutePath) {
            val e = SyncEngine(LocalFolderProvider(rootFile))
            engine = e
            root = rootFile
            if (hydrate) {
                dao.loadEngineState()?.let { st ->
                    e.restoreState(st)
                    publishUi(rootFile, e, scanning = true) // 還原即顯示，不等地圖 walk
                }
            }
        }
        val e = engine!!
        _state.value = _state.value.copy(scanning = true, rootPath = rootFile.absolutePath)
        e.sync()
        publishUi(rootFile, e, scanning = false)
        dao.replaceLibrary(rootFile.absolutePath, e.exportState())
    }

    /** 由引擎當前索引導出 UI 狀態（還原後與 sync 後共用）。 */
    private fun publishUi(rootFile: File, e: SyncEngine, scanning: Boolean) {
        val st = e.exportState()
        val report = SyncEngine.SyncReport(
            emptyList(), emptyList(), st.tracks, st.playlists, st.errors)
        val tracks = report.tracks.values
            .filter { it.available }
            .map { it.track }
            .sortedWith(compareBy { it.path })
        val byId = tracks.associateBy { it.id }
        val resolved = e.resolvedItems(report)
        _state.value = UiState(
            rootPath = rootFile.absolutePath,
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
        )
    }
}
