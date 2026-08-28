import CryptoKit
import Foundation
import MuCore

/// 釘選離線（schema.sql v0.3 pins 狀態機 + 內容定址下載層，D13）：
/// - 下載層：downloads/<sha256>——bytes 相同 = 同一份副本，跨庫共用、只抓一次；
///   換庫不清（休眠），unpin 時無其他 pin 引用同 hash 才刪檔。
/// - 記錄層：pins 按 (root, trackId)——釘選意圖屬於庫；states 只載入當前 root（顯示單庫視角）。
/// - 重驗：sync 後以 rev 比對（revalidateSync），rev 變 → 重抓（內容 hash 即終極 rev）。
/// 本地 provider = 邊複製邊算 SHA-256（零額外 IO）；雲端 provider 進場時換 provider.download，
/// 語意不變（provider.md §1/§7）。
/// 狀態發布永遠在主執行緒（onStatesChanged）。
public final class PinManager {

    public enum PinState: String {
        case wanted, downloading, done, failed

        public var isPending: Bool { self == .wanted || self == .downloading }
    }

    public struct PinRequest {
        public let trackId: String
        public let rev: String

        public init(trackId: String, rev: String) {
            self.trackId = trackId; self.rev = rev
        }
    }

    /// 狀態變動時於主執行緒回呼（AppModel 重建 UI 用）。
    public var onStatesChanged: (([String: PinState]) -> Void)?

    private let db: MuDatabase
    private let downloadsDir: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mu.pins", qos: .utility)

    private var states: [String: PinState] = [:]   // 僅當前 root
    private var hashes: [String: String] = [:]     // trackId → 副本 SHA-256（done 軌才有）
    private var revs: [String: String] = [:]       // trackId → 已提交的 rev（抓成功才更新）
    /// revalidate 重抓的目標 rev——成功才提交進 revs；失敗則留下次 sync 重試（不卡死 FAILED）。
    private var pendingNewRevs: [String: String] = [:]
    private var root: URL?

    /// legacyPinsDir：v0.2 的 pins/（trackId 為檔名）——搬遷為內容定址後刪除；
    /// 舊 rows 已隨 schema 重建消失，搬來的副本成為之後重釘同內容的 dedup 命中。
    public init(db: MuDatabase, downloadsDir: URL, legacyPinsDir: URL? = nil) {
        self.db = db
        self.downloadsDir = downloadsDir
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        Self.migrateLegacyPins(legacyPinsDir, to: downloadsDir)
        lock.lock()
        if let persisted = db.root() {
            root = URL(fileURLWithPath: persisted)
            loadLocked(rootPath: persisted) // 行程中斷殘留的 DOWNLOADING 重置為 WANTED，自動續傳
        }
        lock.unlock()
        drain()
    }

    /// 換庫 = 記錄休眠（不清 rows、不刪檔案）；同庫冷啟動 = 保留。
    /// 換到的庫若有自己的 rows → 重連（切回舊庫即離線可用，不重抓）。
    /// 以 DB 持久化的 root 判斷（sync 流程在 replaceLibrary 之前呼叫，此時 DB 仍是舊 root）。
    /// 同步執行——呼叫端（sync 序列 queue）需等待語意定案後才落庫新 root。
public     func setRootSync(_ newRoot: URL) {
        queue.sync {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.root?.path != newRoot.path else { return }
            let persisted = self.db.root()
            self.root = newRoot
            if let persisted, persisted == newRoot.path {
                return // 同庫重開：init 已載入該 root 的 states
            }
            self.loadLocked(rootPath: newRoot.path) // 換庫：載入新庫 rows（他庫休眠）
            self.publishLocked()
        }
        drain()
    }

public     func pin(_ requests: [PinRequest]) {
        guard !requests.isEmpty else { return }
        queue.async {
            self.pinLocked(requests)
        }
        drain()
    }

public     func unpin(_ trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        queue.async {
            self.unpinLocked(trackIds)
        }
    }

    /// 釘選完成且副本在 → 副本 URL；否則 nil。同步呼叫（播放解析用）。
public     func pinnedFile(_ trackId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return pinnedFileLocked(trackId)
    }

