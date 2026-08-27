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

    private fun lastIndexOf(hay: ByteArray, needle: ByteArray): Int {
        if (needle.isEmpty() || hay.size < needle.size) return -1
        for (i in hay.size - needle.size downTo 0) {
            var ok = true
            for (j in needle.indices) if (hay[i + j] != needle[j]) { ok = false; break }
            if (ok) return i
        }
        return -1
    }

    // ---- 時長（model.md §1.7）----

    private val mp3BrM1 = intArrayOf(32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
    private val mp3BrM2 = intArrayOf(8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)

    fun parseDuration(fmt: String, data: ByteArray): Long? {
        when (fmt) {
            "flac" -> {
                if (data.size < 4 || String(data, 0, 4, Charsets.ISO_8859_1) != "fLaC") return null
                if (data.size < 8 + 34 || data[4].toInt() and 0x7F != 0) return null
                val rate = ((data[18].toInt() and 0xFF) shl 12) or
                    ((data[19].toInt() and 0xFF) shl 4) or
                    ((data[20].toInt() and 0xFF) ushr 4)
                var total = (data[21].toInt() and 0xF).toLong() shl 32
                for (q in 0 until 4) total = total or ((data[22 + q].toLong() and 0xFF) shl (24 - 8 * q))
                if (rate == 0 || total == 0L) return null
                return total * 1000 / rate
            }
            "mp3" -> {
                var off = 0
                if (data.size >= 3 && String(data, 0, 3, Charsets.ISO_8859_1) == "ID3") {
                    if (data.size < 10) return null
                    off = 10 + (((data[6].toInt() and 0x7F) shl 21) or
                        ((data[7].toInt() and 0x7F) shl 14) or
                        ((data[8].toInt() and 0x7F) shl 7) or (data[9].toInt() and 0x7F))
                }
                var i = off
                val end = minOf(off + 65536, data.size - 3)
                while (i < end) {
                    if (data[i].toInt() and 0xFF == 0xFF && data[i + 1].toInt() and 0xE0 == 0xE0) {
                        val ver = (data[i + 1].toInt() shr 3) and 3
                        val layer = (data[i + 1].toInt() shr 1) and 3
                        val br = (data[i + 2].toInt() shr 4) and 0xF
                        val sr = (data[i + 2].toInt() shr 2) and 3
                        if (ver != 1 && layer == 1 && br != 0 && br != 15 && sr != 3) {
                            val kbps = (if (ver == 3) mp3BrM1 else mp3BrM2)[br - 1]
                            return (data.size - i) * 8L / kbps
                        }
                    }
                    i++
                }
                return null
            }
            "m4a" -> {
                fun find(buf: ByteArray): Pair<Long, Long>? {
                    for (box in boxes(buf)) {
                        val t = String(box.type, Charsets.ISO_8859_1)
                        if (t == "moov") {
                            find(box.payload)?.let { return it }
                        } else if (t == "mvhd") {
                            val p = box.payload
                            if (p.isEmpty()) return null
                            if (p[0].toInt() == 0) {
                                if (p.size < 20) return null
                                return Bytes.u32be(p, 12) to Bytes.u32be(p, 16)
                            }
                            if (p.size < 32) return null
                            var dur = 0L
                            for (q in 0 until 8) dur = (dur shl 8) or (p[24 + q].toLong() and 0xFF)
                            return Bytes.u32be(p, 20) to dur
                        }
                    }
                    return null
                }
                val r = find(data)
                if (r == null || r.first == 0L || r.second == 0L) return null
                return r.second * 1000 / r.first
            }
            "ogg", "opus" -> {
                val p = lastIndexOf(data, "OggS".toByteArray(Charsets.ISO_8859_1))
                if (p < 0 || data.size < p + 14) return null
                var granule = 0L
                for (q in 0 until 8) granule = granule or ((data[p + 6 + q].toLong() and 0xFF) shl (8 * q))
                if (fmt == "opus") {
                    val h = indexOf(data, "OpusHead".toByteArray(Charsets.ISO_8859_1))
                    if (h < 0 || data.size < h + 12) return null
                    val preskip = (data[h + 10].toLong() and 0xFF) or
                        ((data[h + 11].toLong() and 0xFF) shl 8)
                    val v = (granule - preskip) * 1000 / 48000
                    return if (v > 0) v else null
                }
                val v = indexOf(data, byteArrayOf(1) + "vorbis".toByteArray(Charsets.ISO_8859_1))
                if (v < 0 || data.size < v + 16) return null
                val rate = Bytes.u32le(data, v + 12)
                if (rate == 0L || granule == 0L) return null
                return granule * 1000 / rate
            }
            "wav" -> {
                if (!isWav(data)) return null
                var byteRate = 0L
                var dataSize = -1L
                var i = 12
                while (i + 8 <= data.size) {
                    val cid = String(data, i, 4, Charsets.ISO_8859_1)
                    val csz = Bytes.u32le(data, i + 4).toInt()
                    if (cid == "fmt " && csz >= 12) byteRate = Bytes.u32le(data, i + 16)
                    else if (cid == "data") dataSize = csz.toLong()
                    i += 8 + csz + (csz and 1)
                }
                if (byteRate == 0L || dataSize < 0L) return null
                return dataSize * 1000 / byteRate
            }
        }
        return null
    }
}
