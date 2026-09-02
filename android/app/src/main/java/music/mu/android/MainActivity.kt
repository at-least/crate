package music.mu.android

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import music.mu.android.ui.AlbumArt
import music.mu.android.ui.MuDimens
import music.mu.android.ui.MuTheme
import mu.core.Scanner
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MuTheme {
                MuRoot()
            }
        }
    }
}

/** 內容區選擇：Library = 專輯/清單總覽；Album / Playlist = 該清單音軌。 */
private sealed interface View {
    data object Library : View
    data class Album(val id: String) : View
    data class Playlist(val name: String) : View
}

private enum class LibraryTab(val label: String) {
    ALBUMS("專輯"), PLAYLISTS("清單")
}

/**
 * 主畫面。資訊架構與 iOS 對齊：
 * 資料庫（分段：專輯／清單）→ 專輯/清單詳情 → 底部迷你播放列。
 * 搜尋中忽略分段、兩類一起過濾；沒有清單時不顯示分段控制。
 */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun MuRoot(vm: LibraryViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    val context = LocalContext.current
    var view by remember { mutableStateOf<View>(View.Library) }
    var query by remember { mutableStateOf("") }
    var tab by remember { mutableStateOf(LibraryTab.ALBUMS) }

    // 本地資料夾讀取權（API 33+ READ_MEDIA_AUDIO；舊版 READ_EXTERNAL_STORAGE）
    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()) { }
    val pickLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri?.let { u ->
            // SAF tree → 實體路徑（僅支援 primary storage 的 tree；本機測試情境）
            val docId = android.provider.DocumentsContract.getTreeDocumentId(u)
            val path = docId.removePrefix("primary:")
            view = View.Library
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
    val playerUi = rememberPlayerUi(controller)
    val pinManager = (context.applicationContext as MuApp).pinManager

    fun resolveFile(t: Scanner.Track): File? {
        val rootPath = state.rootPath ?: return null
        return pinManager.pinnedFile(t.id) ?: File(rootPath, t.path)
    }

    /** 專輯封面的線索檔：掃描器挑定的封面軌，否則該專輯第一軌。 */
    fun albumArtFile(albumId: String): File? {
        val album = state.albums.firstOrNull { it.id == albumId }
        val track = album?.artTrackId?.let { state.tracksById[it] }
            ?: state.tracksByAlbum[albumId]?.firstOrNull()
        return track?.let(::resolveFile)
    }

    fun play(tracks: List<Scanner.Track>, startIndex: Int) {
        val c = controller ?: return
        c.setMediaItems(PlaybackService.mediaItems(tracks) { resolveFile(it) ?: File(it.path) })
        c.seekTo(startIndex, 0)
        c.prepare()
        c.play()
    }

    BackHandler(enabled = view !is View.Library) { view = View.Library }

    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val title = when (val v = view) {
        is View.Album -> state.albums.firstOrNull { it.id == v.id }?.name ?: "專輯"
        is View.Playlist -> v.name
        View.Library -> "資料庫"
    }

    Scaffold(
        modifier = if (view is View.Library) Modifier.nestedScroll(scrollBehavior.nestedScrollConnection) else Modifier,
        topBar = {
            if (state.rootPath == null) {
                // 歡迎頁沒有可操作的資料庫——不放標題列，讓內容自己說話
            } else if (view is View.Library) {
                LargeTopAppBar(
                    title = { Text(title) },
                    actions = {
                        if (state.rootPath != null) {
                            EffectsMenu()
                            LibraryMenu(onRescan = { vm.rescan() }, onPickFolder = { requestAndPick() },
                                folderName = state.rootPath?.let { File(it).name })
                        }
                    },
                    scrollBehavior = scrollBehavior,
                )
            } else {
                TopAppBar(
                    title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    navigationIcon = {
                        IconButton(onClick = { view = View.Library }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                        }
                    },
                    actions = { EffectsMenu() },
                )
            }
        },
        bottomBar = {
            if (playerUi.hasQueue) {
                val albumId = state.tracksById[playerUi.trackId]?.albumId.orEmpty()
                MiniPlayer(
                    ui = playerUi,
                    artKey = albumId,
                    artFile = albumArtFile(albumId),
                    onToggle = {
                        controller?.run { if (isPlaying) pause() else { prepare(); play() } }
                    },
                    onNext = { controller?.seekToNextMediaItem() },
                    onOpen = {
                        state.tracksById[playerUi.trackId]?.albumId?.let { view = View.Album(it) }
                    },
                )
            }
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            when {
                state.rootPath == null && !state.scanning -> Welcome { requestAndPick() }

                state.scanning && state.albums.isEmpty() && state.playlists.isEmpty() -> Scanning()

                view is View.Playlist -> {
                    val pl = state.playlists.firstOrNull { it.name == (view as View.Playlist).name }
                    if (pl == null) {
                        Gone("清單已無可播軌")
                    } else {
                        DetailScreen(
                            artKey = "pl:" + pl.name,
                            artFile = null,
                            playlistArt = true,
                            title = pl.name,
                            subtitle = "播放清單",
                            meta = "${pl.tracks.size} 首 · " + totalDuration(pl.tracks),
                            tracks = pl.tracks,
                            numbering = { i, _ -> i + 1 },
                            subtitleOf = { it.artist + " · " + it.album },
                            offlineIds = offlineIds(state),
                            playingId = playerUi.trackId,
                            onPlayAll = { play(pl.tracks, 0) },
                            onPlay = { i -> play(pl.tracks, i) },
                        )
                    }
                }

                view is View.Album -> {
                    // unpin 後專輯可能整個消失（全離線軌被濾掉）→ 回庫列表，別讓 first{} 炸
                    val album = state.albums.firstOrNull { it.id == (view as View.Album).id }
                    if (album == null) {
                        Gone("專輯已無可播軌")
                    } else {
                        val tracks = state.tracksByAlbum[album.id].orEmpty()
                        DetailScreen(
                            artKey = album.id,
                            artFile = albumArtFile(album.id),
                            title = album.name,
                            subtitle = album.albumArtist,
                            meta = listOfNotNull(
                                album.year?.toString(),
                                tracks.firstOrNull()?.format?.uppercase()?.ifEmpty { null },
                                "${tracks.size} 首",
                            ).joinToString(" · "),
                            tracks = tracks,
                            numbering = { i, t -> t.trackNo ?: (i + 1) },
                            subtitleOf = { t -> t.artist.takeIf { it != album.albumArtist } },
                            offlineIds = offlineIds(state),
                            playingId = playerUi.trackId,
                            onPlayAll = { play(tracks, 0) },
                            onPlay = { i -> play(tracks, i) },
                            pin = PinUi(
                                tracks = tracks,
                                pinStates = state.pinStates,
                                onPin = { vm.pinAlbum(album.id) },
                                onUnpin = { vm.unpinAlbum(album.id) },
                            ),
                        )
                    }
                }

                else -> LibraryScreen(
                    state = state,
                    query = query,
                    onQuery = { query = it },
                    tab = tab,
                    onTab = { tab = it },
                    artFileOf = ::albumArtFile,
                    onAlbum = { view = View.Album(it) },
                    onPlaylist = { view = View.Playlist(it) },
                )
            }
        }
    }
}

