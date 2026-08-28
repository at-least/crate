import Foundation

/// 引擎面向的 provider 兩面（sync-rules §3）：快照 + 讀檔。
/// 本地（provider.md §6）永不拋錯；雲端（§8）在重試耗盡/重授權失敗時拋 `ProviderError`。
public protocol SyncProvider {
    /// path -> rev；全部檔案（含非音訊；過濾是引擎的事）。失敗 → 整輪 sync 拋錯、狀態不動。
    func snapshot() throws -> [String: String]
    /// 掃描用讀檔；nil = NotFound（引擎靜默丟棄）；其他失敗拋錯 → §3.2-8 續掃。
    func readBytes(_ path: String) throws -> [UInt8]?
}

/// provider.md §2 錯誤語意（重試耗盡後由 provider 拋出）。
public enum ProviderError: Error, Equatable {
    case auth                 // 重授權後仍 401
    case transient            // 退避 5 次仍失敗
    case notFound             // 404（引擎面：readBytes 回 nil，不以此拋出）
    case http(Int)            // 其他 4xx（不重試）
}
