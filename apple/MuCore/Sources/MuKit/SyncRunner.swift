import Foundation
import MuCore

/// 同步執行器：引擎只在自有的序列 queue 上觸碰（≈ Android syncMutex + Dispatchers.IO）。
/// open 排隊而非丟棄：冷啟動還原中選新資料夾，等這輪完照樣生效。
/// iOS/macOS 兩個 app 共用（MuiOS AppModel / MuMac AppModel 皆以此驅動引擎）。
public final class SyncRunner {

    public struct Outcome {
        public let rootPath: String
        public let scanning: Bool
        public let state: EngineState
        public let resolved: [String: [String?]]
    }

    private let db: MuDatabase
    private let pinManager: PinManager
    private let queue = DispatchQueue(label: "mu.sync", qos: .userInitiated)
    private var engine: SyncEngine?
    private var root: URL?

    public init(db: MuDatabase, pinManager: PinManager) {
        self.db = db
        self.pinManager = pinManager
    }

    public func open(url rawUrl: URL, bookmark: Data?, hydrate: Bool,
                     onMain: @escaping (Outcome) -> Void) {
        // 書籤解析回來的路徑一律展開 symlink（/tmp → /private/tmp）；
        // 統一正規化，否則冷啟動 root 字串與首次挑選不一致 → setRootSync 誤判換庫而清釘選
        let url = rawUrl.resolvingSymlinksInPath()
        queue.async { [weak self] in
            guard let self else { return }
            if self.root?.path != url.path {
                let e = SyncEngine(provider: LocalFolderProvider(root: url))
                self.engine = e
                self.root = url
                // 換庫清釘選（同庫冷啟動不清）——先於 replaceLibrary 落庫新 root，
                // 此時 DB 仍是舊 root，setRootSync 據此判斷同庫/換庫
                self.pinManager.setRootSync(url)
                if hydrate, let st = self.db.loadEngineState() {
                    e.restoreState(st)
                    self.publish(scanning: true, state: st, url: url, onMain) // 還原即顯示
                }
            }
            guard let engine = self.engine else { return }
            // 每輪 sync 前都亮掃描中（= Android syncLocked；非僅 hydrate 分支）
            self.publish(scanning: true, state: engine.exportState(), url: url, onMain)
            _ = engine.sync()
            let st = engine.exportState()
            // done 釘選的來源 rev 已變 → 重抓（hash 即終極 rev；來源消失的軌不動）
            self.pinManager.revalidateSync(st.tracks.mapValues(\.rev))
            self.publish(scanning: false, state: st, url: url, onMain)
            // 同庫沿用既有書籤；換庫一律寫新書籤（nil = 清除——寫回舊書籤會讓冷啟動開錯庫）。
            // 此時 DB 仍是舊 root（setRootSync 不寫 root），與其判斷同源。
            let persistedRoot = self.db.root()
            self.db.replaceLibrary(
                root: url.path,
                bookmark: persistedRoot == nil || persistedRoot == url.path
                    ? (bookmark ?? self.db.bookmark()) : bookmark,
                state: st)
        }
    }

    public func rescan(_ onMain: @escaping (Outcome) -> Void) {
        queue.async { [weak self] in
            guard let self, let url = self.root, let engine = self.engine else { return }
            self.publish(scanning: true, state: engine.exportState(), url: url, onMain)
            _ = engine.sync()
            let st = engine.exportState()
            self.pinManager.revalidateSync(st.tracks.mapValues(\.rev))
            self.publish(scanning: false, state: st, url: url, onMain)
            self.db.replaceLibrary(root: url.path, bookmark: self.db.bookmark(), state: st)
        }
    }

    private func publish(scanning: Bool, state: EngineState, url: URL,
                         _ onMain: @escaping (Outcome) -> Void) {
        let resolved = engine?.resolvedItems(Self.report(state)) ?? [:]
        let out = Outcome(rootPath: url.path, scanning: scanning, state: state, resolved: resolved)
        DispatchQueue.main.async { onMain(out) }
    }

    private static func report(_ st: EngineState) -> SyncEngine.SyncReport {
        SyncEngine.SyncReport(changes: [], scanned: [], tracks: st.tracks,
                              playlists: st.playlists, errors: st.errors)
    }
}
