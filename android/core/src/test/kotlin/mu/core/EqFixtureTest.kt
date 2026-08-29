package mu.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * EQ 契約測試：跑 contract/fixtures/eq_cases/（model.md §1.10；純整數三方 byte-identical）。
 * 另含 Biquad/AudioDsp 的性質測試（浮點，不入 byte 契約）。
 */
class EqFixtureTest {

    @Test
    fun `all eq fixture cases match expected json byte for byte`() {
        val casesDir = findDir("contract/fixtures/eq_cases") ?: fail("eq_cases not found")
        val names = casesDir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted()
            ?: fail("cannot list $casesDir")
        assertTrue(names.size >= 3, "expected >=3 eq cases, got ${names.size}")

        val failures = ArrayList<String>()
        for (name in names) {
            val caseDir = File(casesDir, name)
            val expected = File(caseDir, "expected.json").readBytes()
            val script = Json.parseToJsonElement(File(caseDir, "script.json").readText()).jsonObject
            val out = ArrayList<Map<String, Any?>>()
            for (el in script["entries"]!!.jsonArray) {
                val e = el.jsonObject
                val kind = e["type"]!!.jsonPrimitive.content
                val entryName = e["name"]!!.jsonPrimitive.content
                when (kind) {
                    "parse", "preset" -> {
                        val eq = if (kind == "parse") {
                            EqSettings.parse((e["text"] as? JsonPrimitive)?.takeIf { !it.isString || true }
                                ?.contentOrNull)
                        } else {
                            EqSettings.preset(
                                entryName,
                                e["enabled"]?.jsonPrimitive?.booleanOrNull ?: true,
                                e["preamp"]?.jsonPrimitive?.intOrNull ?: 0,
                            )
                        }
                        out.add(linkedMapOf(
                            "activeBands" to eq.activeBands().map { listOf(it.first, it.second) },
                            "kind" to kind,
                            "name" to entryName,
                            "serialized" to eq.serialize(),
                            "settings" to settingsMap(eq),
                        ))
                    }
                    "gain" -> {
                        val eq = EqSettings.parse((e["eq"] as? JsonPrimitive)?.contentOrNull)
                        val mode = ReplayGain.Mode.from(e["mode"]!!.jsonPrimitive.content)
                        val gain = eq.playbackGainMb(
                            mode,
                            e["trackMb"]?.jsonPrimitive?.intOrNull,
                            e["albumMb"]?.jsonPrimitive?.intOrNull,
                        )
                        out.add(linkedMapOf(
                            "gainMb" to gain,
                            "identity" to eq.isIdentity(gain),
                            "kind" to kind,
                            "name" to entryName,
                        ))
                    }
                    else -> fail("unknown entry type [$kind] in case [$name]")
                }
            }
            val actual = CanonicalJson.render(out).toByteArray(Charsets.UTF_8)
            if (!expected.contentEquals(actual)) {
                failures.add("case [$name]\n--- expected ---\n${expected.decodeToString()}\n" +
                    "--- actual ---\n${actual.decodeToString()}")
            }
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size}/${names.size} eq cases drifted:\n\n" +
                failures.joinToString("\n\n========\n\n"))
        }
    }

    private fun settingsMap(eq: EqSettings): Map<String, Any?> = linkedMapOf(
        "bands" to eq.bands,
        "enabled" to eq.enabled,
        "preamp" to eq.preamp,
        "preset" to eq.preset,
    )

    // ---- DSP 性質（浮點；不入 byte 契約）

    @Test
    fun `peaking filter magnitude response`() {
        val fs = 48000.0
        for (db in listOf(-12.0, -6.0, 3.0, 12.0)) {
            val bq = Biquad.peaking(fs, 1000.0, db)
            assertEquals(db, 20 * log10(bq.magnitude(1000.0, fs)), 0.01)
            assertEquals(0.0, 20 * log10(bq.magnitude(20.0, fs)), 0.6)
            assertEquals(0.0, 20 * log10(bq.magnitude(20000.0, fs)), 0.6)
        }
        assertEquals(Biquad.IDENTITY, Biquad.peaking(fs, 1000.0, 0.0))
        assertEquals(Biquad.IDENTITY, Biquad.peaking(8000.0, 16000.0, 6.0))
        assertEquals(1.0, Biquad.IDENTITY.magnitude(1000.0, fs), 1e-12)
    }

    @Test
    fun `dsp identity gain and clipping`() {
        val dsp = AudioDsp()
        val input = FloatArray(64) { sin(it * 0.1).toFloat() }

        dsp.configure(EqSettings.DEFAULT, 0, 48000.0, 2)
        assertTrue(dsp.isIdentity)
        assertTrue(dsp.processed(input, 2).contentEquals(input), "直通不動樣本")

        dsp.configure(EqSettings.DEFAULT, -600, 48000.0, 2)
        assertFalse(dsp.isIdentity)
        val expected = EqSettings.linear(-600)
        dsp.processed(input, 2).forEachIndexed { i, v ->
            assertEquals(input[i] * expected, v, 1e-5f)
        }

        dsp.configure(EqSettings.DEFAULT, 1200, 48000.0, 1)
        assertTrue(EqSettings.linear(1200) > 1f)
        val loud = dsp.processed(floatArrayOf(0.9f, -0.9f, 0.1f), 1)
        assertEquals(1f, loud[0], 1e-6f)
        assertEquals(-1f, loud[1], 1e-6f)
        assertEquals(0.1f * EqSettings.linear(1200), loud[2], 1e-5f)
    }

    @Test
    fun `dsp band boost raises energy and stays stable`() {
        val fs = 48000.0
        val dsp = AudioDsp()
        val eq = EqSettings.create(listOf(0, 0, 0, 0, 0, 1200, 0, 0, 0, 0), enabled = true)
        dsp.configure(eq, 0, fs, 1)
        assertFalse(dsp.isIdentity)
        val n = 4800
        val input = FloatArray(n) { (0.2 * sin(2 * PI * 1000 * it / fs)).toFloat() }
        val out = dsp.processed(input, 1)
        fun rms(xs: FloatArray, from: Int): Double {
            var acc = 0.0
            for (i in from until xs.size) acc += xs[i].toDouble() * xs[i]
            return sqrt(acc / (xs.size - from))
        }
        assertEquals(12.0, 20 * log10(rms(out, n / 2) / rms(input, n / 2)), 0.5)
        assertTrue(out.all { it.isFinite() && abs(it) <= 1f }, "有界且無 NaN")

        val low = FloatArray(n) { (0.2 * sin(2 * PI * 100 * it / fs)).toFloat() }
        dsp.reset()
        val lowOut = dsp.processed(low, 1)
        assertEquals(0.0, 20 * log10(rms(lowOut, n / 2) / rms(low, n / 2)), 1.0)
    }

    @Test
    fun `dsp interleaved channels independent`() {
        val dsp = AudioDsp()
        val eq = EqSettings.create(listOf(0, 0, 0, 0, 0, 1200, 0, 0, 0, 0), enabled = true)
        dsp.configure(eq, 0, 48000.0, 2)
        val buf = FloatArray(256) { if (it % 2 == 0) sin(it * 0.05).toFloat() else 0f }
        val out = dsp.processed(buf, 2)
        for (i in 1 until 256 step 2) assertEquals(0f, out[i], 1e-9f)
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
