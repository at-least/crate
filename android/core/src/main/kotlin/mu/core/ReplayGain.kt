package mu.core

import kotlin.math.pow

/**
 * ReplayGain 播放套用（model.md §1.9 的消費端）。
 * v1 以播放器音量套增益：線性 = 10^(mb/2000)，**上限 1.0**（只衰減、不放大——ExoPlayer/AVPlayer 音量無法 >1；
 * 正增益要放大需 audio processor，Phase 4 EQ 相位再議）。無前置增益。
 */
object ReplayGain {

    enum class Mode(val key: String, val label: String) {
        OFF("off", "關閉"), TRACK("track", "音軌"), ALBUM("album", "專輯");

        companion object {
            fun from(key: String?): Mode = entries.firstOrNull { it.key == key } ?: ALBUM
        }
    }

    const val PREF_KEY = "replayGainMode"

    /** 依模式取用的增益（millibel）；album 缺值退回 track；無 → null。 */
    fun gainMb(mode: Mode, trackMb: Int?, albumMb: Int?): Int? = when (mode) {
        Mode.OFF -> null
        Mode.TRACK -> trackMb
        Mode.ALBUM -> albumMb ?: trackMb
    }

    /** 播放器音量（0…1）。 */
    fun volume(mode: Mode, trackMb: Int?, albumMb: Int?): Float {
        val mb = gainMb(mode, trackMb, albumMb) ?: return 1f
        return minOf(1.0, 10.0.pow(mb / 2000.0)).toFloat()
    }
}
