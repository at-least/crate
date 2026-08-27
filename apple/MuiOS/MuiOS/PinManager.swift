import Foundation
import MuCore

/// 釘選離線（schema.sql pins 表的狀態機）：pin → 檔案複製到 Application Support/pins/ →
/// 來源消失後仍可由 [pinnedFile] 播放。循序佇列；本地 provider = 檔案複製，
/// 雲端 provider 進場時換 provider.download，語意不變（provider.md §1）。
/// 狀態發布永遠在主執行緒（onStatesChanged）。
final class PinManager {

    enum PinState: String {
        case wanted, downloading, done, failed

        var isPending: Bool { self == .wanted || self == .downloading }
    }

    /// 狀態變動時於主執行緒回呼（AppModel 重建 UI 用）。
    var onStatesChanged: (([String: PinState]) -> Void)?

    private let db: MuDatabase
    private let pinsDir: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mu.pins", qos: .utility)

    private var states: [String: PinState] = [:]
    private var root: URL?

    init(db: MuDatabase, pinsDir: URL) {
        self.db = db
        self.pinsDir = pinsDir
        try? FileManager.default.createDirectory(at: pinsDir, withIntermediateDirectories: true)
        lock.lock()
        // 行程中斷殘留的 DOWNLOADING 重置為 WANTED，自動續傳
        for row in db.allPins() {
            let st = PinState(rawValue: row.state) ?? .failed
            if st == .downloading {
                db.upsertPin(trackId: row.trackId, state: PinState.wanted.rawValue)
                states[row.trackId] = .wanted
            } else {
                states[row.trackId] = st
            }
        }
        lock.unlock()
        drain()
    }

    /// 換庫 = 清釘選（單庫語意）；同庫冷啟動 = 接回 root，不清。
    /// 以 DB 持久化的 root 判斷（sync 流程在 replaceLibrary 之前呼叫，此時 DB 仍是舊 root）。
    /// 同步執行——呼叫端（sync 序列 queue）需等待語意定案後才落庫新 root。
    func setRootSync(_ newRoot: URL) {
        queue.sync {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.root?.path != newRoot.path else { return }
            let persisted = self.db.root()
            if let persisted, persisted == newRoot.path {
                self.root = newRoot // 同庫重開：釘選保留
                return
            }
            self.root = newRoot
            self.db.clearPins()
            if let files = try? FileManager.default.contentsOfDirectory(
                at: self.pinsDir, includingPropertiesForKeys: nil) {
                for f in files { try? FileManager.default.removeItem(at: f) }
            }
            self.states = [:]
            self.publishLocked()
        }
        drain()
    }

    func pin(_ trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        queue.async {
            self.pinLocked(trackIds)
        }
        drain()
    }

    func unpin(_ trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        queue.async {
            self.unpinLocked(trackIds)
        }
    }

    /// 釘選完成且檔案在 → 副本 URL；否則 nil。同步呼叫（播放解析用）。
    func pinnedFile(_ trackId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard states[trackId] == .done else { return nil }
        let u = fileURL(for: trackId)
        return u.isFileURLExists ? u : nil
    }

    /// 目前狀態快照（任意執行緒）。
    func snapshot() -> [String: PinState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    /// pin 的佇列段（pin 序列 queue 上執行；需持有 lock 的部分在鎖內）。
    private func pinLocked(_ trackIds: [String]) {
        lock.lock()
        defer { lock.unlock() }
        // DONE 且檔案在 → 跳過：重釘整張專輯（新增軌）不得把已離線的軌打成 WANTED
        //（來源已消失的軌重跑會 FAILED，等於弄丟離線副本）
        let queued = trackIds.filter { id in
            states[id] != .done || !fileURL(for: id).isFileURLExists
        }
        guard !queued.isEmpty else { return }
        for id in queued {
            db.upsertPin(trackId: id, state: PinState.wanted.rawValue)
            states[id] = .wanted
        }
        publishLocked()
    }

    private func unpinLocked(_ trackIds: [String]) {
        lock.lock()
        defer { lock.unlock() }
        db.deletePins(trackIds)
        for id in trackIds {
            states[id] = nil
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
        publishLocked()
    }

    /// 消費 WANTED → 複製 → DONE/FAILED。單一 worker 循序執行（對雲端友善）；
    /// 每軌完成後重新入隊——setRootSync 的 queue.sync 至多等一軌複製（= Android pump 逐批放鎖）。
    private func drain() {
        queue.async { self.drainOne() }
    }

    private func drainOne() {
        lock.lock()
        var next: (String, URL)? = nil
        if let entry = states.first(where: { $0.value == .wanted }) {
            if let r = root { // 無 root（換庫清釘前）→ 不標 DOWNLOADING，收工
                setStateLocked(entry.key, .downloading)
                next = (entry.key, entry.key.fileURLUnder(r))
            }
        }
        lock.unlock()
        guard let (id, src) = next else { return }

        let dst = fileURL(for: id)
        let ok = Self.copy(from: src, to: dst)

        lock.lock()
        // 複製期間被 unpin/換庫 → 狀態已移除，不回寫
        if states[id] == .downloading {
            setStateLocked(id, ok ? .done : .failed)
        }
        lock.unlock()
        queue.async { self.drainOne() }
    }

    /// 需持有 [lock] 呼叫。
    private func setStateLocked(_ trackId: String, _ state: PinState) {
        db.upsertPin(trackId: trackId, state: state.rawValue)
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

    private func fileURL(for trackId: String) -> URL {
        pinsDir.appendingPathComponent(
            trackId.replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: "/", with: "%2F"))
    }

    private static func copy(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            return true
        } catch {
            return false
        }
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
