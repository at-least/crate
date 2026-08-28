package mu.core

/**
 * FLAC / Ogg(+Vorbis,Opus) / WAV / MP4(ilst) 容器與註解解析。
 * 一律經 ChunkedReader 只讀結構需要的位元組（model.md §1.8；存取序列即規格）。
 */
internal object ContainerParsers {

    private val FLAC = "fLaC".toByteArray(Charsets.ISO_8859_1)
    private val OGGS = "OggS".toByteArray(Charsets.ISO_8859_1)

    // ---- FLAC ----
    fun flacTags(r: ChunkedReader): Map<String, String>? {
        if (!r.bytes(0, 4).contentEquals(FLAC)) return null
        val comments = LinkedHashMap<String, String>()
        var i = 4L
        while (i + 4 <= r.size) {
            val h = r.bytes(i, 4)
            val last = h[0].toInt() and 0x80 != 0
            val btype = h[0].toInt() and 0x7F
            val blen = Bytes.u24be(h, 1).toLong()
            val start = i + 4
            val end = minOf(r.size, start + blen)
            if (btype == 4 && end > start) { // VORBIS_COMMENT；PICTURE 等跳過
                val block = r.bytes(start, (end - start).toInt())
                vorbisCommentInto(block, 0, block.size, comments)
            }
            if (last) break
            i = start + blen
        }
        return comments
    }