private fun offlineIds(state: LibraryViewModel.UiState): Set<String> =
    state.pinStates.filterValues { it == PinManager.PinState.DONE }.keys

// MARK: 資料庫

@Composable
private fun LibraryScreen(
    state: LibraryViewModel.UiState,
    query: String,
    onQuery: (String) -> Unit,
    tab: LibraryTab,
    onTab: (LibraryTab) -> Unit,
    artFileOf: (String) -> File?,
    onAlbum: (String) -> Unit,
    onPlaylist: (String) -> Unit,
) {
    val q = query.trim()
    val searching = q.isNotEmpty()
    val albums = if (!searching) {
        state.albums
    } else {
        state.albums.filter {
            it.name.contains(q, true) || it.albumArtist.contains(q, true)
        }
    }
    val playlists = if (!searching) {
        state.playlists
    } else {
        state.playlists.filter { it.name.contains(q, true) }
    }
    val showsPicker = !searching && state.playlists.isNotEmpty()
    val showsAlbums = if (searching) albums.isNotEmpty() else
        (tab == LibraryTab.ALBUMS || state.playlists.isEmpty())
    val showsPlaylists = if (searching) playlists.isNotEmpty() else
        (tab == LibraryTab.PLAYLISTS && state.playlists.isNotEmpty())

    Column(Modifier.fillMaxSize()) {
        SearchField(query, onQuery)
        if (showsPicker) {
            SingleChoiceSegmentedButtonRow(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = MuDimens.pageInset, vertical = 4.dp),
            ) {
                LibraryTab.entries.forEachIndexed { i, t ->
                    SegmentedButton(
                        selected = tab == t,
                        onClick = { onTab(t) },
                        shape = SegmentedButtonDefaults.itemShape(i, LibraryTab.entries.size),
                    ) { Text(t.label) }
                }
            }
        }
        if (albums.isEmpty() && playlists.isEmpty()) {
            Empty(
                icon = if (searching) Icons.Default.Search else Icons.Default.LibraryMusic,
                title = if (searching) "沒有符合的結果" else "資料夾裡還沒有音樂",
                body = if (searching) "換個關鍵字試試。" else "把音樂放進資料夾後，從右上角選單重新掃描。",
            )
        } else if (showsPlaylists) {
            LazyColumn(Modifier.fillMaxSize()) {
                items(playlists, key = { it.name }) { pl ->
                    PlaylistRow(pl) { onPlaylist(pl.name) }
                    HorizontalDivider(Modifier.padding(start = MuDimens.pageInset + 68.dp))
                }
            }
        } else if (showsAlbums) {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(150.dp),
                contentPadding = PaddingValues(MuDimens.pageInset),
                horizontalArrangement = Arrangement.spacedBy(MuDimens.gridSpacing),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(albums, key = { it.id }) { album ->
                    AlbumCard(album, artFileOf(album.id)) { onAlbum(album.id) }
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun SearchField(query: String, onQuery: (String) -> Unit) {
    OutlinedTextField(
        value = query,
        onValueChange = onQuery,
        singleLine = true,
        placeholder = { Text("專輯、藝人或清單") },
        leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQuery("") }) {
                    Icon(Icons.Default.Close, contentDescription = "清除搜尋")
                }
            }
        },
        shape = RoundedCornerShape(28.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = MuDimens.pageInset, vertical = 4.dp),
    )
}

