package crate.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * 同步引擎契約測試：跑 contract/fixtures/sync_cases/ 全部案例。
 * 驅動 = script.json 步驟 → 真實暫存目錄樹（顯式 mtime）→ 每步一輪 sync()；
 * Kotlin 引擎輸出必須與 Python 參考實作的 expected.json byte-identical（sync-rules.md §3）。
 */
class SyncFixtureTest {

    @Test
    fun `all sync fixture cases match expected json byte for byte`() {
        val casesDir = findDir("contract/fixtures/sync_cases") ?: fail("sync_cases not found")
        val assetsDir = findDir("contract/fixtures/sync_assets") ?: fail("sync_assets not found")
        val names = casesDir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted()
            ?: fail("cannot list $casesDir")
        assertTrue(names.size >= 6, "expected >=6 sync cases, got ${names.size}")

        val failures = ArrayList<String>()
        for (name in names) {
            val caseDir = File(casesDir, name)
            val expected = File(caseDir, "expected.json").readBytes()
            val script = Json.parseToJsonElement(
                File(caseDir, "script.json").readText()).jsonObject
            val tmp = createTempDirectory("crate-sync-").toFile()
            try {
                val root = File(tmp, "lib").apply { mkdirs() }
                val engine = SyncEngine(LocalFolderProvider(root))
                val reports = ArrayList<Map<String, Any?>>()
                for (step in script["steps"]!!.jsonArray) {
                    val deleteAfter = ArrayList<String>()
                    for (opEl in step.jsonObject["ops"]!!.jsonArray) {
                        applyOp(root, assetsDir, opEl.jsonObject, deleteAfter)
                    }
                    val r = engine.sync(
                        afterDelta = if (deleteAfter.isEmpty()) null else {
                            { deleteAfter.forEach { File(root, it).delete() } }
                        })
                    reports.add(engine.toCanonical(r))
                }
                val actual = CanonicalJson.render(reports).toByteArray(Charsets.UTF_8)
                if (!expected.contentEquals(actual)) {
                    failures.add(
                        "case [$name]\n--- expected ---\n${expected.decodeToString()}\n" +
                            "--- actual ---\n${actual.decodeToString()}"
                    )
                }
            } finally {
                tmp.deleteRecursively()
            }
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size}/${names.size} sync cases drifted:\n\n" +
                failures.joinToString("\n\n========\n\n"))
        }
    }

    private fun applyOp(
        root: File, assetsDir: File,
        op: JsonObject, deleteAfter: MutableList<String>,
    ) {
        fun s(k: String) = op[k]!!.jsonPrimitive.content
        when (val k = s("op")) {
            "write" -> {
                val p = File(root, s("path"))
                p.parentFile?.mkdirs()
                val data = op["asset"]?.jsonPrimitive?.content
                    ?.let { File(assetsDir, it).readBytes() }
                    ?: op["text"]!!.jsonPrimitive.content.toByteArray(Charsets.UTF_8)
                p.writeBytes(data)
                p.setLastModified(op["mtime"]!!.jsonPrimitive.long * 1000)
            }
            "delete" -> File(root, s("path")).delete()
            "rename" -> {
                val dst = File(root, s("to"))
                dst.parentFile?.mkdirs()
                File(root, s("from")).renameTo(dst)
            }
            "touch" -> File(root, s("path"))
                .setLastModified(op["mtime"]!!.jsonPrimitive.long * 1000)
            "delete_after_delta" -> deleteAfter.add(s("path"))
            else -> fail("unknown op: $k")
        }
    }

    private fun findDir(rel: String): File? {
        var dir = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val c = File(dir, rel)
            if (c.isDirectory) return c
            dir = dir.parentFile
        }
        return null
    }
}