    /// 目前狀態快照（任意執行緒；僅當前 root）。
public     func snapshot() -> [String: PinState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    /// sync 後重驗（SyncRunner 呼叫）：done 且來源 rev 已變 → 重抓。
    /// 不在索引的軌（來源消失／B5）不動——釘選副本存活即可播。
public     func revalidateSync(_ currentRevs: [String: String]) {
        queue.sync {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let rootPath = self.root?.path else { return }
            let doneChanged = self.states
                .filter { $0.value == .done }
                .compactMap { id, _ in currentRevs[id].flatMap { $0 != revs[id] ? id : nil } }
            // 上次 revalidate 觸發的重抓失敗 → 重試（revs 仍是舊值，同 rev 也會再進場）
            let retry = self.states.filter { $0.value == .failed && pendingNewRevs[$0.key] != nil }.map(\.key)
            let refresh = Set(doneChanged + retry)
            guard !refresh.isEmpty else { return }
            for id in refresh {
                if let nr = currentRevs[id] { pendingNewRevs[id] = nr }
                db.upsertPin(root: rootPath, trackId: id, contentHash: hashes[id],
                             rev: revs[id] ?? "", state: PinState.wanted.rawValue)
                states[id] = .wanted
            }
            self.publishLocked()
        }
        drain()
    }

    // MARK: - 佇列段（pin 序列 queue 上執行；需持有 lock 的部分在鎖內）

    /// 需持有 [lock] 呼叫。
    private func loadLocked(rootPath: String) {
        states = [:]; hashes = [:]; revs = [:]; pendingNewRevs = [:]
        for row in db.allPins(root: rootPath) {
            let st = PinState(rawValue: row.state) ?? .failed
            if st == .downloading {
                // 殘留重置保留 content_hash：崩潰後舊副本檔案仍可被 GC/unpin 追蹤
                db.upsertPin(root: rootPath, trackId: row.trackId, contentHash: row.contentHash,
                             rev: row.rev, state: PinState.wanted.rawValue)
                states[row.trackId] = .wanted
            } else {
                states[row.trackId] = st
            }
            if let h = row.contentHash { hashes[row.trackId] = h }
            revs[row.trackId] = row.rev
        }
    }

    private func pinLocked(_ requests: [PinRequest]) {
        lock.lock()
        defer { lock.unlock() }
        guard let rootPath = root?.path else { return }
        // DONE 且副本在 → 跳過：重釘整張專輯（新增軌）不得把已離線的軌打成 WANTED
        //（來源已消失的軌重跑會 FAILED，等於弄丟離線副本）
        let queued = requests.filter { r in
            states[r.trackId] != .done || pinnedFileLocked(r.trackId) == nil
        }
        guard !queued.isEmpty else { return }
        for r in queued {
            revs[r.trackId] = r.rev
            pendingNewRevs[r.trackId] = nil
            db.upsertPin(root: rootPath, trackId: r.trackId, contentHash: hashes[r.trackId],
                         rev: r.rev, state: PinState.wanted.rawValue)
            states[r.trackId] = .wanted
        }
        publishLocked()
    }

    private func unpinLocked(_ trackIds: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard let rootPath = root?.path else { return }
        let affected = Set(trackIds.compactMap { hashes[$0] })
        db.deletePins(root: rootPath, trackIds: trackIds)
        for id in trackIds {
            states[id] = nil
            hashes[id] = nil
            revs[id] = nil
            pendingNewRevs[id] = nil
        }
        // GC：跨庫共用（同 hash 他釘）者保留
        for h in affected where db.pinCount(contentHash: h) == 0 {
            try? FileManager.default.removeItem(at: fileURL(hash: h))
        }
        publishLocked()
    }

    /// 消費 WANTED → 複製＋SHA-256 → downloads/<hash> → DONE/FAILED。
    /// 單一 worker 循序執行（對雲端友善）；每軌完成後重新入隊——
    /// setRootSync/revalidateSync 的 queue.sync 至多等一軌複製（= Android pump 逐批放鎖）。
    private func drain() {
        queue.async { self.drainOne() }
    }

    private func drainOne() {
        lock.lock()
        var next: (String, URL)? = nil
        if let entry = states.first(where: { $0.value == .wanted }) {
            if let r = root { // 無 root → 不標 DOWNLOADING，收工
                setStateLocked(entry.key, .downloading)
                next = (entry.key, entry.key.fileURLUnder(r))
            }
        }
        lock.unlock()
        guard let (id, src) = next else { return }

        let hash = Self.fetch(from: src, to: downloadsDir)

        lock.lock()
        // 複製期間被 unpin/換庫 → 狀態已移除，不回寫
        if states[id] == .downloading {
            let oldHash = hashes[id]
            if let hash {
                hashes[id] = hash
                // revalidate 觸發的重抓：成功才提交新 rev（失敗留下次 sync 重試）
                if let nr = pendingNewRevs.removeValue(forKey: id) { revs[id] = nr }
                setStateLocked(id, .done)
                if !fileURL(hash: hash).isFileURLExists {
                    // 完成瞬間被併發刪除（unpin 的 GC 競態）→ 重排重抓
                    setStateLocked(id, .wanted)
                }
            } else {
                setStateLocked(id, .failed)
            }
            // 重抓（rev 變）替換 hash 後，舊 hash 已無本軌引用——他庫也沒引用才刪
            if let oldHash, oldHash != hash, db.pinCount(contentHash: oldHash) == 0 {
                try? FileManager.default.removeItem(at: fileURL(hash: oldHash))
            }
        }
        lock.unlock()
        queue.async { self.drainOne() }
    }

    /// 需持有 [lock] 呼叫。
    private func setStateLocked(_ trackId: String, _ state: PinState) {
        if let rootPath = root?.path {
            db.upsertPin(root: rootPath, trackId: trackId,
                         contentHash: hashes[trackId], rev: revs[trackId] ?? "",
                         state: state.rawValue)
        }
        states[trackId] = state
        publishLocked()
    }

    /// 需持有 [lock] 呼叫；拋到主執行緒。
    private func publishLocked() {
        let snapshot = states
        DispatchQueue.main.async { [weak self] in
            self?.onStatesChanged?(snapshot)
        }
    }

    /// 需持有 [lock] 呼叫。
    private func pinnedFileLocked(_ trackId: String) -> URL? {
        guard states[trackId] == .done, let h = hashes[trackId] else { return nil }
        let u = fileURL(hash: h)
        return u.isFileURLExists ? u : nil
    }

    private func fileURL(hash: String) -> URL {
        downloadsDir.appendingPathComponent(hash)
    }

    // MARK: - 下載層（內容定址）

    /// 複製並計算 SHA-256 → downloads/<hash>；同內容已有副本 = dedup 命中（直接沿用）。
    /// 回傳 hash hex（來源消失/IO 失敗 = nil）。走暫存檔——半途中斷不留損毀副本。
    private static func fetch(from src: URL, to dir: URL) -> String? {
        let fm = FileManager.default
        guard src.isFileURLExists,
              let input = InputStream(url: src) else { return nil }
        input.open()
        defer { input.close() }
        let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) } // move 成功後 tmp 已不存在；dedup 命中時清掉
        guard fm.createFile(atPath: tmp.path, contents: nil),
              let output = OutputStream(url: tmp, append: false) else { return nil }
        output.open()
        defer { output.close() }
        var hasher = SHA256()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while input.hasBytesAvailable {
            let n = input.read(&buf, maxLength: buf.count)
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(data: Data(bytes: buf, count: n))
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return output.write(base.assumingMemoryBound(to: UInt8.self).advanced(by: off),
                                        maxLength: n - off)
                }
                if w <= 0 { return nil }
                off += w
            }
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let dst = dir.appendingPathComponent(hex)
        do {
            if dst.isFileURLExists { return hex } // dedup 命中
            try fm.moveItem(at: tmp, to: dst)
            return hex
        } catch {
            return nil
        }
    }

    /// v0.2 的 pins/（trackId 為檔名）→ 內容定址搬遷：算 hash 改名；之後重釘同內容直接命中。
    private static func migrateLegacyPins(_ legacy: URL?, to downloads: URL) {
        guard let legacy else { return }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            if let h = sha256File(f) {
                let dst = downloads.appendingPathComponent(h)
                if dst.isFileURLExists { try? fm.removeItem(at: f) }
                else { try? fm.moveItem(at: f, to: dst) }
            }
        }
        try? fm.removeItem(at: legacy) // 空目錄也一併移除
    }

    private static func sha256File(_ url: URL) -> String? {
        guard let input = InputStream(url: url) else { return nil }
        input.open()
        defer { input.close() }
        var hasher = SHA256()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while input.hasBytesAvailable {
            let n = input.read(&buf, maxLength: buf.count)
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(data: Data(bytes: buf, count: n))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension URL {
    var isFileURLExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

private extension String {
    /// trackId（= 相對路徑）→ 庫根下的 URL。
    func fileURLUnder(_ root: URL) -> URL {
        root.appendingPathComponent(self)
    }
}
