import CrateCore

/// 一組音軌的釘選狀態彙總（專輯/清單頭部的釘選按鈕共用；iOS/macOS 文案必須一致，
/// 因為 UI 測試斷言 `fullLabel` 的確切文字）。
public struct PinSummary {
    public let total: Int
    public let done: Int
    public let pending: Int
    public let failed: Int

    public init(tracks: [CrateCore.Scanner.Track], states: [String: PinManager.PinState]) {
        total = tracks.count
        done = tracks.filter { states[$0.id] == .done }.count
        pending = tracks.filter { states[$0.id]?.isPending == true }.count
        failed = tracks.filter { states[$0.id] == .failed }.count
    }

    public var allDone: Bool { total > 0 && done == total }

    /// 按鈕上的圖示名稱（SF Symbol）。
    public var symbolName: String {
        if allDone { return "checkmark.circle.fill" }
        if failed > 0 { return "exclamationmark.arrow.circlepath" }
        return "arrow.down.circle"
    }

    /// 按鈕短標籤。
    public var shortLabel: String {
        if total == 0 { return "無軌" }
        if allDone { return "已釘選" }
        if pending > 0 { return "釘選中 \(done)/\(total)" }
        if failed > 0 { return "重試釘選" }
        return "釘選離線"
    }

    /// accessibility / help 用完整狀態句。
    public var fullLabel: String {
        switch true {
        case total == 0:
            return "無軌"
        case allDone:
            return "已釘選（\(total) 軌，點擊取消）"
        case done + pending > 0:
            return "釘選中 \(done)/\(total)" + (failed > 0 ? " · \(failed) 失敗" : "")
        case failed > 0:
            return "釘選失敗 \(failed)/\(total)（點擊重試）"
        default:
            return "釘選離線（\(total) 軌）"
        }
    }
}
