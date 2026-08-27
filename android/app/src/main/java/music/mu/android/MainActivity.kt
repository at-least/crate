package music.mu.android

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items as listItems
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import mu.core.Scanner
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                MuApp()
            }
        }
    }
}

/** 內容區選擇：null = 專輯網格；album id / playlist 名稱 = 該清單音軌。 */
private sealed interface View {
    data object Library : View
    data class Album(val id: String) : View
    data class Playlist(val name: String) : View
}

@androidx.compose.runtime.Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
fun MuApp(vm: LibraryViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    val context = LocalContext.current
    var view by remember { mutableStateOf<View>(View.Library) }
    var playerSheet by remember { mutableStateOf<PlayerBarState?>(null) }

    // 本地資料夾讀取權（API 33+ READ_MEDIA_AUDIO；舊版 READ_EXTERNAL_STORAGE）
    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()) { }
    val pickLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri?.let { u ->
            // SAF tree → 實體路徑（僅支援 primary storage 的 tree；本機測試情境）
            val docId = android.provider.DocumentsContract.getTreeDocumentId(u)
            val path = docId.removePrefix("primary:")
            vm.open(File("/storage/emulated/0/$path"))
        }
    }
    fun requestAndPick() {
        val perms = if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        permLauncher.launch(perms)
        pickLauncher.launch(null)
    }

    val controller = rememberPlayerController()
    val pinManager = (context.applicationContext as MuApp).pinManager

    fun play(tracks: List<Scanner.Track>, startIndex: Int, title: String) {
        controller?.let { c ->
            val rootPath = state.rootPath!!
            fun resolveFile(t: Scanner.Track): File =
                pinManager.pinnedFile(t.id) ?: File(rootPath, t.path)
            c.setMediaItems(PlaybackService.mediaItems(tracks, ::resolveFile))
            c.seekTo(startIndex, 0)
            c.prepare()
            c.play()
        }
        playerSheet = PlayerBarState(title)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Mu") },
                navigationIcon = {
                    if (view !is View.Library) {
                        IconButton(onClick = { view = View.Library }) {
                            androidx.compose.material3.Icon(
                                Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                        }
                    }
                },
                actions = {
                    if (state.rootPath != null) {
                        IconButton(onClick = { vm.rescan() }) {
                            androidx.compose.material3.Icon(
                                Icons.Default.Refresh, contentDescription = "重掃")
                        }
                    }
                },
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            when {
                state.scanning -> Column(
                    Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) { CircularProgressIndicator(); Text("掃描中…") }

                state.rootPath == null -> Column(
                    Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("選擇你的音樂資料夾", style = MaterialTheme.typography.titleMedium)
                    Button(onClick = { requestAndPick() }, modifier = Modifier.padding(16.dp)) {
                        Text("選擇資料夾")
                    }
                }

                view is View.Playlist -> {
                    val pl = state.playlists.first {
                        it.name == (view as View.Playlist).name
                    }
                    TrackList(
                        title = pl.name,
                        subtitle = "${pl.tracks.size} 軌（清單）",
                        tracks = pl.tracks,
                        onPlay = { t, i -> play(pl.tracks, i, t.title) },
                    )
                    playerSheet?.let { PlayerBar(controller, it.title) }
                }

                view is View.Album -> {
                    // unpin 後專輯可能整個消失（全離線軌被濾掉）→ 回庫列表，別讓 first{} 炸
                    val album = state.albums.firstOrNull { it.id == (view as View.Album).id }
                    if (album == null) {
                        androidx.compose.runtime.LaunchedEffect(album) { view = View.Library }
                        Text("專輯已無可播軌", Modifier.padding(16.dp))
                    } else {
                        val tracks = state.tracksByAlbum[album.id].orEmpty()
                        val states = tracks.map { state.pinStates[it.id] }
                        val done = states.count { it == PinManager.PinState.DONE }
                        val pending = states.count {
                            it == PinManager.PinState.WANTED || it == PinManager.PinState.DOWNLOADING
                        }
                        val failed = states.count { it == PinManager.PinState.FAILED }
                        Column(Modifier.fillMaxSize()) {
                            AssistChip(
                                onClick = {
                                    if (tracks.isNotEmpty() && done == tracks.size) {
                                        vm.unpinAlbum(album.id)
                                    } else {
                                        vm.pinAlbum(album.id)
                                    }
                                },
                                label = {
                                    Text(
                                        when {
                                            tracks.isEmpty() -> "無軌"
                                            done == tracks.size -> "已釘選（${tracks.size} 軌，點擊取消）"
                                            done + pending > 0 ->
                                                "釘選中 $done/${tracks.size}" +
                                                    if (failed > 0) " · $failed 失敗" else ""
                                            failed > 0 -> "釘選失敗 $failed/${tracks.size}（點擊重試）"
                                            else -> "釘選離線（${tracks.size} 軌）"
                                        },
                                    )
                                },
                                modifier = Modifier.padding(start = 16.dp, top = 8.dp),
                            )
                            TrackList(
                                title = album.name,
                                subtitle = album.albumArtist +
                                    (album.year?.let { " · $it" } ?: ""),
                                tracks = tracks,
                                offlineIds = state.pinStates
                                    .filterValues { it == PinManager.PinState.DONE }.keys,
                                onPlay = { t, i -> play(tracks, i, t.title) },
                            )
                        }
                        playerSheet?.let { PlayerBar(controller, it.title) }
                    }
                }

                else -> Column(Modifier.fillMaxSize()) {
                    if (state.playlists.isNotEmpty()) {
                        LazyRow(
                            Modifier.padding(horizontal = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            listItems(state.playlists, key = { it.name }) { pl ->
                                AssistChip(onClick = { view = View.Playlist(pl.name) },
                                    label = { Text(pl.name) })
                            }
                        }
                    }
                    LazyVerticalGrid(
                        GridCells.Adaptive(150.dp), Modifier.weight(1f)) {
                        items(state.albums, key = { it.id }) { album ->
                            Card(
                                Modifier.padding(8.dp).fillMaxWidth().clickable {
                                    view = View.Album(album.id)
                                },
                            ) {
                                Column(Modifier.padding(12.dp)) {
                                    Text(album.name, style = MaterialTheme.typography.titleMedium)
                                    Text(album.albumArtist, style = MaterialTheme.typography.bodySmall)
                                    Text(
                                        "${album.trackCount} 軌" +
                                            (album.year?.let { " · $it" } ?: ""),
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 音軌清單（專輯/playlist 共用）。 */
@androidx.compose.runtime.Composable
private fun TrackList(
    title: String,
    subtitle: String,
    tracks: List<Scanner.Track>,
    offlineIds: Set<String> = emptySet(),
    onPlay: (Scanner.Track, Int) -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        Text(title, Modifier.padding(16.dp), style = MaterialTheme.typography.titleMedium)
        Text(subtitle, Modifier.padding(horizontal = 16.dp),
            style = MaterialTheme.typography.bodySmall)
        LazyColumn(Modifier.weight(1f)) {
            listItems(tracks, key = { it.id }) { t ->
                Row(
                    Modifier.fillMaxWidth().clickable {
                        onPlay(t, tracks.indexOf(t))
                    }.padding(16.dp, 8.dp),
                ) {
                    Text(
                        (t.trackNo?.let { "$it. " } ?: "") + t.title,
                        Modifier.weight(1f),
                    )
                    if (t.id in offlineIds) {
                        Text("離線", Modifier.padding(end = 8.dp),
                            style = MaterialTheme.typography.bodySmall)
                    }
                    Text(
                        t.durationMs?.let { ms ->
                            "%d:%02d".format(ms / 60000, ms / 1000 % 60)
                        } ?: "",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}

data class PlayerBarState(val title: String)
