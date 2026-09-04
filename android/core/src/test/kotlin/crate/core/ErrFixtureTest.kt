package crate.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * 錯誤語意契約測試：跑 contract/fixtures/err_cases/。
 * RetryPolicy 輸出必須與 Python 參考實作 byte-identical（provider.md §2.1）。
 */
class ErrFixtureTest {

    @Test
    fun `all err fixture cases match expected json byte for byte`() {
        val casesDir = findDir("contract/fixtures/err_cases") ?: fail("err_cases not found")
        val names = casesDir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted()
            ?: fail("cannot list $casesDir")
        assertTrue(names.isNotEmpty())

        val failures = ArrayList<String>()
        for (name in names) {
            val caseDir = File(casesDir, name)
            val expected = File(caseDir, "expected.json").readBytes()
            val script = Json.parseToJsonElement(
                File(caseDir, "script.json").readText()).jsonObject
            val out = ArrayList<Map<String, Any?>>()
            for (e in script["entries"]!!.jsonArray.map { it.jsonObject }) {
                if (e["type"]!!.jsonPrimitive.content != "retry") {
                    fail("unknown entry type in case [$name]")
                }
                val queue = e["script"]!!.jsonArray
                    .map { it.jsonPrimitive.content }.toMutableList()
                val o = RetryPolicy.run(
                    op = {
                        when (val s = queue.removeFirstOrNull()) {
                            null, "ok" -> null
                            else -> RetryPolicy.kindFromJson(s)
                        }
                    },
                    onReauth = { },
                    sleep = { /* 收集在 Outcome.sleeps */ },
                )
                out.add(linkedMapOf<String, Any?>(
                    "reauths" to o.reauths, "result" to o.result, "sleeps" to o.sleeps))
            }
            val actual = CanonicalJson.render(out).toByteArray(Charsets.UTF_8)
            if (!expected.contentEquals(actual)) {
                failures.add("case [$name]\n--- expected ---\n${expected.decodeToString()}\n" +
                    "--- actual ---\n${actual.decodeToString()}")
            }
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size}/${names.size} err cases drifted:\n\n" +
                failures.joinToString("\n\n========\n\n"))
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
