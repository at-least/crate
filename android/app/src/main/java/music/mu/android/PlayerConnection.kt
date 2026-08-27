package music.mu.android

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.MoreExecutors

/** 建立/釋放 MediaController（UI ↔ PlaybackService）。 */
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

/** 底部迷你播放列：播/暫、下一首。 */
@Composable
fun PlayerBar(controller: MediaController?, title: String) {
    Row(Modifier.padding(16.dp)) {
        Text(title, Modifier.weight(1f), maxLines = 1)
        Button(
            onClick = {
                controller?.run {
                    if (isPlaying) pause() else { prepare(); play() }
                }
            },
            modifier = Modifier.padding(horizontal = 4.dp),
        ) { Text(if (controller?.isPlaying == true) "⏸" else "▶") }
        Button(
            onClick = { controller?.seekToNextMediaItem() },
        ) { Text("⏭") }
    }
}