@Composable
private fun AlbumCard(album: Scanner.Album, artFile: File?, onClick: () -> Unit) {
    Column(
        Modifier
            .clip(RoundedCornerShape(MuDimens.artCorner))
            .clickable(onClick = onClick),
    ) {
        AlbumArt(album.id, artFile, Modifier.fillMaxWidth().aspectRatio(1f))
        Text(
            album.name,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
        Text(
            album.albumArtist + (album.year?.let { " · $it" } ?: ""),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun PlaylistRow(pl: LibraryViewModel.UiState.PlaylistUi, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .heightIn(min = 64.dp)
            .padding(horizontal = MuDimens.pageInset, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AlbumArt("pl:" + pl.name, null, Modifier.size(56.dp), MuDimens.artCornerSmall, playlist = true)
        Column(
            Modifier
                .weight(1f)
                .padding(horizontal = 12.dp),
        ) {
            Text(pl.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1,
                overflow = TextOverflow.Ellipsis)
            Text("${pl.tracks.size} 首", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.outline,
        )
    }
}

// MARK: 詳情

private data class PinUi(
    val tracks: List<Scanner.Track>,
    val pinStates: Map<String, PinManager.PinState>,
    val onPin: () -> Unit,
    val onUnpin: () -> Unit,
)

@Composable
private fun DetailScreen(
    artKey: String,
    artFile: File?,
    title: String,
    subtitle: String,
    meta: String,
    tracks: List<Scanner.Track>,
    numbering: (Int, Scanner.Track) -> Int,
    subtitleOf: (Scanner.Track) -> String?,
    offlineIds: Set<String>,
    playingId: String,
    onPlayAll: () -> Unit,
    onPlay: (Int) -> Unit,
    playlistArt: Boolean = false,
    pin: PinUi? = null,
) {
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = MuDimens.pageInset),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                AlbumArt(artKey, artFile, Modifier.size(220.dp), MuDimens.artCornerLarge,
                    playlist = playlistArt)
                Text(
                    title,
                    style = MaterialTheme.typography.headlineSmall,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 16.dp),
                )
                Text(
                    subtitle,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary,
                    textAlign = TextAlign.Center,
                )
                Text(
                    meta,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp),
                )
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(top = 16.dp, bottom = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Button(
                        onClick = onPlayAll,
                        enabled = tracks.isNotEmpty(),
                        modifier = Modifier.weight(1f).heightIn(min = MuDimens.hitTarget),
                    ) {
                        Icon(Icons.Default.PlayArrow, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("播放")
                    }
                    if (pin != null) {
                        PinButton(pin, Modifier.weight(1f))
                    }
                }
            }
        }
        itemsIndexed(tracks) { i, t ->
            TrackRow(
                number = numbering(i, t),
                title = t.title,
                subtitle = subtitleOf(t),
                durationMs = t.durationMs,
                offline = t.id in offlineIds,
                playing = t.id == playingId && playingId.isNotEmpty(),
                onClick = { onPlay(i) },
            )
            if (i < tracks.size - 1) {
                HorizontalDivider(Modifier.padding(start = MuDimens.pageInset + 40.dp))
            }
        }
        item {
            Text(
                "${tracks.size} 首歌曲 · " + totalDuration(tracks),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(MuDimens.pageInset),
            )
        }
    }
}

