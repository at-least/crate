package mu.core

import mu.core.CanonicalJson.render
import mu.core.CanonicalJson.toCanonical
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * 契約測試：跑 contract/fixtures/cases/ 全部案例，
 * Kotlin 掃描器輸出必須與 Python 參考實作的 expected.json byte-identical。
 */
class FixtureTest {

    @Test
    fun `all fixture cases match expected json byte for byte`() {
        val casesDir = findCasesDir()
        val names = casesDir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted()
            ?: fail("cases dir not found")
        assertTrue(names.size >= 20, "expected >=20 cases, got ${names.size}")

        val failures = ArrayList<String>()
        for (name in names) {
            val expected = File(casesDir, "$name/expected.json").readBytes()
            val result = Scanner.scan(File(casesDir, "$name/lib"))
            val actual = render(result.toCanonical()).toByteArray(Charsets.UTF_8)
            if (!expected.contentEquals(actual)) {
                failures.add(
                    "case [$name]\n--- expected ---\n${expected.decodeToString()}\n" +
                        "--- actual ---\n${actual.decodeToString()}"
                )
            }
        }
        if (failures.isNotEmpty()) fail("${failures.size}/${names.size} cases drifted:\n\n" +
            failures.joinToString("\n\n========\n\n"))
    }

    @Test
    fun `extinf ms conversion is float-free deterministic`() {
        assertEquals(213500, Scanner.extinfToMs("213.5"))
        assertEquals(5000, Scanner.extinfToMs("5"))
        assertEquals(500, Scanner.extinfToMs(".5"))
        assertEquals(5400, Scanner.extinfToMs("5.4005"))
        assertEquals(-1500, Scanner.extinfToMs("-1.5"))
        assertEquals(null, Scanner.extinfToMs(""))
        assertEquals(null, Scanner.extinfToMs("abc"))
        assertEquals(null, Scanner.extinfToMs("1.2.3"))
    }

    @Test
    fun `canonical json escaping matches spec`() {
        val m = linkedMapOf("b" to "引", "a" to listOf<String>())
        assertEquals("{\n  \"a\": [],\n  \"b\": \"引\"\n}\n", render(m))
        assertEquals("\"\\u0001 \\n \\\" \\\\\"\n", render("\u0001 \n \" \\"))
    }

    private fun findCasesDir(): File {
        var dir = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val c = File(dir, "contract/fixtures/cases")
            if (c.isDirectory) return c
            dir = dir.parentFile
        }
        fail("contract/fixtures/cases not found from ${System.getProperty("user.dir")}")
    }
}
