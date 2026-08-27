import Foundation
import MuCore

/// 音樂庫狀態：SyncEngine 首掃/增量 → 專輯/音軌/清單 UI 狀態（≈ Android LibraryViewModel）。
/// 索引與庫根持久化於 MuDatabase（schema.sql v0.2）：冷啟動先還原（即時 UI）再 delta 同步
/// （rev 未變不重讀），每輪 sync 後落庫。換資料夾 = 換新引擎 + DB 全量置換（單庫語意）。
/// 釘選：available 或 pinned-done 的軌都進專輯清單（來源消失仍可播）；狀態由 PinManager 推送。
@MainActor
final class AppModel: ObservableObject {

    struct PlaylistUi: Equatable {
        let name: String
        let tracks: [Track]
    }

    struct UiState: Equatable {
        var rootPath: String? = nil
        var scanning = false
        var albums: [Album] = []
        var tracksByAlbum: [String: [Track]] = [:]
        var tracksById: [String: Track] = [:]
        var playlists: [PlaylistUi] = []
        var pinStates: [String: PinManager.PinState] = [:]
    }

    @Published private(set) var ui = UiState()

    let player = PlayerManager()
    let pinManager: PinManager
    private let db: MuDatabase
    private let runner: SyncRunner

    /// 上一輪索引快照（rebuildUi 用；pin 變動不需重掃）。
    private var lastIndex: EngineState?
    private var lastResolved: [String: [String?]] = [:]
    private var rootPath: String?

    init(db: MuDatabase, pinManager: PinManager) {
        self.db = db
        self.pinManager = pinManager
        let runner = SyncRunner(db: db, pinManager: pinManager)
        self.runner = runner
        pinManager.onStatesChanged = { [weak self] _ in
            Task { @MainActor in self?.rebuildUi() }
        }
        #if DEBUG
        // 模擬器冒煙測試鉤子（SIMCTL_CHILD_MU_ROOT 注入；不經文件挑選器）
        if let r = ProcessInfo.processInfo.environment["MU_ROOT"] {
            let url = URL(fileURLWithPath: r)
            runner.open(url: url, bookmark: try? url.bookmarkData(), hydrate: false) {
                [weak self] out in self?.apply(out)
            }
            return
        }
        #endif
        // 冷啟動：還原書籤（security-scoped）→ hydrate 即時 UI → delta 同步
        if let data = db.bookmark(), let url = Self.resolveBookmark(data),
           (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            url.startAccessingSecurityScopedResource()
            runner.open(url: url, bookmark: data, hydrate: true) { [weak self] out in
                self?.apply(out)
            }
        }
    }

    /// 使用者挑選資料夾（document picker；security-scoped URL）。
    func open(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData()
        runner.open(url: url, bookmark: bookmark, hydrate: false) { [weak self] out in
            self?.apply(out)
        }
    }

    /// 增量重掃（外部改檔後；delta：rev 未變的檔案不重讀）。
    func rescan() {
        runner.rescan { [weak self] out in self?.apply(out) }
    }

    /// 釘選/取消釘選整張專輯（可見軌 = available 或已釘）。
    func pinAlbum(_ albumId: String) {
        pinManager.pin(ui.tracksByAlbum[albumId]?.map(\.id) ?? [])
    }

    func unpinAlbum(_ albumId: String) {
        pinManager.unpin(ui.tracksByAlbum[albumId]?.map(\.id) ?? [])
    }

    /// 播放（專輯/清單共用）：釘選副本優先，否則庫根原檔。
    func play(_ tracks: [Track], startIndex: Int) {
        player.play(tracks, startIndex: startIndex) { [weak self] t in
            guard let self, let rootPath else { return URL(fileURLWithPath: t.path) }
            return pinManager.pinnedFile(t.id)
                ?? URL(fileURLWithPath: rootPath).appendingPathComponent(t.path)
        }
    }

    private func apply(_ out: SyncRunner.Outcome) {
        lastIndex = out.state
        lastResolved = out.resolved
        rootPath = out.rootPath
        rebuildUi(scanning: out.scanning)
    }

    /// 由 lastIndex + pin 狀態導出 UI（sync 後與 pin 變動共用；不需重掃）。
    private func rebuildUi(scanning: Bool? = nil) {
        guard let st = lastIndex, let rootPath else { return }
        let pins = pinManager.snapshot()
        // 專輯清單：available 或 pinned-done（來源消失仍可播）
        let tracks = st.tracks.values
            .filter { $0.available || pins[$0.track.id] == .done }
            .map(\.track)
            .sorted { utf16Less($0.path, $1.path) }
        var byId: [String: Track] = [:]
        for t in tracks where byId[t.id] == nil { byId[t.id] = t }
        let playlists: [PlaylistUi] = lastResolved.keys.sorted { utf16Less($0, $1) }
            .compactMap { p in
                guard let raw = st.playlists[p] else { return nil }
                let ts = (lastResolved[p] ?? []).compactMap { byId[$0 ?? ""] }
                return PlaylistUi(name: raw.name, tracks: ts)
            }
        ui = UiState(
            rootPath: rootPath,
            scanning: scanning ?? ui.scanning,
            albums: MuCore.Scanner.groupAlbums(tracks).sorted { a, b in
                a.albumArtist != b.albumArtist
                    ? utf16Less(a.albumArtist, b.albumArtist)
                    : utf16Less(a.name, b.name)
            },
            tracksByAlbum: Dictionary(grouping: tracks, by: { $0.albumId }),
            tracksById: byId,
            playlists: playlists,
            pinStates: pins)
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

/// 同步執行器：引擎只在自有的序列 queue 上觸碰（≈ Android syncMutex + Dispatchers.IO）。
/// open 排隊而非丟棄：冷啟動還原中選新資料夾，等這輪完照樣生效。
private final class SyncRunner {

    struct Outcome {
        let rootPath: String
        let scanning: Bool
        let state: EngineState
        let resolved: [String: [String?]]
    }

    private let db: MuDatabase
    private let pinManager: PinManager
    private let queue = DispatchQueue(label: "mu.sync", qos: .userInitiated)
    private var engine: SyncEngine?
    private var root: URL?

    init(db: MuDatabase, pinManager: PinManager) {
        self.db = db
        self.pinManager = pinManager
    }

    func open(url rawUrl: URL, bookmark: Data?, hydrate: Bool,
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

    func rescan(_ onMain: @escaping (Outcome) -> Void) {
        queue.async { [weak self] in
            guard let self, let url = self.root, let engine = self.engine else { return }
            self.publish(scanning: true, state: engine.exportState(), url: url, onMain)
            _ = engine.sync()
            let st = engine.exportState()
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

/// Kotlin String.compareTo 對等（UTF-16 字典序；Swift 的 `<` 是正規等價比較，非此序）。
private func utf16Less(_ a: String, _ b: String) -> Bool {
    Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
}
