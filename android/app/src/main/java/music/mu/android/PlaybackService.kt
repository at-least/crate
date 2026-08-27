package music.mu.android

import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import mu.core.Scanner
import java.io.File

/**
 * Media3 播放服務：通知/鎖屏/耳機控制由 MediaSession 免費獲得。
 * 資料來源 = LocalFolderProvider 的本地檔（Uri.fromFile）。
 */
class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val player = ExoPlayer.Builder(this)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true) // 拔耳機自動暫停
            .build()
        mediaSession = MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = mediaSession?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        mediaSession?.run {
            player.release()
            release()
            mediaSession = null
        }
        super.onDestroy()
    }

    companion object {
        /** 音軌清單 → MediaItems；檔案由 resolveFile 決定（釘選副本優先，否則庫根原檔）。 */
        fun mediaItems(
            tracks: List<Scanner.Track>,
            resolveFile: (Scanner.Track) -> File,
        ): List<MediaItem> =
            tracks.map { t ->
                MediaItem.Builder()
                    .setUri(android.net.Uri.fromFile(resolveFile(t)))
                    .setMediaId(t.id)
                    .setMediaMetadata(
                        MediaMetadata.Builder()
                            .setTitle(t.title)
                            .setArtist(t.artist)
                            .setAlbumTitle(t.album)
                            .setTrackNumber(t.trackNo ?: -1)
                            .build(),
                    )
                    .build()
            }
    }
}
