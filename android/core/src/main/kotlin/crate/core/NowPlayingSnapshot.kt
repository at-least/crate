package crate.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/**
 * 現正播放快照（model.md §1.11）：播放器 → Widget 的單向資料。
 * 純整數/字串；序列化與 Python/Swift byte-identical。
 */
data class NowPlayingSnapshot(
    val trackId: String?,
    val title: String?,
    val artist: String?,
    val albumId: String?,
    val isPlaying: Boolean,
    val positionMs: Int,
    val durationMs: Int?,
    val updatedAtMs: Long,
) {
    enum class DisplayState { IDLE, PAUSED, PLAYING }

    companion object {
        /** 預設過期門檻：6 小時。 */
        const val STALE_AFTER_MS = 6L * 60 * 60 * 1000

        /** 共享儲存鍵（SharedPreferences）。 */
        const val STORAGE_KEY = "nowPlaying"

        val IDLE = create()

        fun create(
            trackId: String? = null,
            title: String? = null,
            artist: String? = null,
            albumId: String? = null,
            isPlaying: Boolean = false,
            positionMs: Int = 0,
            durationMs: Int? = null,
            updatedAtMs: Long = 0,
        ) = NowPlayingSnapshot(
            trackId?.takeIf { it.isNotEmpty() },
            title?.takeIf { it.isNotEmpty() },
            artist?.takeIf { it.isNotEmpty() },
            albumId?.takeIf { it.isNotEmpty() },
            isPlaying,
            maxOf(0, positionMs),
            durationMs?.let { maxOf(0, it) },
            updatedAtMs,
        )

        /** 壞 JSON / 缺鍵 / 型別不符 → 該欄位取預設。 */
        fun parse(text: String?): NowPlayingSnapshot {
            if (text.isNullOrEmpty()) return IDLE
            val obj = try {
                Json.parseToJsonElement(text) as? JsonObject ?: return IDLE
            } catch (e: Exception) {
                return IDLE
            }
            fun str(key: String): String? =
                (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() }

            fun int(key: String): Int? =
                (obj[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toIntOrNull()

            fun long(key: String): Long? =
                (obj[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()

            return create(
                trackId = str("trackId"), title = str("title"), artist = str("artist"),
                albumId = str("albumId"),
                isPlaying = (obj["isPlaying"] as? JsonPrimitive)
                    ?.takeIf { !it.isString }?.content == "true",
                positionMs = int("positionMs") ?: 0,
                durationMs = int("durationMs"),
                updatedAtMs = long("updatedAtMs") ?: 0,
            )
        }
    }

    /** canonical（鍵序固定、無空白）——三方 byte-identical。 */
    fun serialize(): String {
        fun q(v: String?): String = if (v == null) "null" else CanonicalJson.quoted(v)
        return """{"albumId":${q(albumId)},"artist":${q(artist)},""" +
            """"durationMs":${durationMs ?: "null"},"isPlaying":$isPlaying,""" +
            """"positionMs":$positionMs,"title":${q(title)},""" +
            """"trackId":${q(trackId)},"updatedAtMs":$updatedAtMs}"""
    }

    fun displayState(nowMs: Long, staleAfterMs: Long = STALE_AFTER_MS): DisplayState {
        if (trackId == null) return DisplayState.IDLE
        if (nowMs - updatedAtMs > staleAfterMs) return DisplayState.IDLE
        return if (isPlaying) DisplayState.PLAYING else DisplayState.PAUSED
    }

    /** 推算目前位置（playing 才隨時鐘前進；clamp 到時長）。 */
    fun effectivePositionMs(nowMs: Long, staleAfterMs: Long = STALE_AFTER_MS): Int {
        if (displayState(nowMs, staleAfterMs) != DisplayState.PLAYING) return maxOf(0, positionMs)
        var pos = positionMs + maxOf(0L, nowMs - updatedAtMs)
        if (durationMs != null) pos = minOf(pos, durationMs.toLong())
        return maxOf(0L, pos).toInt()
    }
}
