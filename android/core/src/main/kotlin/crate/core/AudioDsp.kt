package crate.core

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 單一 biquad（RBJ cookbook peaking EQ），a0 已正規化。浮點——不入三方 byte 契約，
 * 由各平台單元測試驗頻率響應（model.md §1.10）。
 */
data class Biquad(
    val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double,
) {
    companion object {
        val IDENTITY = Biquad(1.0, 0.0, 0.0, 0.0, 0.0)

        /** f0 ≥ Nyquist 或增益 0 → identity。 */
        fun peaking(
            sampleRate: Double,
            f0: Double,
            gainDb: Double,
            q: Double = EqSettings.BAND_Q,
        ): Biquad {
            if (sampleRate <= 0 || f0 <= 0 || f0 >= sampleRate / 2 || gainDb == 0.0 || q <= 0) {
                return IDENTITY
            }
            val a = 10.0.pow(gainDb / 40.0)
            val w0 = 2.0 * PI * f0 / sampleRate
            val alpha = sin(w0) / (2.0 * q)
            val cosW0 = cos(w0)
            val a0 = 1 + alpha / a
            return Biquad(
                (1 + alpha * a) / a0,
                (-2 * cosW0) / a0,
                (1 - alpha * a) / a0,
                (-2 * cosW0) / a0,
                (1 - alpha / a) / a0,
            )
        }
    }

    /** |H(e^jw)|（測試用）。 */
    fun magnitude(atHz: Double, sampleRate: Double): Double {
        val w = 2.0 * PI * atHz / sampleRate
        val cw = cos(w); val sw = sin(w)
        val c2w = cos(2 * w); val s2w = sin(2 * w)
        val numRe = b0 + b1 * cw + b2 * c2w
        val numIm = -(b1 * sw + b2 * s2w)
        val denRe = 1 + a1 * cw + a2 * c2w
        val denIm = -(a1 * sw + a2 * s2w)
        return sqrt(numRe * numRe + numIm * numIm) / sqrt(denRe * denRe + denIm * denIm)
    }
}

/**
 * 播放期 DSP：EQ 串接 + 總增益（model.md §1.10）。
 * 直通時零成本；輸出硬性 clamp 到 ±1.0（正增益過大 → 削峰，屬使用者選擇）。
 * `configure` 由控制端呼叫、`process` 由音訊執行緒呼叫，兩者以 lock 序列化（configure 頻率極低）。
 */
class AudioDsp {

    private val lock = Any()
    private var filters: List<Biquad> = emptyList()
    private var state: Array<DoubleArray> = arrayOf()
    private var gain: Float = 1f
    @Volatile private var identityFlag = true
    private var channels = 0
    private var sampleRate = 0.0
    private var settings: EqSettings = EqSettings.DEFAULT
    private var gainMb = 0

    /** 目前是否直通（呼叫端可據此略過整個處理）。 */
    val isIdentity: Boolean get() = identityFlag

    /** 控制端：更新設定與總增益；格式沿用最後一次 [prepare]。 */
    fun setSettings(settings: EqSettings, gainMb: Int) {
        synchronized(lock) {
            this.settings = settings
            this.gainMb = gainMb
            rebuildLocked()
        }
    }

    /** 音訊端：串流格式就緒/改變。 */
    fun prepare(sampleRate: Double, channels: Int) {
        synchronized(lock) {
            this.sampleRate = sampleRate
            this.channels = channels
            rebuildLocked()
        }
    }

    /** 一次設定（測試/單純情境）。 */
    fun configure(settings: EqSettings, gainMb: Int, sampleRate: Double, channels: Int) {
        synchronized(lock) {
            this.settings = settings
            this.gainMb = gainMb
            this.sampleRate = sampleRate
            this.channels = channels
            rebuildLocked()
        }
    }

    private fun rebuildLocked() {
        val newFilters = if (sampleRate > 0) {
            settings.activeBands()
                .map { Biquad.peaking(sampleRate, it.first.toDouble(), it.second / 100.0) }
                .filter { it != Biquad.IDENTITY }
        } else {
            emptyList()
        }
        val changedShape = newFilters.size != filters.size || state.size != maxOf(channels, 1)
        filters = newFilters
        gain = EqSettings.linear(gainMb)
        identityFlag = newFilters.isEmpty() && gainMb == 0
        if (changedShape) {
            state = Array(maxOf(channels, 1)) { DoubleArray(maxOf(newFilters.size, 1) * 4) }
        }
    }

    fun reset() {
        synchronized(lock) { state.forEach { it.fill(0.0) } }
    }

    /** 交錯（interleaved）緩衝原地處理；[frames] = 每聲道樣本數。 */
    fun process(buf: FloatArray, offset: Int, frames: Int, ch: Int) {
        synchronized(lock) {
            if (identityFlag || frames <= 0 || ch <= 0) return
            if (state.size < ch) {
                state = Array(ch) { DoubleArray(maxOf(filters.size, 1) * 4) }
            }
            val fs = filters
            for (c in 0 until ch) {
                val st = state[c]
                for (f in 0 until frames) {
                    val i = offset + f * ch + c
                    var x = buf[i].toDouble()
                    for (k in fs.indices) x = step(fs[k], x, st, k * 4)
                    buf[i] = clip((x * gain).toFloat())
                }
            }
        }
    }

    /** 測試用：回傳處理後的新陣列。 */
    fun processed(samples: FloatArray, ch: Int): FloatArray {
        val out = samples.copyOf()
        process(out, 0, out.size / ch, ch)
        return out
    }

    /** Direct Form I 單步；st[base..base+3] = x1,x2,y1,y2。 */
    private fun step(bq: Biquad, x: Double, st: DoubleArray, base: Int): Double {
        val y = bq.b0 * x + bq.b1 * st[base] + bq.b2 * st[base + 1] -
            bq.a1 * st[base + 2] - bq.a2 * st[base + 3]
        st[base + 1] = st[base]; st[base] = x
        st[base + 3] = st[base + 2]; st[base + 2] = y
        return y
    }

    private fun clip(v: Float): Float = if (v > 1f) 1f else if (v < -1f) -1f else v
}
