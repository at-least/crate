package music.mu.android

import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.glance.appwidget.updateAll
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import mu.core.EqSettings
import mu.core.NowPlayingSnapshot
import mu.core.ReplayGain
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
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
        val renderersFactory = object : DefaultRenderersFactory(this) {
            override fun buildAudioSink(
                context: android.content.Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean,
            ): AudioSink = DefaultAudioSink.Builder(context)
                .setAudioProcessorChain(DefaultAudioSink.DefaultAudioProcessorChain(processor))
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                .build()
        }
        val player = ExoPlayer.Builder(this, renderersFactory)
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
        // ReplayGain + EQ：換曲/改設定時重算 DSP（設定存 SharedPreferences；UI 改動即時生效）
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                applyDsp(player, mediaItem)
                publishNowPlaying(player)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) = publishNowPlaying(player)

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) = publishNowPlaying(player)
        })
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        prefListener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == ReplayGain.PREF_KEY || key == EqSettings.PREF_KEY) {
                applyDsp(player, player.currentMediaItem)
            }
        }
        prefs?.registerOnSharedPreferenceChangeListener(prefListener)
        applyDsp(player, null)
    }

    private val processor = MuAudioProcessor()
    private val widgetScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** 現正播放快照 → SharedPreferences + Widget（model.md §1.11；widget 只讀）。 */
    private fun publishNowPlaying(player: Player) {
        val item = player.currentMediaItem
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 }?.toInt()
        val snapshot = NowPlayingSnapshot.create(
            trackId = item?.mediaId,
            title = item?.mediaMetadata?.title?.toString(),
            artist = item?.mediaMetadata?.artist?.toString(),
            albumId = item?.mediaMetadata?.albumTitle?.toString(),
            isPlaying = player.isPlaying,
            positionMs = player.currentPosition.coerceAtLeast(0).toInt(),
            durationMs = duration,
            updatedAtMs = System.currentTimeMillis(),
        )
        prefs?.edit()?.putString(NowPlayingSnapshot.STORAGE_KEY, snapshot.serialize())?.apply()
        widgetScope.launch { MuWidget().updateAll(this@PlaybackService) }
    }

    private var prefs: android.content.SharedPreferences? = null
    private var prefListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null

    /** 總增益（ReplayGain + preamp）與 EQ 一併交給 DSP；播放器音量固定 1（正增益放大在 DSP 內）。 */
    private fun applyDsp(player: Player, item: MediaItem?) {
        val mode = ReplayGain.Mode.from(prefs?.getString(ReplayGain.PREF_KEY, null))
        val eq = EqSettings.parse(prefs?.getString(EqSettings.PREF_KEY, null))
        val extras = item?.mediaMetadata?.extras
        fun mb(key: String): Int? = extras?.takeIf { it.containsKey(key) }?.getInt(key)
        processor.dsp.setSettings(eq, eq.playbackGainMb(mode, mb(EXTRA_RG_TRACK), mb(EXTRA_RG_ALBUM)))
        player.volume = 1f
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
        widgetScope.cancel()
        prefs?.unregisterOnSharedPreferenceChangeListener(prefListener)
        mediaSession?.run {
            player.release()
            release()
            mediaSession = null
        }
        super.onDestroy()
    }

    companion object {
        const val PREFS = "mu"
        const val EXTRA_RG_TRACK = "rgTrackMb"
        const val EXTRA_RG_ALBUM = "rgAlbumMb"

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
                            .setExtras(android.os.Bundle().apply {
                                t.replayGainTrackMb?.let { putInt(EXTRA_RG_TRACK, it) }
                                t.replayGainAlbumMb?.let { putInt(EXTRA_RG_ALBUM, it) }
                            })
                            .build(),
                    )
                    .build()
            }
    }
}
