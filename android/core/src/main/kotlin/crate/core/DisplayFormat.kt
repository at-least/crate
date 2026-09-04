package crate.core

import kotlin.math.roundToLong

/**
 * UI 顯示用純格式化（不含任何平台 UI 依賴）：時長、EQ/ReplayGain 中文標籤。
 * 這裡的字串不是契約內容（不做三方 byte-identical 比對），只是避免同一份文案在
 * iOS/macOS/Android 各自的畫面檔裡重複手key、進而各自漂移。
 */
object DisplayFormat {

    /** 「3:07」。負值/null 回空字串。 */
    fun duration(ms: Long?): String {
        if (ms == null || ms < 0) return ""
        return "%d:%02d".format(ms / 60000, ms / 1000 % 60)
    }

    /** 「3:07」或「1:03:07」（滿一小時才帶時）。 */
    fun clock(seconds: Double): String {
        val s = maxOf(0, seconds.roundToLong())
        return if (s >= 3600) {
            "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60)
        } else {
            "%d:%02d".format(s / 60, s % 60)
        }
    }

    /** 「48 分鐘」或「1 小時 12 分鐘」。 */
    fun totalDuration(msValues: List<Long?>): String {
        val secs = msValues.filterNotNull().sum() / 1000
        return if (secs >= 3600) {
            "${secs / 3600} 小時 ${secs / 60 % 60} 分鐘"
        } else {
            "${maxOf(1L, secs / 60)} 分鐘"
        }
    }

    /** EQ preset 內部名稱 → 中文標籤（未知名稱原樣回傳）。 */
    fun eqPresetLabel(name: String): String = eqPresetLabels[name] ?: name

    /** 前置增益選項（millibel）：兩平台的選單共用同一組刻度。 */
    val eqPreampChoicesMb = listOf(-600, -300, 0, 300, 600)

    /** 「+3 dB」/「0 dB」。 */
    fun gainLabel(mb: Int): String = if (mb == 0) "0 dB" else "%+.0f dB".format(mb / 100.0)

    private val eqPresetLabels = mapOf(
        "flat" to "平坦", "rock" to "搖滾", "pop" to "流行", "jazz" to "爵士",
        "classical" to "古典", "bass" to "重低音", "treble" to "高音",
        "vocal" to "人聲", "loudness" to "響度",
    )
}