    // ---- Ogg / Opus：前 64KB 視窗 bytewise 掃 magic ----
    fun oggTags(r: ChunkedReader): Map<String, String>? {
        if (r.size < 4) return null
        val window = r.bytes(0, minOf(ChunkedReader.CHUNK, r.size).toInt())
        if (!window.copyOf(4).contentEquals(OGGS)) return null
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
    fun isWav(r: ChunkedReader): Boolean {
        if (r.size < 12) return false
        val h = r.bytes(0, 12)
        return String(h, 0, 4, Charsets.ISO_8859_1) == "RIFF" && String(h, 8, 4, Charsets.ISO_8859_1) == "WAVE"
    }

    // ---- MP4 / M4A：box 巡訪只讀 header，payload 以範圍表示 ----
    class BoxRef(val type: ByteArray, val start: Long, val end: Long)

    fun boxes(r: ChunkedReader, from: Long, to: Long): List<BoxRef> {
        val out = ArrayList<BoxRef>()
        var i = from
        while (i + 8 <= to) {
            val h = r.bytes(i, 8)
            var size = Bytes.u32be(h, 0)
            val type = h.copyOfRange(4, 8)
            var hdr = 8
            if (size == 1L) {
                if (i + 16 > to) break
                val h2 = r.bytes(i + 8, 8)
                size = 0
                for (q in 0 until 8) size = (size shl 8) or (h2[q].toLong() and 0xFF)
                hdr = 16
            } else if (size == 0L) {
                size = to - i
            }
            if (size < hdr || i + size > to) break
            out.add(BoxRef(type, i + hdr, i + size))
            i += size
        }
        return out
    }

    fun m4aTags(r: ChunkedReader): Map<String, String>? {
        var foundMoov = false
        var ilst: BoxRef? = null

        fun walk(from: Long, to: Long, insideMeta: Boolean) {
            for (box in boxes(r, from, to)) {
                val t = String(box.type, Charsets.ISO_8859_1)
                when {
                    t == "moov" -> { foundMoov = true; walk(box.start, box.end, false) }
                    t == "udta" -> walk(box.start, box.end, false)
                    t == "meta" -> if (box.end - box.start > 4) walk(box.start + 4, box.end, true)
                    insideMeta && t == "ilst" -> ilst = box
                }
            }
        }
        walk(0, r.size, false)
        if (!foundMoov) return null
        val il = ilst ?: return linkedMapOf()

        val textKey = mapOf(
            "©nam" to "TITLE", "©ART" to "ARTIST", "©alb" to "ALBUM",
            "aART" to "ALBUMARTIST", "©day" to "YEAR", "cpil" to "COMPILATION",
        )
        val numKey = mapOf("trkn" to "TRACKNUMBER", "disk" to "DISCNUMBER")
        val out = LinkedHashMap<String, String>()
        for (box in boxes(r, il.start, il.end)) {
            val t = String(box.type, Charsets.ISO_8859_1)
            val key = textKey[t]
            val nkey = numKey[t]
            if (key == null && nkey == null) continue
            for (d in boxes(r, box.start, box.end)) {
                if (String(d.type, Charsets.ISO_8859_1) != "data") continue
                val dd = r.bytes(d.start, (d.end - d.start).toInt())
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

    // ---- 時長（model.md §1.7 / §1.8）----

    private val mp3BrM1 = intArrayOf(32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
    private val mp3BrM2 = intArrayOf(8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)

    fun parseDuration(fmt: String, data: ByteArray): Long? = parseDuration(fmt, ChunkedReader(data))

    fun parseDuration(fmt: String, r: ChunkedReader): Long? {
        val size = r.size
        when (fmt) {
            "flac" -> {
                if (size < 8 + 34) return null
                val d = r.bytes(0, 42)
                if (!d.copyOf(4).contentEquals(FLAC) || d[4].toInt() and 0x7F != 0) return null
                val rate = ((d[18].toInt() and 0xFF) shl 12) or
                    ((d[19].toInt() and 0xFF) shl 4) or
                    ((d[20].toInt() and 0xFF) ushr 4)
                var total = (d[21].toInt() and 0xF).toLong() shl 32
                for (q in 0 until 4) total = total or ((d[22 + q].toLong() and 0xFF) shl (24 - 8 * q))
                if (rate == 0 || total == 0L) return null
                return total * 1000 / rate
            }
            "mp3" -> {
                var off = 0L
                if (size >= 3 && String(r.bytes(0, 3), Charsets.ISO_8859_1) == "ID3") {
                    if (size < 10) return null
                    val h = r.bytes(6, 4)
                    off = 10L + (((h[0].toInt() and 0x7F) shl 21) or ((h[1].toInt() and 0x7F) shl 14) or
                        ((h[2].toInt() and 0x7F) shl 7) or (h[3].toInt() and 0x7F))
                }
                val n = (minOf(off + 65536, size - 3) - off).toInt()
                if (n <= 0) return null
                val buf = r.bytes(off, n + 2)
                for (i in 0 until n) {
                    if (buf[i].toInt() and 0xFF == 0xFF && buf[i + 1].toInt() and 0xE0 == 0xE0) {
                        val ver = (buf[i + 1].toInt() shr 3) and 3
                        val layer = (buf[i + 1].toInt() shr 1) and 3
                        val br = (buf[i + 2].toInt() shr 4) and 0xF
                        val sr = (buf[i + 2].toInt() shr 2) and 3
                        if (ver != 1 && layer == 1 && br != 0 && br != 15 && sr != 3) {
                            val kbps = (if (ver == 3) mp3BrM1 else mp3BrM2)[br - 1]
                            return (size - (off + i)) * 8L / kbps
                        }
                    }
                }
                return null
            }
            "m4a" -> {
                fun find(from: Long, to: Long): Pair<Long, Long>? {
                    for (box in boxes(r, from, to)) {
                        val t = String(box.type, Charsets.ISO_8859_1)
                        if (t == "moov") {
                            find(box.start, box.end)?.let { return it }
                        } else if (t == "mvhd") {
                            val len = box.end - box.start
                            val p = r.bytes(box.start, minOf(len, 32L).toInt())
                            if (p.isEmpty()) return null
                            if (p[0].toInt() == 0) {
                                if (len < 20) return null
                                return Bytes.u32be(p, 12) to Bytes.u32be(p, 16)
                            }
                            if (len < 32) return null
                            var dur = 0L
                            for (q in 0 until 8) dur = (dur shl 8) or (p[24 + q].toLong() and 0xFF)
                            return Bytes.u32be(p, 20) to dur
                        }
                    }
                    return null
                }
                val res = find(0, size)
                if (res == null || res.first == 0L || res.second == 0L) return null
                return res.second * 1000 / res.first
            }
            "ogg", "opus" -> {
                val tailOff = maxOf(0L, size - ChunkedReader.CHUNK)
                val tail = r.bytes(tailOff, (size - tailOff).toInt())
                val pRel = lastIndexOf(tail, OGGS)
                if (pRel < 0) return null
                val p = pRel + tailOff
                if (size < p + 14) return null
                val g = r.bytes(p + 6, 8)
                var granule = 0L
                for (q in 0 until 8) granule = granule or ((g[q].toLong() and 0xFF) shl (8 * q))
                val head = r.bytes(0, minOf(ChunkedReader.CHUNK, size).toInt())
                if (fmt == "opus") {
                    val h = indexOf(head, "OpusHead".toByteArray(Charsets.ISO_8859_1))
                    if (h < 0 || size < h + 12) return null
                    val ps = r.bytes(h + 10, 2)
                    val preskip = (ps[0].toLong() and 0xFF) or ((ps[1].toLong() and 0xFF) shl 8)
                    val v = (granule - preskip) * 1000 / 48000
                    return if (v > 0) v else null
                }
                val v = indexOf(head, byteArrayOf(1) + "vorbis".toByteArray(Charsets.ISO_8859_1))
                if (v < 0 || size < v + 16) return null
                val rate = Bytes.u32le(r.bytes(v + 12, 4), 0)
                if (rate == 0L || granule == 0L) return null
                return granule * 1000 / rate
            }
            "wav" -> {
                if (!isWav(r)) return null
                var byteRate = 0L
                var dataSize = -1L
                var i = 12L
                while (i + 8 <= size) {
                    val ch = r.bytes(i, 8)
                    val cid = String(ch, 0, 4, Charsets.ISO_8859_1)
                    val csz = Bytes.u32le(ch, 4)
                    if (cid == "fmt " && csz >= 12) {
                        if (i + 20 <= size) byteRate = Bytes.u32le(r.bytes(i + 16, 4), 0)
                    } else if (cid == "data") {
                        dataSize = csz
                    }
                    i += 8 + csz + (csz and 1)
                }
                if (byteRate == 0L || dataSize < 0L) return null
                return dataSize * 1000 / byteRate
            }
        }
        return null
    }
}
