package music.mu.android

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import mu.core.LocalFolderProvider
import mu.core.Scanner
import mu.core.SyncEngine
import java.io.File

/**
 * 音樂庫狀態：選定本地資料夾 → SyncEngine 首掃/增量 → 專輯/音軌/清單 UI 狀態。
 * 上次資料夾存 SharedPreferences（重開 app 自動重掃；Room 持久化接上後改存 DB）。
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

    private var root: File? = null
    private var engine: SyncEngine? = null

    fun open(root: File) {
        this.root = root
        val e = engine ?: SyncEngine(LocalFolderProvider(root)).also { engine = it }
        prefs().edit().putString(KEY_ROOT, root.absolutePath).apply()
        viewModelScope.launch(Dispatchers.IO) {
            _state.value = _state.value.copy(
                scanning = true, rootPath = root.absolutePath)
            val report = e.sync()
            val tracks = report.tracks.values
                .filter { it.available }
                .map { it.track }
                .sortedWith(compareBy { it.path })
            val byId = tracks.associateBy { it.id }
            val resolved = e.resolvedItems(report)
            _state.value = UiState(
                rootPath = root.absolutePath,
                scanning = false,
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

    /** 增量重掃（外部改檔後；delta：rev 未變的檔案不重讀）。 */
    fun rescan() {
        root?.let { open(it) }
    }

    /** 自動重開上次的資料夾（MainActivity 啟動時呼叫一次）。 */
    fun reopenLast() {
        if (root != null) return
        prefs().getString(KEY_ROOT, null)?.let { path ->
            val f = File(path)
            if (f.isDirectory) open(f)
        }
    }

    private fun prefs() = getApplication<Application>()
        .getSharedPreferences("mu_library", Context.MODE_PRIVATE)

    private companion object { const val KEY_ROOT = "root" }
}
