package mu.core

import java.io.File

/**
 * 本地資料夾 provider（provider.md §6）。
 * sync 契約（sync-rules.md §3）用到的面：snapshot 快照 + 檔案讀取；
 * listDir 等其餘介面隨 FakeProvider 子步驟的錯誤語意契約一併補上（putText 已於 D12 移除）。
 */
class LocalFolderProvider(private val root: File) {

    /** path -> rev（"{size}:{mtimeMs}"）。全部檔案（含非音訊；過濾是引擎的事）。 */
    fun snapshot(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        if (!root.isDirectory) return out
        root.walkTopDown()
            .filter { it.isFile }
            .map { it.relativeTo(root).invariantSeparatorsPath }
            .sorted()
            .forEach { rel ->
                val f = File(root, rel)
                out[rel] = "${f.length()}:${f.lastModified()}"
            }
        return out
    }

    /** 掃描用讀檔；不存在 → null（引擎靜默丟棄，sync-rules §3.2-4）。 */
    fun readBytes(path: String): ByteArray? {
        val f = File(root, path)
        return if (f.isFile) f.readBytes() else null
    }
}
