import Foundation

/// 單一 biquad（RBJ cookbook peaking EQ），a0 已正規化。浮點——不入三方 byte 契約，
/// 由各平台單元測試驗頻率響應（model.md §1.10）。
public struct Biquad: Equatable {
    public let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// f0 ≥ Nyquist 或增益 0 → identity。
    public static func peaking(sampleRate: Double, f0: Double, gainDb: Double,
                               q: Double = EqSettings.bandQ) -> Biquad {
        guard sampleRate > 0, f0 > 0, f0 < sampleRate / 2, gainDb != 0, q > 0 else { return identity }
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * Double.pi * f0 / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0,
                      b1: (-2 * cosW0) / a0,
                      b2: (1 - alpha * a) / a0,
                      a1: (-2 * cosW0) / a0,
                      a2: (1 - alpha / a) / a0)
    }

    /// |H(e^jw)|（測試用）。
    public func magnitude(atHz f: Double, sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * f / sampleRate
        let cw = cos(w), sw = sin(w)
        let c2w = cos(2 * w), s2w = sin(2 * w)
        let numRe = b0 + b1 * cw + b2 * c2w
        let numIm = -(b1 * sw + b2 * s2w)
        let denRe = 1 + a1 * cw + a2 * c2w
        let denIm = -(a1 * sw + a2 * s2w)
        return (numRe * numRe + numIm * numIm).squareRoot()
            / (denRe * denRe + denIm * denIm).squareRoot()
    }
}

/// 播放期 DSP：EQ 串接 + 總增益（model.md §1.10）。
/// 直通時零成本；輸出硬性 clamp 到 ±1.0（正增益過大 → 削峰，屬使用者選擇）。
/// 非 thread-safe 的處理迴圈：`configure` 由控制端呼叫、`process` 由音訊執行緒呼叫，
/// 兩者以 `lock` 序列化（configure 頻率極低）。
public final class AudioDsp {

    private let lock = NSLock()
    private var filters: [Biquad] = []
    private var state: [[Double]] = []       // [channel][filter*4]：x1,x2,y1,y2
    private var gain: Float = 1
    private var identity = true
    private var channels = 0
    private var sampleRate: Double = 0
    private var settings: EqSettings = .default
    private var gainMb = 0

    public init() {}

    /// 目前是否直通（呼叫端可據此略過整個處理）。
    public var isIdentity: Bool {
        lock.lock(); defer { lock.unlock() }
        return identity
    }

    /// 控制端（主執行緒）：更新設定與總增益；格式沿用最後一次 `prepare`。
    public func setSettings(_ settings: EqSettings, gainMb: Int) {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
        self.gainMb = gainMb
        rebuildLocked()
    }

    /// 音訊端：串流格式就緒/改變（tap prepare）。
    public func prepare(sampleRate: Double, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        self.sampleRate = sampleRate
        self.channels = channels
        rebuildLocked()
    }

    /// 一次設定（測試/單純情境）。
    public func configure(settings: EqSettings, gainMb: Int, sampleRate: Double, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
        self.gainMb = gainMb
        self.sampleRate = sampleRate
        self.channels = channels
        rebuildLocked()
    }

    private func rebuildLocked() {
        let newFilters = sampleRate > 0
            ? settings.activeBands().map {
                Biquad.peaking(sampleRate: sampleRate, f0: Double($0.hz),
                               gainDb: Double($0.mb) / 100.0)
              }.filter { $0 != .identity }
            : []
        let changedShape = newFilters.count != filters.count || state.count != max(channels, 1)
        filters = newFilters
        gain = EqSettings.linear(mb: gainMb)
        identity = newFilters.isEmpty && gainMb == 0
        if changedShape {
            state = Array(repeating: Array(repeating: 0, count: max(newFilters.count, 1) * 4),
                          count: max(channels, 1))
        }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for c in state.indices { for i in state[c].indices { state[c][i] = 0 } }
    }

    /// 交錯（interleaved）緩衝原地處理。
    public func process(_ buf: UnsafeMutablePointer<Float>, frames: Int, channels ch: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !identity, frames > 0, ch > 0 else { return }
        if state.count < ch {
            state = Array(repeating: Array(repeating: 0, count: max(filters.count, 1) * 4),
                          count: ch)
        }
        for c in 0..<ch {
            state[c].withUnsafeMutableBufferPointer { st in
                for f in 0..<frames {
                    var x = Double(buf[f * ch + c])
                    for (k, bq) in filters.enumerated() {
                        x = Self.step(bq, x, st.baseAddress! + k * 4)
                    }
                    buf[f * ch + c] = Self.clip(Float(x) * gain)
                }
            }
        }
    }

    /// 非交錯（每聲道獨立緩衝）原地處理。
    public func process(planar bufs: [UnsafeMutablePointer<Float>], frames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !identity, frames > 0, !bufs.isEmpty else { return }
        if state.count < bufs.count {
            state = Array(repeating: Array(repeating: 0, count: max(filters.count, 1) * 4),
                          count: bufs.count)
        }
        for (c, buf) in bufs.enumerated() {
            state[c].withUnsafeMutableBufferPointer { st in
                for f in 0..<frames {
                    var x = Double(buf[f])
                    for (k, bq) in filters.enumerated() {
                        x = Self.step(bq, x, st.baseAddress! + k * 4)
                    }
                    buf[f] = Self.clip(Float(x) * gain)
                }
            }
        }
    }

    /// 測試用：交錯陣列處理。
    public func processed(_ samples: [Float], channels ch: Int) -> [Float] {
        var out = samples
        out.withUnsafeMutableBufferPointer { p in
            process(p.baseAddress!, frames: p.count / ch, channels: ch)
        }
        return out
    }

    /// Direct Form I 單步；st = [x1,x2,y1,y2]。
    private static func step(_ bq: Biquad, _ x: Double, _ st: UnsafeMutablePointer<Double>) -> Double {
        let y = bq.b0 * x + bq.b1 * st[0] + bq.b2 * st[1] - bq.a1 * st[2] - bq.a2 * st[3]
        st[1] = st[0]; st[0] = x
        st[3] = st[2]; st[2] = y
        return y
    }

    private static func clip(_ v: Float) -> Float {
        v > 1 ? 1 : (v < -1 ? -1 : v)
    }
}
