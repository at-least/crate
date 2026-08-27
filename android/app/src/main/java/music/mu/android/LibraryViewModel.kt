package music.mu.android

import android.app.Application
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
 * 音樂庫狀態：選定本地資料夾 → SyncEngine 首掃/增量 → 專輯/音軌 UI 狀態。
 * v0：索引在記憶體（ViewModel 存活期間）；Room 持久化下一步接。
 */
class LibraryViewModel(app: Application) : AndroidViewModel(app) {

    data class UiState(
        val rootPath: String? = null,
        val scanning: Boolean = false,
        val albums: List<Scanner.Album> = emptyList(),
        val tracksByAlbum: Map<String, List<Scanner.Track>> = emptyMap(),
        val playlistPaths: List<String> = emptyList(),
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state

    private var root: File? = null
    private var engine: SyncEngine? = null

    fun open(root: File) {
        this.root = root
        val e = engine ?: SyncEngine(LocalFolderProvider(root)).also { engine = it }
        viewModelScope.launch(Dispatchers.IO) {
            _state.value = _state.value.copy(
                scanning = true, rootPath = root.absolutePath)
            val report = e.sync()
            val tracks = report.tracks.values
                .filter { it.available }
                .map { it.track }
                .sortedWith(compareBy { it.path })
            _state.value = UiState(
                rootPath = root.absolutePath,
                scanning = false,
                albums = Scanner.groupAlbums(tracks)
                    .sortedWith(compareBy({ it.albumArtist }, { it.name })),
                tracksByAlbum = tracks.groupBy { it.albumId },
                playlistPaths = report.playlists.keys.sorted(),
            )
        }
    }

    /** 增量重掃（外部改檔後）。 */
    fun rescan() {
        root?.let { open(it) }
    }
}
