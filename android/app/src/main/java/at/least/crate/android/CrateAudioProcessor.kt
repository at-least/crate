package at.least.crate.android

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import crate.core.AudioDsp
import java.nio.ByteBuffer

/**
 * Media3 音訊處理節點：把 crate.core.AudioDsp（EQ + 總增益，model.md §1.10）掛進 ExoPlayer 的
 * DefaultAudioSink 處理鏈。直通時只做 buffer 複製（DSP 判定 identity）。
 *
 * 支援 16-bit PCM 與 float PCM（sink 依裝置決定）；其餘編碼交還給 Media3 處理。
 */
class CrateAudioProcessor : BaseAudioProcessor() {

    val dsp = AudioDsp()

    private var encoding = C.ENCODING_INVALID
    private var channels = 0
    private var scratch = FloatArray(0)

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT &&
            inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT
        ) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        encoding = inputAudioFormat.encoding
        channels = inputAudioFormat.channelCount
        dsp.prepare(inputAudioFormat.sampleRate.toDouble(), channels)
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val pos = inputBuffer.position()
        val limit = inputBuffer.limit()
        val size = limit - pos
        if (size <= 0) return
        val out = replaceOutputBuffer(size)
        if (dsp.isIdentity || channels <= 0) {
            out.put(inputBuffer) // 直通（position 由 put 推進到 limit）
            out.flip()
            return
        }
        if (encoding == C.ENCODING_PCM_16BIT) {
            val samples = size / 2
            val frames = samples / channels
            ensureScratch(samples)
            for (i in 0 until samples) scratch[i] = inputBuffer.getShort(pos + i * 2) / 32768f
            dsp.process(scratch, 0, frames, channels)
            for (i in 0 until samples) {
                val v = (scratch[i] * 32767f).toInt().coerceIn(-32768, 32767)
                out.putShort(v.toShort())
            }
        } else {
            val samples = size / 4
            val frames = samples / channels
            ensureScratch(samples)
            for (i in 0 until samples) scratch[i] = inputBuffer.getFloat(pos + i * 4)
            dsp.process(scratch, 0, frames, channels)
            for (i in 0 until samples) out.putFloat(scratch[i])
        }
        inputBuffer.position(limit)
        out.flip()
    }

    override fun onFlush() {
        dsp.reset()
    }

    override fun onReset() {
        scratch = FloatArray(0)
        dsp.reset()
    }

    private fun ensureScratch(n: Int) {
        if (scratch.size < n) scratch = FloatArray(n)
    }
}
