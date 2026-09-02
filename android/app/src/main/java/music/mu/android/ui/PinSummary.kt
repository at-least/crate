package music.mu.android.ui

import music.mu.android.PinManager
import mu.core.Scanner

/** 一組音軌的釘選狀態彙總（專輯詳情頁的釘選按鈕用；文案與 iOS 的 MuKit.PinSummary 一致）。 */
data class PinSummary(
    val total: Int,
    val done: Int,
    val pending: Int,
    val failed: Int,
) {
    companion object {
        fun of(tracks: List<Scanner.Track>, states: Map<String, PinManager.PinState>): PinSummary {
            val done = tracks.count { states[it.id] == PinManager.PinState.DONE }
            val pending = tracks.count {
                val s = states[it.id]
                s == PinManager.PinState.WANTED || s == PinManager.PinState.DOWNLOADING
            }
            val failed = tracks.count { states[it.id] == PinManager.PinState.FAILED }
            return PinSummary(tracks.size, done, pending, failed)
        }
    }

    val allDone: Boolean get() = total > 0 && done == total

    val shortLabel: String get() = when {
        total == 0 -> "無軌"
        allDone -> "已釘選"
        pending > 0 -> "釘選中 $done/$total"
        failed > 0 -> "重試釘選"
        else -> "釘選離線"
    }

    val fullLabel: String get() = when {
        total == 0 -> "無軌"
        allDone -> "已釘選（$total 軌，點擊取消）"
        done + pending > 0 -> "釘選中 $done/$total" + if (failed > 0) " · $failed 失敗" else ""
        failed > 0 -> "釘選失敗 $failed/$total（點擊重試）"
        else -> "釘選離線（$total 軌）"
    }
}
