package mu.core

/**
 * Canonical JSON 寫出器（model.md §2.2）。
 * 規則：鍵按 codepoint 排序、2 空格縮排、LF、檔尾一個 \n、
 * 短轉義 + \u00xx 小寫、非 ASCII 原樣、errors[].message 恆為 ""（契約豁免）。
 */
object CanonicalJson {

    fun render(value: Any?): String {
        val sb = StringBuilder()
        renderValue(value, 0, sb)
        sb.append('\n')
        return sb.toString()
    }

    private fun renderValue(v: Any?, indent: Int, sb: StringBuilder) {
        when (v) {
            null -> sb.append("null")
            is Boolean -> sb.append(v.toString())
            is Int -> sb.append(v.toString())
            is Long -> sb.append(v.toString())
            is String -> escape(v, sb)
            is List<*> -> renderList(v, indent, sb)
            is Map<*, *> -> renderMap(v, indent, sb)
            else -> throw IllegalArgumentException("unsupported: ${v::class}")
        }
    }

    private fun renderList(list: List<*>, indent: Int, sb: StringBuilder) {
        if (list.isEmpty()) {
            sb.append("[]")
            return
        }
        sb.append("[\n")
        for (i in list.indices) {
            indentStr(indent + 1, sb)
            renderValue(list[i], indent + 1, sb)
            if (i != list.size - 1) sb.append(',')
            sb.append('\n')
        }
        indentStr(indent, sb)
        sb.append(']')
    }

    private fun renderMap(map: Map<*, *>, indent: Int, sb: StringBuilder) {
        if (map.isEmpty()) {
            sb.append("{}")
            return
        }
        @Suppress("UNCHECKED_CAST")
        val sorted = (map as Map<String, Any?>).toSortedMap { a, b -> codePointCompare(a, b) }
        sb.append("{\n")
        val keys = sorted.keys.toList()
        for (i in keys.indices) {
            val k = keys[i]
            indentStr(indent + 1, sb)
            escape(k, sb)
            sb.append(": ")
            renderValue(sorted[k], indent + 1, sb)
            if (i != keys.size - 1) sb.append(',')
            sb.append('\n')
        }
        indentStr(indent, sb)
        sb.append('}')
    }

    private fun indentStr(n: Int, sb: StringBuilder) {
        repeat(n * 2) { sb.append(' ') }
    }

    private fun escape(s: String, sb: StringBuilder) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else ->
                    if (c.code < 0x20) {
                        sb.append("\\u").append(c.code.toString(16).padStart(4, '0'))
                    } else {
                        sb.append(c)
                    }
            }
        }
        sb.append('"')
    }

    // ---- ScanResult → canonical map ----

    fun Scanner.ScanResult.toCanonical(): Map<String, Any?> = linkedMapOf(
        "albums" to albums.map { it.toCanonical() },
        "errors" to errors.map { it.toCanonical() },
        "playlists" to playlists.map { it.toCanonical() },
        "tracks" to tracks.map { it.toCanonical() },
    )

    private fun Scanner.Album.toCanonical(): Map<String, Any?> = linkedMapOf(
        "albumArtist" to albumArtist,
        "artTrackId" to artTrackId,
        "compilation" to compilation,
        "id" to id,
        "name" to name,
        "trackCount" to trackCount,
        "year" to year,
    )

    private fun Scanner.ScanError.toCanonical(): Map<String, Any?> = linkedMapOf(
        "code" to code,
        "message" to "", // 契約豁免：實作自由文字不參與比對
        "path" to path,
    )

    private fun Scanner.Playlist.toCanonical(): Map<String, Any?> = linkedMapOf(
        "id" to id,
        "items" to items.map {
            linkedMapOf<String, Any?>(
                "durationMs" to it.durationMs,
                "missing" to it.missing,
                "position" to it.position,
                "ref" to it.ref,
                "trackId" to it.trackId,
            )
        },
        "name" to name,
        "path" to path,
    )

    private fun Scanner.Track.toCanonical(): Map<String, Any?> = linkedMapOf(
        "album" to album,
        "albumArtist" to albumArtist,
        "albumId" to albumId,
        "artist" to artist,
        "disc" to disc,
        "durationMs" to null, // v0 固定 null（model.md §2.1）
        "format" to format,
        "id" to id,
        "path" to path,
        "sizeBytes" to sizeBytes,
        "tagOk" to tagOk,
        "title" to title,
        "trackNo" to trackNo,
        "year" to year,
    )
}
