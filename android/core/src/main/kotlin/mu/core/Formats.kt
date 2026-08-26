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
)

internal object TagNormalize {
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
