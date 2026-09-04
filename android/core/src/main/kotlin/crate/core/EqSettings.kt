package crate.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlin.math.pow

/** 等化器設定（model.md §1.10）。純整數（millibel）；序列化與 Python/Swift byte-identical。 */
data class EqSettings(
    val bands: List<Int>,
    val enabled: Boolean,
    val preamp: Int,
    val preset: String,
) {
    companion object {
        /** 中心頻率（Hz）；每段 Q 固定。 */
        val BAND_HZ = listOf(31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)
        const val BAND_Q = 1.41
        const val GAIN_LIMIT_MB = 1200
        const val RG_LIMIT_MB = 6000
        const val TOTAL_MIN_MB = -6000
        const val TOTAL_MAX_MB = 1200

        /** 平台 prefs 鍵（model.md §1.10）。 */
        const val PREF_KEY = "eq"

        val PRESETS: List<Pair<String, List<Int>>> = listOf(
            "flat" to listOf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
            "rock" to listOf(500, 400, 200, 0, -100, -100, 200, 400, 500, 500),
            "pop" to listOf(-100, 100, 300, 400, 300, 100, 0, -100, -100, -100),
            "jazz" to listOf(300, 200, 100, 200, -100, -100, 0, 100, 200, 300),
            "classical" to listOf(400, 300, 200, 100, -100, -100, 0, 200, 300, 400),
            "bass" to listOf(700, 600, 400, 200, 0, 0, 0, 0, 0, 0),
            "treble" to listOf(0, 0, 0, 0, 0, 100, 300, 500, 600, 700),
            "vocal" to listOf(-200, -100, 0, 200, 400, 400, 300, 100, 0, -100),
            "loudness" to listOf(600, 500, 200, 0, -200, -200, 0, 200, 500, 600),
        )

        fun presetBands(name: String): List<Int>? = PRESETS.firstOrNull { it.first == name }?.second

        val DEFAULT = create()

        fun create(
            bands: List<Int> = emptyList(),
            enabled: Boolean = false,
            preamp: Int = 0,
            preset: String = "flat",
        ): EqSettings {
            val b = bands.take(BAND_HZ.size).toMutableList()
            while (b.size < BAND_HZ.size) b.add(0)
            return EqSettings(
                b.map { clamp(it, -GAIN_LIMIT_MB, GAIN_LIMIT_MB) },
                enabled,
                clamp(preamp, -GAIN_LIMIT_MB, GAIN_LIMIT_MB),
                preset,
            )
        }

        /** 未知名稱 → flat。 */
        fun preset(name: String, enabled: Boolean = true, preamp: Int = 0): EqSettings {
            val known = presetBands(name)
            return create(known ?: presetBands("flat")!!, enabled, preamp,
                if (known == null) "flat" else name)
        }

        /** 壞 JSON / 缺鍵 → 預設；非整數 band → 0。 */
        fun parse(text: String?): EqSettings {
            if (text.isNullOrEmpty()) return DEFAULT
            val obj = try {
                Json.parseToJsonElement(text) as? JsonObject ?: return DEFAULT
            } catch (e: Exception) {
                return DEFAULT
            }
            val bands = (obj["bands"] as? JsonArray)?.map { asInt(it) ?: 0 } ?: emptyList()
            val presetName = (obj["preset"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return create(
                bands,
                (obj["enabled"] as? JsonPrimitive)?.takeIf { !it.isString }?.content == "true",
                asInt(obj["preamp"]) ?: 0,
                presetName?.takeIf { presetBands(it) != null } ?: "flat",
            )
        }

        /** 線性增益（v1.3 起可 > 1——DSP 層套用）。 */
        fun linear(mb: Int): Float = 10.0.pow(mb / 2000.0).toFloat()

        internal fun clamp(v: Int, lo: Int, hi: Int) = if (v < lo) lo else if (v > hi) hi else v

        /** JSON 值 → Int；Bool、浮點、字串一律 null（契約：非整數視為 0）。 */
        private fun asInt(el: kotlinx.serialization.json.JsonElement?): Int? {
            val p = el as? JsonPrimitive ?: return null
            if (p.isString) return null
            return p.content.toIntOrNull()
        }
    }

    /** canonical（鍵序固定、無空白）——三方 byte-identical。 */
    fun serialize(): String =
        """{"bands":[${bands.joinToString(",")}],"enabled":$enabled,"preamp":$preamp,"preset":"$preset"}"""

    /** (頻率, mb)；停用或增益 0 的段不進 DSP。 */
    fun activeBands(): List<Pair<Int, Int>> =
        if (!enabled) emptyList() else BAND_HZ.zip(bands).filter { it.second != 0 }

    /** DSP 直通判定（§1.10 末段）。 */
    fun isIdentity(gainMb: Int): Boolean = gainMb == 0 && activeBands().isEmpty()

    /** 播放總增益（§1.9 ReplayGain + preamp，整數 mb）。 */
    fun playbackGainMb(mode: ReplayGain.Mode, trackMb: Int?, albumMb: Int?): Int {
        val rg = ReplayGain.gainMb(mode, trackMb, albumMb)
        var total = clamp(rg ?: 0, -RG_LIMIT_MB, RG_LIMIT_MB)
        if (enabled) total += preamp
        return clamp(total, TOTAL_MIN_MB, TOTAL_MAX_MB)
    }

    fun playbackGainMb(mode: ReplayGain.Mode, track: Scanner.Track?): Int =
        playbackGainMb(mode, track?.replayGainTrackMb, track?.replayGainAlbumMb)
}
