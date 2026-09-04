import Foundation

/// 等化器設定（model.md §1.10）。純整數（millibel）；序列化與 Python/Kotlin byte-identical。
public struct EqSettings: Equatable {

    /// 中心頻率（Hz）；每段 Q 固定。
    public static let bandHz = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let bandQ = 1.41
    public static let gainLimitMb = 1200
    public static let rgLimitMb = 6000
    public static let totalMinMb = -6000
    public static let totalMaxMb = 1200

    public static let presets: [(name: String, bands: [Int])] = [
        ("flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("rock", [500, 400, 200, 0, -100, -100, 200, 400, 500, 500]),
        ("pop", [-100, 100, 300, 400, 300, 100, 0, -100, -100, -100]),
        ("jazz", [300, 200, 100, 200, -100, -100, 0, 100, 200, 300]),
        ("classical", [400, 300, 200, 100, -100, -100, 0, 200, 300, 400]),
        ("bass", [700, 600, 400, 200, 0, 0, 0, 0, 0, 0]),
        ("treble", [0, 0, 0, 0, 0, 100, 300, 500, 600, 700]),
        ("vocal", [-200, -100, 0, 200, 400, 400, 300, 100, 0, -100]),
        ("loudness", [600, 500, 200, 0, -200, -200, 0, 200, 500, 600]),
    ]

    public static func presetBands(_ name: String) -> [Int]? {
        presets.first { $0.name == name }?.bands
    }

    public let bands: [Int]
    public let enabled: Bool
    public let preamp: Int
    public let preset: String

    public init(bands: [Int] = [], enabled: Bool = false, preamp: Int = 0, preset: String = "flat") {
        var b = Array(bands.prefix(Self.bandHz.count))
        while b.count < Self.bandHz.count { b.append(0) }
        self.bands = b.map { Self.clamp($0, -Self.gainLimitMb, Self.gainLimitMb) }
        self.enabled = enabled
        self.preamp = Self.clamp(preamp, -Self.gainLimitMb, Self.gainLimitMb)
        self.preset = preset
    }

    public static let `default` = EqSettings()

    /// 未知名稱 → flat。
    public static func preset(_ name: String, enabled: Bool = true, preamp: Int = 0) -> EqSettings {
        let known = presetBands(name)
        return EqSettings(bands: known ?? presetBands("flat")!, enabled: enabled,
                          preamp: preamp, preset: known == nil ? "flat" : name)
    }

    /// 壞 JSON / 缺鍵 → 預設；非整數 band → 0。
    public static func parse(_ text: String?) -> EqSettings {
        guard let text, !text.isEmpty, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .default
        }
        var bands: [Int] = []
        if let raw = obj["bands"] as? [Any] {
            bands = raw.map { asInt($0) ?? 0 }
        }
        let presetName = obj["preset"] as? String
        return EqSettings(
            bands: bands,
            enabled: (obj["enabled"] as? NSNumber).map { isBool($0) && $0.boolValue } ?? false,
            preamp: asInt(obj["preamp"]) ?? 0,
            preset: presetName.flatMap { presetBands($0) != nil ? $0 : nil } ?? "flat")
    }

    /// canonical（鍵序固定、無空白）——三方 byte-identical。
    public func serialize() -> String {
        let b = bands.map(String.init).joined(separator: ",")
        return "{\"bands\":[\(b)],\"enabled\":\(enabled),\"preamp\":\(preamp),\"preset\":\"\(preset)\"}"
    }

    /// (頻率, mb)；停用或增益 0 的段不進 DSP。
    public func activeBands() -> [(hz: Int, mb: Int)] {
        guard enabled else { return [] }
        return zip(Self.bandHz, bands).filter { $0.1 != 0 }.map { (hz: $0.0, mb: $0.1) }
    }

    /// DSP 直通判定（§1.10 末段）。
    public func isIdentity(gainMb: Int) -> Bool {
        gainMb == 0 && activeBands().isEmpty
    }

    /// 播放總增益（§1.9 ReplayGain + preamp，整數 mb）。
    public func playbackGainMb(mode: ReplayGain.Mode, trackMb: Int?, albumMb: Int?) -> Int {
        let rg = ReplayGain.gainMb(mode: mode, trackMb: trackMb, albumMb: albumMb)
        var total = Self.clamp(rg ?? 0, -Self.rgLimitMb, Self.rgLimitMb)
        if enabled { total += preamp }
        return Self.clamp(total, Self.totalMinMb, Self.totalMaxMb)
    }

    public func playbackGainMb(mode: ReplayGain.Mode, track: Scanner.Track?) -> Int {
        playbackGainMb(mode: mode, trackMb: track?.replayGainTrackMb,
                       albumMb: track?.replayGainAlbumMb)
    }

    /// 線性增益（v1.3 起可 > 1——DSP 層套用）。
    public static func linear(mb: Int) -> Float {
        Float(pow(10.0, Double(mb) / 2000.0))
    }

    public static let defaultsKey = "eq"

    public static func load(from defaults: UserDefaults = .standard) -> EqSettings {
        parse(defaults.string(forKey: defaultsKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(serialize(), forKey: Self.defaultsKey)
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { v < lo ? lo : (v > hi ? hi : v) }

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// JSON 值 → Int；Bool、浮點、字串一律 nil（契約：非整數視為 0）。
    private static func asInt(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, !isBool(n) else { return nil }
        return CFNumberIsFloatType(n) ? nil : n.intValue
    }
}
