package mu.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/** 現正播放快照契約測試：跑 contract/fixtures/nowplaying_cases/（model.md §1.11）。 */
class NowPlayingFixtureTest {

    @Test
    fun `all nowplaying fixture cases match expected json byte for byte`() {
        val casesDir = findDir("contract/fixtures/nowplaying_cases") ?: fail("nowplaying_cases not found")
        val names = casesDir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted()
            ?: fail("cannot list $casesDir")
        assertTrue(names.size >= 2, "expected >=2 nowplaying cases, got ${names.size}")

        val failures = ArrayList<String>()
        for (name in names) {
            val caseDir = File(casesDir, name)
            val expected = File(caseDir, "expected.json").readBytes()
            val script = Json.parseToJsonElement(File(caseDir, "script.json").readText()).jsonObject
            val out = ArrayList<Map<String, Any?>>()
            for (el in script["entries"]!!.jsonArray) {
                val e = el.jsonObject
                val snap = NowPlayingSnapshot.parse(e["text"]?.jsonPrimitive?.contentOrNull)
                val row = LinkedHashMap<String, Any?>()
                val now = e["nowMs"]?.jsonPrimitive?.longOrNull
                if (now != null) {
                    row["displayState"] = snap.displayState(now).name.lowercase()
                    row["effectivePositionMs"] = snap.effectivePositionMs(now)
                }
                row["name"] = e["name"]!!.jsonPrimitive.content
                row["serialized"] = snap.serialize()
                row["snapshot"] = linkedMapOf<String, Any?>(
                    "albumId" to snap.albumId,
                    "artist" to snap.artist,
                    "durationMs" to snap.durationMs,
                    "isPlaying" to snap.isPlaying,
                    "positionMs" to snap.positionMs,
                    "title" to snap.title,
                    "trackId" to snap.trackId,
                    "updatedAtMs" to snap.updatedAtMs,
                )
                out.add(row)
            }
            val actual = CanonicalJson.render(out).toByteArray(Charsets.UTF_8)
            if (!expected.contentEquals(actual)) {
                failures.add("case [$name]\n--- expected ---\n${expected.decodeToString()}\n" +
                    "--- actual ---\n${actual.decodeToString()}")
            }
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size}/${names.size} nowplaying cases drifted:\n\n" +
                failures.joinToString("\n\n========\n\n"))
        }
    }

    @Test
    fun `serialize round trip with escaping`() {
        val snap = NowPlayingSnapshot.create(
            trackId = "A/\"quoted\"/01.flac", title = "Ri\\se", artist = "Aurora\n2",
            albumId = "alb|A|B", isPlaying = true, positionMs = 1000,
            durationMs = 2000, updatedAtMs = 1700000000000,
        )
        assertEquals(snap, NowPlayingSnapshot.parse(snap.serialize()))
        assertEquals(NowPlayingSnapshot.IDLE, NowPlayingSnapshot.parse(null))
    }

    private fun findDir(rel: String): File? {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val c = File(dir, rel)
            if (c.isDirectory) return c
            dir = dir.parentFile
        }
        return null
    }
}
