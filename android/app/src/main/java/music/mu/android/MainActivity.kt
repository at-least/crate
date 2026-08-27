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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items as listItems
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
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

@androidx.compose.runtime.Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
fun MuApp(vm: LibraryViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    val context = LocalContext.current
    var selectedAlbum by remember { mutableStateOf<String?>(null) }
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

    Scaffold(topBar = { TopAppBar(title = { Text("Mu") }) }) { pad ->
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

                selectedAlbum == null -> LazyVerticalGrid(GridCells.Adaptive(150.dp)) {
                    items(state.albums, key = { it.id }) { album ->
                        Card(
                            Modifier.padding(8.dp).fillMaxWidth().clickable {
                                selectedAlbum = album.id
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

                else -> {
                    val album = state.albums.first { it.id == selectedAlbum }
                    val tracks = state.tracksByAlbum[album.id].orEmpty()
                    Column(Modifier.fillMaxSize()) {
                        Text(
                            "${album.name} — ${album.albumArtist}",
                            Modifier.padding(16.dp),
                            style = MaterialTheme.typography.titleMedium,
                        )
                        LazyColumn(Modifier.weight(1f)) {
                            listItems(tracks, key = { it.id }) { t ->
                                Row(
                                    Modifier.fillMaxWidth().clickable {
                                        controller?.let { c ->
                                            c.setMediaItems(
                                                PlaybackService.mediaItems(tracks, state.rootPath!!))
                                            c.seekTo(tracks.indexOf(t), 0)
                                            c.prepare()
                                            c.play()
                                        }
                                        playerSheet = PlayerBarState(t.title)
                                    }.padding(16.dp, 8.dp),
                                ) {
                                    Text(
                                        (t.trackNo?.let { "$it. " } ?: "") + t.title,
                                        Modifier.weight(1f),
                                    )
                                    Text(
                                        t.durationMs?.let { ms ->
                                            "%d:%02d".format(ms / 60000, ms / 1000 % 60)
                                        } ?: "",
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                }
                            }
                        }
                        playerSheet?.let { PlayerBar(controller, it.title) }
                    }
                }
            }
        }
    }
}

data class PlayerBarState(val title: String)
