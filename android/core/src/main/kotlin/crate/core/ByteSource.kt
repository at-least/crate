package crate.core

import java.io.File
import java.io.RandomAccessFile

/**
 * 掃描器的輸入（model.md §1.8）：size + read(offset, length)（裁切到 size）。
 * 雲端 read 可拋 [ProviderException]（NotFound = 讀取中檔案消失 → 引擎靜默丟棄；其他 → 續掃）。
 */
interface ByteSource {
    val size: Long
    fun read(offset: Long, length: Int): ByteArray
}

/** 記憶體來源（測試 / 陣列 API 相容包裝）。 */
class MemorySource(private val data: ByteArray) : ByteSource {
    override val size: Long get() = data.size.toLong()
    override fun read(offset: Long, length: Int): ByteArray {
        if (offset >= data.size || length <= 0) return ByteArray(0)
        val a = offset.toInt()
        return data.copyOfRange(a, minOf(data.size, a + length))
    }
}

/** 本地檔案來源（open 時取 size；讀取中檔案消失 → NotFound）。 */
class FileSource private constructor(private val file: File, override val size: Long) : ByteSource {
    companion object {
        /** 不存在 → null。 */
        fun open(file: File): FileSource? = if (file.isFile) FileSource(file, file.length()) else null
    }

    override fun read(offset: Long, length: Int): ByteArray {
        val raf = try {
            RandomAccessFile(file, "r")
        } catch (e: java.io.FileNotFoundException) {
            throw ProviderException.NotFound()
        }
        raf.use {
            it.seek(offset)
            val buf = ByteArray(length)
            var n = 0
            while (n < length) {
                val got = it.read(buf, n, length - n)
                if (got < 0) break
                n += got
            }
            return if (n == length) buf else buf.copyOf(n)
        }
    }
}

/** 64 KiB 對齊 chunk、每 chunk 抓一次（快取）；三實作同算法 → 觸碰 chunk 集合一致（model.md §1.8）。 */
class ChunkedReader(private val src: ByteSource) {
    companion object {
        const val CHUNK = 65536L
    }

    val size: Long = src.size
    private val chunks = HashMap<Long, ByteArray>()
    var fetches = 0; private set

    constructor(bytes: ByteArray) : this(MemorySource(bytes))

    /** [offset, offset+length) 裁切到 size；越界/空 → 空陣列。 */
    fun bytes(off: Long, length: Int): ByteArray {
        if (off < 0 || off >= size || length <= 0) return ByteArray(0)
        val end = minOf(size, off + length)
        val out = java.io.ByteArrayOutputStream((end - off).toInt())
        for (k in (off / CHUNK)..((end - 1) / CHUNK)) {
            val data = chunks.getOrPut(k) {
                val start = k * CHUNK
                fetches++
                src.read(start, minOf(CHUNK, size - start).toInt())
            }
            val a = (maxOf(off, k * CHUNK) - k * CHUNK).toInt()
            val b = (minOf(end, (k + 1) * CHUNK) - k * CHUNK).toInt()
            if (a < b && b <= data.size) out.write(data, a, b - a)
        }
        return out.toByteArray()
    }

    fun bytes(off: Int, length: Int): ByteArray = bytes(off.toLong(), length)
}