@Composable
private fun TrackRow(
    number: Int,
    title: String,
    subtitle: String?,
    durationMs: Long?,
    offline: Boolean,
    playing: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .heightIn(min = MuDimens.hitTarget)
            .padding(horizontal = MuDimens.pageInset, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) {
            if (playing) {
                Icon(
                    Icons.AutoMirrored.Filled.VolumeUp,
                    contentDescription = "播放中",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
            } else {
                Text(
                    "$number",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Column(
            Modifier
                .weight(1f)
                .padding(horizontal = 12.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                color = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (!subtitle.isNullOrEmpty()) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (offline) {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = "離線",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp).padding(end = 0.dp),
            )
            Spacer(Modifier.width(8.dp))
        }
        Text(
            durationMs?.let { "%d:%02d".format(it / 60000, it / 1000 % 60) } ?: "",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** 釘選按鈕：短標籤 + 圖示；contentDescription 為完整狀態句（與 iOS 同文案）。 */
@Composable
private fun PinButton(pin: PinUi, modifier: Modifier = Modifier) {
    val total = pin.tracks.size
    val done = pin.tracks.count { pin.pinStates[it.id] == PinManager.PinState.DONE }
    val pending = pin.tracks.count {
        val s = pin.pinStates[it.id]
        s == PinManager.PinState.WANTED || s == PinManager.PinState.DOWNLOADING
    }
    val failed = pin.tracks.count { pin.pinStates[it.id] == PinManager.PinState.FAILED }
    val allDone = total > 0 && done == total
    val full = when {
        total == 0 -> "無軌"
        allDone -> "已釘選（$total 軌，點擊取消）"
        done + pending > 0 -> "釘選中 $done/$total" + if (failed > 0) " · $failed 失敗" else ""
        failed > 0 -> "釘選失敗 $failed/$total（點擊重試）"
        else -> "釘選離線（$total 軌）"
    }
    val short = when {
        total == 0 -> "無軌"
        allDone -> "已釘選"
        pending > 0 -> "釘選中 $done/$total"
        failed > 0 -> "重試釘選"
        else -> "釘選離線"
    }
    OutlinedButton(
        onClick = { if (allDone) pin.onUnpin() else pin.onPin() },
        enabled = total > 0,
        modifier = modifier
            .heightIn(min = MuDimens.hitTarget)
            .testTag("pinChip")
            .semanticsLabel(full),
    ) {
        if (pending > 0) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        } else {
            Icon(
                if (allDone) Icons.Default.CheckCircle
                else if (failed > 0) Icons.Default.Refresh
                else Icons.Default.FileDownload,
                contentDescription = null,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(short, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private fun Modifier.semanticsLabel(label: String): Modifier =
    this.semantics { contentDescription = label }

// MARK: 空狀態 / 歡迎

@Composable
private fun Welcome(onPick: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Default.LibraryMusic,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(56.dp),
        )
        Text("Mu", style = MaterialTheme.typography.displaySmall,
            modifier = Modifier.padding(top = 16.dp))
        Text(
            "把資料夾當成音樂庫。\n只讀不寫，隨處播放，釘選離線。",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp),
        )
        Button(
            onClick = onPick,
            modifier = Modifier
                .padding(top = 32.dp)
                .heightIn(min = MuDimens.hitTarget),
        ) { Text("選擇音樂資料夾") }
        Text(
            "支援 MP3 · FLAC · M4A · OGG · WAV，播放清單讀取 .m3u8",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 16.dp),
        )
    }
}

@Composable
private fun Scanning() {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator()
        Text("正在掃描資料庫", style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(top = 16.dp))
        Text(
            "第一次掃描會讀取每個檔案的標籤，稍候片刻。",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

@Composable
private fun Empty(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    body: String,
) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(44.dp))
        Text(title, style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(top = 12.dp))
        Text(body, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun Gone(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, style = MaterialTheme.typography.titleMedium)
    }
}

private fun totalDuration(tracks: List<Scanner.Track>): String {
    val secs = tracks.mapNotNull { it.durationMs }.sum() / 1000
    return if (secs >= 3600) {
        "${secs / 3600} 小時 ${secs / 60 % 60} 分鐘"
    } else {
        "${maxOf(1L, secs / 60)} 分鐘"
    }
}

// MARK: 選單

/** 資料庫選單：重掃 / 更換資料夾（標題列出目前資料夾）。 */
@Composable
private fun LibraryMenu(onRescan: () -> Unit, onPickFolder: () -> Unit, folderName: String?) {
    var open by remember { mutableStateOf(false) }
    IconButton(onClick = { open = true }) {
        Icon(Icons.Default.MoreVert, contentDescription = "資料庫選項")
    }
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        if (!folderName.isNullOrEmpty()) {
            MenuHeader(folderName)
        }
        DropdownMenuItem(
            text = { Text("重新掃描") },
            leadingIcon = { Icon(Icons.Default.Refresh, contentDescription = null) },
            onClick = { open = false; onRescan() },
        )
        DropdownMenuItem(
            text = { Text("更換資料夾…") },
            leadingIcon = { Icon(Icons.Default.LibraryMusic, contentDescription = null) },
            onClick = { open = false; onPickFolder() },
        )
    }
}

/**
 * 音效選單：ReplayGain 模式 + EQ preset/前置增益
 * （存 SharedPreferences，PlaybackService 監聽即時套用）。
 * 選取狀態用圖示表示，不用文字打勾。
 */
@Composable
private fun EffectsMenu() {
    val context = LocalContext.current
    val prefs = remember {
        context.getSharedPreferences(PlaybackService.PREFS, android.content.Context.MODE_PRIVATE)
    }
    var mode by remember {
        mutableStateOf(mu.core.ReplayGain.Mode.from(prefs.getString(mu.core.ReplayGain.PREF_KEY, null)))
    }
    var eq by remember {
        mutableStateOf(mu.core.EqSettings.parse(prefs.getString(mu.core.EqSettings.PREF_KEY, null)))
    }
    var open by remember { mutableStateOf(false) }

    fun saveEq(next: mu.core.EqSettings) {
        eq = next
        prefs.edit().putString(mu.core.EqSettings.PREF_KEY, next.serialize()).apply()
    }

    IconButton(onClick = { open = true }, modifier = Modifier.testTag("replayGain")) {
        Icon(
            Icons.Default.Tune,
            contentDescription = "音效：音量標準化 ${mode.label}／等化器 " +
                if (eq.enabled) eqLabel(eq.preset) else "關閉",
        )
    }
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        MenuHeader("音量標準化")
        mu.core.ReplayGain.Mode.entries.forEach { m ->
            CheckableItem(m.label, m == mode) {
                mode = m
                prefs.edit().putString(mu.core.ReplayGain.PREF_KEY, m.key).apply()
                open = false
            }
        }
        HorizontalDivider()
        MenuHeader("等化器")
        CheckableItem("關閉", !eq.enabled) {
            saveEq(mu.core.EqSettings.create(eq.bands, enabled = false, preamp = eq.preamp,
                preset = eq.preset))
            open = false
        }
        mu.core.EqSettings.PRESETS.forEach { (name, _) ->
            CheckableItem(eqLabel(name), eq.enabled && eq.preset == name) {
                saveEq(mu.core.EqSettings.preset(name, enabled = true, preamp = eq.preamp))
                open = false
            }
        }
        HorizontalDivider()
        MenuHeader("前置增益")
        listOf(-600, -300, 0, 300, 600).forEach { mb ->
            CheckableItem(preampLabel(mb), eq.preamp == mb, enabled = eq.enabled) {
                saveEq(mu.core.EqSettings.create(eq.bands, eq.enabled, mb, eq.preset))
                open = false
            }
        }
    }
}

@Composable
private fun MenuHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
private fun CheckableItem(
    label: String,
    selected: Boolean,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    DropdownMenuItem(
        text = { Text(label) },
        enabled = enabled,
        leadingIcon = {
            if (selected) {
                Icon(Icons.Default.Check, contentDescription = "已選取")
            } else {
                Spacer(Modifier.size(24.dp))
            }
        },
        onClick = onClick,
    )
}

private fun preampLabel(mb: Int) = if (mb == 0) "0 dB" else "%+.0f dB".format(mb / 100.0)

private fun eqLabel(name: String) = when (name) {
    "flat" -> "平坦"
    "rock" -> "搖滾"
    "pop" -> "流行"
    "jazz" -> "爵士"
    "classical" -> "古典"
    "bass" -> "重低音"
    "treble" -> "高音"
    "vocal" -> "人聲"
    "loudness" -> "響度"
    else -> name
}
