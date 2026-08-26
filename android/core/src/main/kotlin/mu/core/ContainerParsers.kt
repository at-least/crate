package mu.core

/** FLAC / Ogg(+Vorbis,Opus) / WAV / MP4(ilst) 容器與註解解析。 */
internal object ContainerParsers {

    // ---- FLAC ----
    fun flacTags(data: ByteArray): Map<String, String>? {
        if (data.size < 4 || data[0] != 'f'.code.toByte() || data[1] != 'L'.code.toByte() ||
            data[2] != 'a'.code.toByte() || data[3] != 'C'.code.toByte()
        ) return null
        val comments = LinkedHashMap<String, String>()
        var i = 4
        while (i + 4 <= data.size) {
            val last = data[i].toInt() and 0x80 != 0
            val btype = data[i].toInt() and 0x7F
            val blen = Bytes.u24be(data, i + 1)
            val start = i + 4
            val end = minOf(data.size, start + blen)
            if (btype == 4 && end > start) {
                vorbisCommentInto(data, start, end, comments)
            }
            if (last) break
            i = start + blen
            if (blen < 0) break
        }
        return comments
    }

    // ---- Ogg / Opus：前 64KB bytewise 掃 magic（fixtures/README 已釘死） ----
    fun oggTags(data: ByteArray): Map<String, String>? {
        if (data.size < 4 || String(data, 0, 4, Charsets.ISO_8859_1) != "OggS") return null
        val window = data.copyOf(minOf(data.size, 65536))
        val posOpus = indexOf(window, "OpusTags".toByteArray(Charsets.ISO_8859_1))
        val posVorbis = indexOf(window, byteArrayOf(3) + "vorbis".toByteArray(Charsets.ISO_8859_1))
        return when {
            posOpus >= 0 -> LinkedHashMap<String, String>().also {
                vorbisCommentInto(window, posOpus + 8, window.size, it)
            }
            posVorbis >= 0 -> LinkedHashMap<String, String>().also {
                vorbisCommentInto(window, posVorbis + 7, window.size, it)
            }
            else -> linkedMapOf()
        }
    }

    private fun vorbisCommentInto(b: ByteArray, from: Int, to: Int, out: LinkedHashMap<String, String>) {
        var j = from
        if (j + 4 > to) return
        val vendorLen = Bytes.u32le(b, j).toInt()
        j += 4
        if (vendorLen < 0 || j + vendorLen + 4 > to) return
        j += vendorLen
        val count = Bytes.u32le(b, j).toInt()
        j += 4
        if (count < 0) return
        repeat(count) {
            if (j + 4 > to) return
            val vlen = Bytes.u32le(b, j).toInt()
            j += 4
            if (vlen < 0 || j + vlen > to) return
            val kv = String(b, j, vlen, Charsets.UTF_8)
            j += vlen
            val eq = kv.indexOf('=')
            if (eq > 0) {
                val k = kv.substring(0, eq).uppercase()
                val v = kv.substring(eq + 1).trim(*" \t\r\n\u0000".toCharArray())
                if (!out.containsKey(k)) out[k] = v
            }
        }
    }

    // ---- WAV ----
    fun isWav(data: ByteArray): Boolean =
        data.size >= 12 && String(data, 0, 4, Charsets.ISO_8859_1) == "RIFF" &&
            String(data, 8, 4, Charsets.ISO_8859_1) == "WAVE"

    // ---- MP4 / M4A ilst ----
    private class Box(val type: ByteArray, val payload: ByteArray)

    private fun boxes(buf: ByteArray, from: Int = 0, to: Int = buf.size): List<Box> {
        val out = ArrayList<Box>()
        var i = from
        while (i + 8 <= to) {
            var size = Bytes.u32be(buf, i)
            val type = buf.copyOfRange(i + 4, i + 8)
            var hdr = 8
            if (size == 1L) {
                if (i + 16 > to) break
                size = 0
                for (q in 0 until 8) size = (size shl 8) or (buf[i + 8 + q].toLong() and 0xFF)
                hdr = 16
            } else if (size == 0L) {
                size = (to - i).toLong()
            }
            if (size < hdr || i + size > to) break
            out.add(Box(type, buf.copyOfRange(i + hdr, i + size.toInt())))
            i += size.toInt()
        }
        return out
    }

    fun m4aTags(data: ByteArray): Map<String, String>? {
        var foundMoov = false
        var ilst: ByteArray? = null

        fun walk(buf: ByteArray, insideMeta: Boolean) {
            for (box in boxes(buf)) {
                val t = String(box.type, Charsets.ISO_8859_1)
                when {
                    t == "moov" -> { foundMoov = true; walk(box.payload, false) }
                    t == "udta" -> walk(box.payload, false)
                    t == "meta" && box.payload.size > 4 ->
                        walk(box.payload.copyOfRange(4, box.payload.size), true)
                    insideMeta && t == "ilst" -> ilst = box.payload
                }
            }
        }
        walk(data, false)
        if (!foundMoov) return null
        val payload = ilst ?: return linkedMapOf()

        val textKey = mapOf(
            "©nam" to "TITLE", "©ART" to "ARTIST", "©alb" to "ALBUM",
            "aART" to "ALBUMARTIST", "©day" to "YEAR", "cpil" to "COMPILATION",
        )
        val numKey = mapOf("trkn" to "TRACKNUMBER", "disk" to "DISCNUMBER")
        val out = LinkedHashMap<String, String>()
        for (box in boxes(payload)) {
            val t = String(box.type, Charsets.ISO_8859_1)
            val key = textKey[t]
            val nkey = numKey[t]
            for (d in boxes(box.payload)) {
                if (String(d.type, Charsets.ISO_8859_1) != "data") continue
                val dd = d.payload
                if (key != null && dd.size >= 9) {
                    val v = String(dd, 8, dd.size - 8, Charsets.UTF_8).trim(*" \t\r\n\u0000".toCharArray())
                    if (v.isNotEmpty() && !out.containsKey(key)) out[key] = v
                } else if (nkey != null && dd.size >= 6) {
                    val n = Bytes.u16be(dd, 4)
                    if (n != 0 && !out.containsKey(nkey)) out[nkey] = n.toString()
                }
            }
        }
        return out
    }

    private fun indexOf(hay: ByteArray, needle: ByteArray): Int {
        outer@ for (i in 0..hay.size - needle.size) {
            for (j in needle.indices) if (hay[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }
}
