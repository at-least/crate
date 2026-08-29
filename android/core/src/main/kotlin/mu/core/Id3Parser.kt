package mu.core

/** ID3v2.3 / v2.4 解析（model.md §1.2–1.3；v2.2 → null 走 fallback）。 */
internal object Id3Parser {
    private val FRAME_KEY = mapOf(
        "TIT2" to "TITLE", "TPE1" to "ARTIST", "TALB" to "ALBUM",
        "TPE2" to "ALBUMARTIST", "TRCK" to "TRACKNUMBER", "TPOS" to "DISCNUMBER",
        "TYER" to "YEAR", "TDRC" to "DATE", "TCMP" to "COMPILATION",
        "TCP" to "COMPILATION",
    )

    /** 陣列 API（測試相容）。 */
    fun parse(data: ByteArray): Map<String, String>? = parse(ChunkedReader(data))

    private fun ss(b: ByteArray, o: Int): Long =
        ((b[o].toLong() and 0x7F) shl 21) or ((b[o + 1].toLong() and 0x7F) shl 14) or
            ((b[o + 2].toLong() and 0x7F) shl 7) or (b[o + 3].toLong() and 0x7F)

    /** 只讀 frame header；非關注 frame（APIC 等）以 size 跳過（model.md §1.8）。 */
    fun parse(r: ChunkedReader): Map<String, String>? {
        if (r.size < 10) return null
        val h = r.bytes(0, 10)
        if (h[0] != 'I'.code.toByte() || h[1] != 'D'.code.toByte() || h[2] != '3'.code.toByte()) return null
        val verMajor = h[3].toInt() and 0xFF
        val flags = h[5].toInt() and 0xFF
        var bodyStart = 10L
        val bodyEnd = minOf(r.size, 10 + ss(h, 6))
        if (verMajor !in 3..4) return null
        if (flags and 0x40 != 0) { // extended header
            if (bodyEnd - bodyStart < 4) return null
            val e = r.bytes(bodyStart, 4)
            val ext = if (verMajor == 3) Bytes.u32be(e, 0) + 4 else ss(e, 0)
            bodyStart = minOf(bodyEnd, bodyStart + ext)
        }
        val out = LinkedHashMap<String, String>()
        var i = bodyStart
        while (i + 10 <= bodyEnd) {
            val fh = r.bytes(i, 10)
            val fid = String(fh, 0, 4, Charsets.ISO_8859_1)
            if (fid == "\u0000\u0000\u0000\u0000") break
            val fsize = if (verMajor == 3) Bytes.u32be(fh, 4) else ss(fh, 4)
            val fStart = i + 10
            val fEnd = minOf(bodyEnd, fStart + fsize)
            val key = FRAME_KEY[fid]
            if (key != null && fEnd > fStart) {
                val fdata = r.bytes(fStart, (fEnd - fStart).toInt())
                val enc = fdata[0].toInt() and 0xFF
                val rawEnd = indexOfNul(fdata, 1, fdata.size)
                val raw = fdata.copyOfRange(1, rawEnd)
                val value = decodeText(enc, raw).trimContract()
                if (value.isNotEmpty() && !out.containsKey(key)) out[key] = value
            } else if (fid == "TXXX" && fEnd > fStart) { // §1.9：description 決定鍵
                val fdata = r.bytes(fStart, (fEnd - fStart).toInt())
                val enc = fdata[0].toInt() and 0xFF
                val (descB, rest) = splitNul(fdata.copyOfRange(1, fdata.size), enc)
                val k = decodeText(enc, descB).trimContract().uppercase()
                if (k in TagNormalize.RG_KEYS) {
                    val (valB, _) = splitNul(rest, enc)
                    val value = decodeText(enc, valB).trimContract()
                    if (value.isNotEmpty() && !out.containsKey(k)) out[k] = value
                }
            }
            i = fStart + fsize
        }
        return out
    }

    /** 依編碼切第一個終止符：Latin-1/UTF-8 = 1 NUL；UTF-16 = 對齊的 00 00。回 (前段, 後段)。 */
    fun splitNul(raw: ByteArray, enc: Int): Pair<ByteArray, ByteArray> {
        if (enc == 1 || enc == 2) {
            var i = 0
            while (i + 1 < raw.size) {
                if (raw[i].toInt() == 0 && raw[i + 1].toInt() == 0)
                    return raw.copyOfRange(0, i) to raw.copyOfRange(i + 2, raw.size)
                i += 2
            }
            return raw to ByteArray(0)
        }
        val i = raw.indexOfFirst { it.toInt() == 0 }
        return if (i < 0) raw to ByteArray(0) else raw.copyOfRange(0, i) to raw.copyOfRange(i + 1, raw.size)
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
