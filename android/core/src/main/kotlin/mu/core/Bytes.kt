package mu.core

/** 位元組讀取 helper — 一律顯式端序（model.md §4）。 */
internal object Bytes {
    fun u16be(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 8) or (b[off + 1].toInt() and 0xFF)

    fun u24be(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 16) or ((b[off + 1].toInt() and 0xFF) shl 8) or
            (b[off + 2].toInt() and 0xFF)

    fun u32be(b: ByteArray, off: Int): Long =
        ((b[off].toLong() and 0xFF) shl 24) or ((b[off + 1].toLong() and 0xFF) shl 16) or
            ((b[off + 2].toLong() and 0xFF) shl 8) or (b[off + 3].toLong() and 0xFF)

    fun u32le(b: ByteArray, off: Int): Long =
        ((b[off + 3].toLong() and 0xFF) shl 24) or ((b[off + 2].toLong() and 0xFF) shl 16) or
            ((b[off + 1].toLong() and 0xFF) shl 8) or (b[off].toLong() and 0xFF)
}

/** 以 Unicode codepoint 比較（避免 UTF-16 代理對順序差異）。 */
internal fun codePointCompare(a: String, b: String): Int {
    val ca = a.codePoints().toArray()
    val cb = b.codePoints().toArray()
    val n = minOf(ca.size, cb.size)
    for (i in 0 until n) {
        if (ca[i] != cb[i]) return ca[i].compareTo(cb[i])
    }
    return ca.size - cb.size
}
