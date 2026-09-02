package music.mu.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.MoreExecutors
import kotlinx.coroutines.delay
import music.mu.android.ui.AlbumArt
import music.mu.android.ui.MuDimens
import java.io.File

/** 綁定 PlaybackService 的 MediaController（Compose 生命週期內持有）。 */
@Composable
fun rememberPlayerController(): MediaController? {
    val context = LocalContext.current
    val controller = remember { mutableStateOf<MediaController?>(null) }
    DisposableEffect(Unit) {
        val token = SessionToken(context, android.content.ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            controller.value = try {
                com.google.common.util.concurrent.Futures.getDone(future)
            } catch (_: Exception) { null }
        }, MoreExecutors.directExecutor())
        onDispose { MediaController.releaseFuture(future) }
    }
    return controller.value
}

/**
 * 播放器 UI 快照（播放列與音軌高亮共用）。
 * 刻意不含 positionMs/durationMs——那兩個每 0.5 秒跳一次，若放進這個 data class，
 * 每跳一次都會讓讀到 `ui` 的整個組合範圍（目前是 MuRoot 全部）重組一次。
 * 進度改由 [MiniPlayer] 自己用 [MutableLongState] 持有，只讀取的那個 lambda 內部重畫。
 */
data class PlayerUi(
    val hasQueue: Boolean = false,
    val isPlaying: Boolean = false,
    val title: String = "",
    val artist: String = "",
    val trackId: String = "",
)

/**
 * 由 MediaController 事件推導 UI 狀態（只在真的變動時更新：換曲、播/暫、佇列變化）。
 * 直接讀 `controller.isPlaying` 不會觸發重組——必須掛 [Player.Listener]。
 */
@Composable
fun rememberPlayerUi(controller: MediaController?): PlayerUi {
    var ui by remember { mutableStateOf(PlayerUi()) }

    fun snapshot(c: MediaController) = PlayerUi(
        hasQueue = c.mediaItemCount > 0,
        isPlaying = c.isPlaying,
        title = c.mediaMetadata.title?.toString().orEmpty(),
        artist = c.mediaMetadata.artist?.toString().orEmpty(),
        trackId = c.currentMediaItem?.mediaId.orEmpty(),
    )

    DisposableEffect(controller) {
        val c = controller ?: return@DisposableEffect onDispose { }
        ui = snapshot(c)
        val listener = object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                ui = snapshot(c)
            }
        }
        c.addListener(listener)
        onDispose { c.removeListener(listener) }
    }
    return ui
}

/**
 * 底部迷你播放列：封面、標題/藝人、播放/暫停、下一首，上緣一條細進度。
 * 整列可點（打開現正播放）；控制鍵各自 48dp 觸控區。
 */
@Composable
fun MiniPlayer(
    ui: PlayerUi,
    controller: MediaController?,
    artKey: String,
    artFile: File?,
    onToggle: () -> Unit,
    onNext: () -> Unit,
    onOpen: () -> Unit,
) {
    // 進度是唯一每 0.5 秒動一次的狀態，故意跟 PlayerUi 分開持有：
    // positionState/durationState 只在 LinearProgressIndicator 的 progress lambda 裡被讀取，
    // 所以每次 tick 只讓那個 lambda 重畫，不會讓 MiniPlayer 本身（更不會是外層 MuRoot）重組。
    val positionState = remember { mutableLongStateOf(controller?.currentPosition?.coerceAtLeast(0) ?: 0L) }
    val durationState = remember {
        mutableLongStateOf(controller?.duration?.takeIf { it > 0 } ?: 0L)
    }
    LaunchedEffect(controller, ui.trackId, ui.isPlaying) {
        val c = controller ?: return@LaunchedEffect
        positionState.longValue = c.currentPosition.coerceAtLeast(0)
        durationState.longValue = c.duration.takeIf { it > 0 } ?: 0
        while (ui.isPlaying) {
            delay(500)
            positionState.longValue = c.currentPosition.coerceAtLeast(0)
            durationState.longValue = c.duration.takeIf { it > 0 } ?: 0
        }
    }

    Surface(tonalElevation = 3.dp, shadowElevation = 8.dp) {
        // 導覽列（手勢條）在 edge-to-edge 下會壓到控制鍵——底色延伸過去，內容留白避開。
        Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars)) {
            if (durationState.longValue > 0) {
                LinearProgressIndicator(
                    progress = {
                        val duration = durationState.longValue
                        if (duration > 0) (positionState.longValue.toFloat() / duration).coerceIn(0f, 1f) else 0f
                    },
                    modifier = Modifier.fillMaxWidth().height(2.dp),
                    trackColor = MaterialTheme.colorScheme.surfaceVariant,
                    drawStopIndicator = { },
                    gapSize = 0.dp,
                )
            } else {
                HorizontalDivider()
            }
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = "打開現正播放", onClick = onOpen)
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AlbumArt(artKey, artFile, Modifier.size(44.dp), MuDimens.artCornerSmall)
                Column(
                    Modifier
                        .weight(1f)
                        .padding(horizontal = 12.dp),
                ) {
                    Text(
                        ui.title,
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.testTag("player.title"),
                    )
                    if (ui.artist.isNotEmpty()) {
                        Text(
                            ui.artist,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                IconButton(onClick = onToggle, modifier = Modifier.testTag("player.toggle")) {
                    Icon(
                        if (ui.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        contentDescription = if (ui.isPlaying) "暫停" else "播放",
                    )
                }
                IconButton(onClick = onNext, modifier = Modifier.testTag("player.next")) {
                    Icon(Icons.Default.SkipNext, contentDescription = "下一首")
                }
            }
        }
    }
}
