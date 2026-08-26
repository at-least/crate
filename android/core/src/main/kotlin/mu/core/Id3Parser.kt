package mu.core

/** ID3v2.3 / v2.4 解析（model.md §1.2–1.3；v2.2 → null 走 fallback）。 */
internal object Id3Parser {
    private val FRAME_KEY = mapOf(
        "TIT2" to "TITLE", "TPE1" to "ARTIST", "TALB" to "ALBUM",
        "TPE2" to "ALBUMARTIST", "TRCK" to "TRACKNUMBER", "TPOS" to "DISCNUMBER",
        "TYER" to "YEAR", "TDRC" to "DATE", "TCMP" to "COMPILATION",
        "TCP" to "COMPILATION",
    )

    fun parse(data: ByteArray): Map<String, String>? {
        if (data.size < 10) return null
        if (data[0] != 'I'.code.toByte() || data[1] != 'D'.code.toByte() ||
            data[2] != '3'.code.toByte()
        ) return null
        val verMajor = data[3].toInt() and 0xFF
        val flags = data[5].toInt() and 0xFF
        val size = ((data[6].toLong() and 0x7F) shl 21) or ((data[7].toLong() and 0x7F) shl 14) or
            ((data[8].toLong() and 0x7F) shl 7) or (data[9].toLong() and 0x7F)
        var body = data.copyOfRange(10, minOf(data.size, (10 + size).toInt()))
        if (verMajor !in 3..4) return null
        if (flags and 0x40 != 0) { // extended header
            if (body.size < 4) return null
            val ext = if (verMajor == 3) {
                Bytes.u32be(body, 0).toInt() + 4
            } else {
                ((body[0].toLong() and 0x7F) shl 21) or ((body[1].toLong() and 0x7F) shl 14) or
                    ((body[2].toLong() and 0x7F) shl 7) or (body[3].toLong() and 0x7F)
            }.toInt()
            body = if (ext < body.size) body.copyOfRange(ext, body.size) else ByteArray(0)
        }
        val out = LinkedHashMap<String, String>()
        var i = 0
        while (i + 10 <= body.size) {
            val fid = String(body, i, 4, Charsets.ISO_8859_1)
            if (fid == "\u0000\u0000\u0000\u0000") break
            val fsize = if (verMajor == 3) {
                Bytes.u32be(body, i + 4).toInt()
            } else {
                ((body[i + 4].toLong() and 0x7F) shl 21) or ((body[i + 5].toLong() and 0x7F) shl 14) or
                    ((body[i + 6].toLong() and 0x7F) shl 7) or (body[i + 7].toLong() and 0x7F)
            }.toInt()
            if (fsize < 0) break
            val fdataStart = i + 10
            val fdataEnd = minOf(body.size, fdataStart + fsize)
            val key = FRAME_KEY[fid]
            if (key != null && fdataEnd > fdataStart) {
                val enc = body[fdataStart].toInt() and 0xFF
                val rawEnd = indexOfNul(body, fdataStart + 1, fdataEnd)
                val raw = body.copyOfRange(fdataStart + 1, rawEnd)
                val value = decodeText(enc, raw).trimContract()
                if (value.isNotEmpty() && !out.containsKey(key)) out[key] = value
            }
            i = fdataStart + fsize
        }
        return out
    }

    /** 只取第一個 NUL 結尾字串（沒有 NUL → 到結尾）。 */
    private fun indexOfNul(b: ByteArray, from: Int, to: Int): Int {
        for (j in from until to) if (b[j].toInt() == 0) return j
        return to
    }

    private fun String.trimContract(): String = trim(*" \t\r\n\u0000".toCharArray())

    fun decodeText(enc: Int, raw: ByteArray): String = when (enc) {
        0 -> String(raw, Charsets.ISO_8859_1)
        1 -> {
            if (raw.size < 2 || raw.size % 2 != 0) ""
            else when {
                raw[0] == 0xFF.toByte() && raw[1] == 0xFE.toByte() ->
                    String(raw, 2, raw.size - 2, Charsets.UTF_16LE)
                raw[0] == 0xFE.toByte() && raw[1] == 0xFF.toByte() ->
                    String(raw, 2, raw.size - 2, Charsets.UTF_16BE)
                raw[0].toInt() == 0 -> String(raw, Charsets.UTF_16BE)
                else -> String(raw, Charsets.UTF_16LE)
            }
        }
        2 -> if (raw.size % 2 != 0) "" else String(raw, Charsets.UTF_16BE)
        3 -> String(raw, Charsets.UTF_8)
        else -> ""
    }
}
