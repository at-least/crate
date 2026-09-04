package at.least.crate.android

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.action.actionStartActivity
import crate.core.NowPlayingSnapshot

/**
 * 主畫面 Widget（現正播放；model.md §1.11）。
 * 只讀 SharedPreferences 裡的快照——顯示規則（idle/paused/playing、位置推算）在核心層，
 * 兩平台共用同一份契約。點擊 = 開啟 app（v1 不做 widget 內控制）。
 */
class CrateWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val prefs = context.getSharedPreferences(PlaybackService.PREFS, Context.MODE_PRIVATE)
        val snapshot = NowPlayingSnapshot.parse(prefs.getString(NowPlayingSnapshot.STORAGE_KEY, null))
        provideContent { Content(snapshot) }
    }

    @Composable
    private fun Content(snapshot: NowPlayingSnapshot) {
        val now = System.currentTimeMillis()
        val state = snapshot.displayState(now)
        GlanceTheme {
            Column(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(GlanceTheme.colors.widgetBackground)
                    .padding(12.dp)
                    .clickable(actionStartActivity<MainActivity>()),
                verticalAlignment = Alignment.Vertical.CenterVertically,
            ) {
                if (state == NowPlayingSnapshot.DisplayState.IDLE) {
                    Text("Crate", style = TextStyle(fontWeight = FontWeight.Bold, fontSize = 16.sp))
                    Text("沒有播放中的音樂", style = TextStyle(fontSize = 12.sp))
                } else {
                    Text(
                        snapshot.title ?: "—",
                        maxLines = 1,
                        style = TextStyle(fontWeight = FontWeight.Bold, fontSize = 16.sp),
                    )
                    Text(snapshot.artist ?: "—", maxLines = 1, style = TextStyle(fontSize = 12.sp))
                    Text(
                        progressLabel(snapshot, now, state),
                        style = TextStyle(fontSize = 12.sp),
                    )
                }
            }
        }
    }

    companion object {
        /** "▶ 1:23 / 3:33"（無時長則只顯示位置）。 */
        fun progressLabel(
            snapshot: NowPlayingSnapshot,
            nowMs: Long,
            state: NowPlayingSnapshot.DisplayState,
        ): String {
            val icon = if (state == NowPlayingSnapshot.DisplayState.PLAYING) "▶" else "⏸"
            val pos = clock(snapshot.effectivePositionMs(nowMs))
            val dur = snapshot.durationMs?.let { " / " + clock(it) } ?: ""
            return "$icon $pos$dur"
        }

        private fun clock(ms: Int): String {
            val total = ms / 1000
            return "%d:%02d".format(total / 60, total % 60)
        }
    }
}

class CrateWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = CrateWidget()
}
