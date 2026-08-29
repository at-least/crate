package mu.core

/** 正規化 tag 欄位（model.md §1.2）。空字串 = 缺失。 */
internal data class TagFields(
    val title: String?,
    val artist: String?,
    val albumArtist: String?,
    val album: String?,
    val trackNo: Int?,
    val disc: Int?,
    val year: Int?,
    val compilation: Boolean,
    val rgTrackMb: Int? = null,
    val rgAlbumMb: Int? = null,
)

internal object TagNormalize {
    val RG_KEYS = setOf("REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN")

    /** model.md §1.9：'-6.54 dB' → -654；無浮點；無整數位數字 → null。 */
    fun parseGainMb(s: String?): Int? {
        if (s == null) return null
        val t = s.trim()
        var i = 0
        var sign = 1
        if (i < t.length && (t[i] == '+' || t[i] == '-')) { sign = if (t[i] == '-') -1 else 1; i++ }
        var j = i
        while (j < t.length && t[j] in '0'..'9') j++
        if (j == i) return null
        val whole = t.substring(i, j).toInt()
        var frac = 0
        if (j < t.length && t[j] == '.') {
            var k = j + 1
            val digits = StringBuilder()
            while (k < t.length && t[k] in '0'..'9' && digits.length < 2) { digits.append(t[k]); k++ }
            frac = (digits.toString() + "00").substring(0, 2).toInt()
        }
        return sign * (whole * 100 + frac)
    }

    private fun num(s: String?): Int? {
        if (s.isNullOrEmpty()) return null
        val head = s.takeWhile { it.isDigit() }
        return head.toIntOrNull()
    }

    fun from(tags: Map<String, String>): TagFields {
        fun f(k: String) = tags[k]?.takeIf { it.isNotEmpty() }
        val y = f("YEAR") ?: f("DATE")
        return TagFields(
            title = f("TITLE"),
            artist = f("ARTIST"),
            albumArtist = f("ALBUMARTIST"),
            album = f("ALBUM"),
            trackNo = num(tags["TRACKNUMBER"]),
            disc = num(tags["DISCNUMBER"]),
            year = y?.takeIf { it.length >= 4 && it.take(4).all { c -> c.isDigit() } }
                ?.substring(0, 4)?.toInt(),
            compilation = tags["COMPILATION"] == "1",
            rgTrackMb = parseGainMb(tags["REPLAYGAIN_TRACK_GAIN"]),
            rgAlbumMb = parseGainMb(tags["REPLAYGAIN_ALBUM_GAIN"]),
        )
    }
}

/** 副檔名 → format（model.md §1.1）。非音訊 → null（靜默略過）。 */
internal fun formatFor(name: String): String? {
    val ext = if (name.contains('.')) name.substringAfterLast('.') else ""
    return when (ext.lowercase()) {
        "flac" -> "flac"
        "mp3" -> "mp3"
        "m4a", "mp4" -> "m4a"
        "ogg" -> "ogg"
        "opus" -> "opus"
        "wav" -> "wav"
        else -> null
    }
}
