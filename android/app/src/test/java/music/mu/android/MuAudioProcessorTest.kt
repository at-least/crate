package music.mu.android

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import mu.core.EqSettings
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Media3 處理節點的 buffer 層測試（純 JVM）：直通、16-bit/float 增益、削峰。
 * DSP 本身的頻率響應由 :core 的 EqFixtureTest 驗（model.md §1.10）。
 */
class MuAudioProcessorTest {

    private fun configure(p: MuAudioProcessor, encoding: Int, ch: Int = 2, rate: Int = 48000) {
        p.configure(AudioProcessor.AudioFormat(rate, ch, encoding))
        p.flush()
    }

    private fun pcm16(values: ShortArray): ByteBuffer {
        val b = ByteBuffer.allocateDirect(values.size * 2).order(ByteOrder.nativeOrder())
        values.forEach { b.putShort(it) }
        b.flip()
        return b
    }

    private fun readShorts(b: ByteBuffer): ShortArray {
        val out = ShortArray(b.remaining() / 2)
        for (i in out.indices) out[i] = b.getShort()
        return out
    }

    @Test
    fun `passthrough when identity`() {
        val p = MuAudioProcessor()
        configure(p, C.ENCODING_PCM_16BIT)
        assertTrue(p.dsp.isIdentity)
        val input = shortArrayOf(1000, -1000, 32767, -32768)
        p.queueInput(pcm16(input))
        assertTrue("直通 = 位元不變", readShorts(p.output).contentEquals(input))
    }

    @Test
    fun `applies negative gain to pcm16`() {
        val p = MuAudioProcessor()
        configure(p, C.ENCODING_PCM_16BIT)
        p.dsp.setSettings(EqSettings.DEFAULT, -600) // ≈ ×0.5
        assertTrue(!p.dsp.isIdentity)
        p.queueInput(pcm16(shortArrayOf(10000, -10000, 0, 20000)))
        val out = readShorts(p.output)
        val g = EqSettings.linear(-600)
        assertNear((10000 * g).toInt(), out[0].toInt(), 2)
        assertNear((-10000 * g).toInt(), out[1].toInt(), 2)
        assertEquals(0, out[2].toInt().toLong().toInt())
        assertNear((20000 * g).toInt(), out[3].toInt(), 2)
    }

    @Test
    fun `positive gain clips instead of wrapping`() {
        val p = MuAudioProcessor()
        configure(p, C.ENCODING_PCM_16BIT)
        p.dsp.setSettings(EqSettings.DEFAULT, 1200) // ≈ ×4
        p.queueInput(pcm16(shortArrayOf(30000, -30000)))
        val out = readShorts(p.output)
        assertEquals("削峰到滿刻度，不 wrap", 32767, out[0].toInt())
        assertTrue("負向同理，實得 ${out[1]}", out[1] <= -32760)
    }

    @Test
    fun `float encoding path`() {
        val p = MuAudioProcessor()
        configure(p, C.ENCODING_PCM_FLOAT)
        p.dsp.setSettings(EqSettings.DEFAULT, -600)
        val b = ByteBuffer.allocateDirect(4 * 4).order(ByteOrder.nativeOrder())
        floatArrayOf(0.5f, -0.5f, 0f, 0.25f).forEach { b.putFloat(it) }
        b.flip()
        p.queueInput(b)
        val out = p.output
        val g = EqSettings.linear(-600)
        assertTrue(abs(out.getFloat() - 0.5f * g) < 1e-5f)
        assertTrue(abs(out.getFloat() + 0.5f * g) < 1e-5f)
        assertEquals(0f, out.getFloat(), 1e-9f)
        assertTrue(abs(out.getFloat() - 0.25f * g) < 1e-5f)
    }

    @Test
    fun `unsupported encoding is rejected`() {
        val p = MuAudioProcessor()
        var threw = false
        try {
            p.configure(AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_24BIT))
        } catch (e: AudioProcessor.UnhandledAudioFormatException) {
            threw = true
        }
        assertTrue("非 PCM16/float → 交還 Media3", threw)
    }

    private fun assertNear(expected: Int, actual: Int, tolerance: Int) {
        assertTrue("expected ≈ $expected, got $actual", abs(expected - actual) <= tolerance)
    }
}
