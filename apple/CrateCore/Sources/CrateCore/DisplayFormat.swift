import Foundation

/// UI 顯示用純格式化（不含任何平台 UI 依賴）：時長、EQ/ReplayGain 中文標籤。
/// 這裡的字串不是契約內容（不做三方 byte-identical 比對），只是避免同一份文案在
/// iOS/macOS/Android 各自的畫面檔裡重複手key、進而各自漂移。
public enum DisplayFormat {

    /// 「3:07」。負值/nil 回空字串。
    public static func duration(ms: Int?) -> String {
        guard let ms, ms >= 0 else { return "" }
        return String(format: "%d:%02d", ms / 60000, ms / 1000 % 60)
    }

    /// 「3:07」或「1:03:07」（滿一小時才帶時）。
    public static func clock(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 「48 分鐘」或「1 小時 12 分鐘」。
    public static func totalDuration(msValues: [Int?]) -> String {
        let secs = msValues.compactMap { $0 }.reduce(0, +) / 1000
        if secs >= 3600 { return "\(secs / 3600) 小時 \(secs / 60 % 60) 分鐘" }
        return "\(max(1, secs / 60)) 分鐘"
    }

    /// EQ preset 內部名稱 → 中文標籤（未知名稱原樣回傳）。
    public static func eqPresetLabel(_ name: String) -> String {
        eqPresetLabels[name] ?? name
    }

    /// 前置增益選項（millibel）：兩平台的選單共用同一組刻度。
    public static let eqPreampChoicesMb = [-600, -300, 0, 300, 600]

    /// 「+3 dB」/「0 dB」。
    public static func gainLabel(mb: Int) -> String {
        mb == 0 ? "0 dB" : String(format: "%+.0f dB", Double(mb) / 100)
    }

    private static let eqPresetLabels: [String: String] = [
        "flat": "平坦", "rock": "搖滾", "pop": "流行", "jazz": "爵士",
        "classical": "古典", "bass": "重低音", "treble": "高音",
        "vocal": "人聲", "loudness": "響度",
    ]
}
