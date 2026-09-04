import Foundation

/// 本地資料夾 provider（provider.md §6）。
/// sync 契約（sync-rules.md §3）用到的面：snapshot 快照 + 檔案讀取；
/// listDir 等其餘介面隨 FakeProvider 子步驟的錯誤語意契約一併補上（putText 已於 D12 移除）。
public struct LocalFolderProvider: SyncProvider {

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// path -> rev（"{size}:{mtimeMs}"）。全部檔案（含非音訊；過濾是引擎的事）。
    public func snapshot() -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            return out
        }
        // /var → /private/var 等 symlink 兩邊都展開，rel 切除才會對齊
        let rootPath = root.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            guard let rel = relPath(of: url, rootPath: rootPath) else { continue }
            let date = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let ms = Int((date.timeIntervalSince1970 * 1000).rounded())
            out[rel] = "\(values.fileSize ?? 0):\(ms)"
        }
        return out
    }

    /// 掃描用開檔；不存在 → nil（引擎靜默丟棄，sync-rules §3.2-4）。
    public func open(_ path: String) throws -> (any ByteSource)? {
        FileSource(url: root.appendingPathComponent(path))
    }

    /// 便利：整檔讀取（App 層小檔用）；不存在 → nil。
    public func readBytes(_ path: String) -> [UInt8]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { return nil }
        return [UInt8](data)
    }

    /// 相對路徑（root 外或對不上 → nil）。
    private func relPath(of url: URL, rootPath: String) -> String? {
        let p = url.resolvingSymlinksInPath().path
        guard p.hasPrefix(rootPath + "/") else { return nil }
        return String(p.dropFirst(rootPath.count + 1))
    }
}
