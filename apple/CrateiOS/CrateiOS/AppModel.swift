import Foundation
import CrateCore
import CrateKit

/// 音樂庫狀態：SyncEngine 首掃/增量 → 專輯/音軌/清單 UI 狀態（≈ Android LibraryViewModel）。
/// 索引與庫根持久化於 CrateDatabase（schema.sql v0.2）：冷啟動先還原（即時 UI）再 delta 同步
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
    let artwork = ArtworkLoader()
    let pinManager: PinManager
    private let db: CrateDatabase
    private let runner: SyncRunner

    /// 上一輪索引快照（rebuildUi 用；pin 變動不需重掃）。
    private var lastIndex: EngineState?
    private var lastResolved: [String: [String?]] = [:]
    private var rootPath: String?

    init(db: CrateDatabase, pinManager: PinManager) {
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

    /// 釘選整張專輯（可見軌 = available 或已釘）；rev 取自引擎索引（sync 後重驗用）。
    func pinAlbum(_ albumId: String) {
        let reqs = (ui.tracksByAlbum[albumId] ?? []).map { t in
            PinManager.PinRequest(trackId: t.id, rev: lastIndex?.tracks[t.path]?.rev ?? "")
        }
        pinManager.pin(reqs)
    }

    func unpinAlbum(_ albumId: String) {
        pinManager.unpin(ui.tracksByAlbum[albumId]?.map(\.id) ?? [])
    }

    /// 播放（專輯/清單共用）：釘選副本優先，否則庫根原檔。
    func play(_ tracks: [Track], startIndex: Int) {
        player.play(tracks, startIndex: startIndex) { [weak self] t in
            self?.fileURL(for: t) ?? URL(fileURLWithPath: t.path)
        }
    }

    /// 音軌實體檔：釘選副本優先，否則庫根原檔。
    func fileURL(for t: Track) -> URL? {
        guard let rootPath else { return nil }
        return pinManager.pinnedFile(t.id)
            ?? URL(fileURLWithPath: rootPath).appendingPathComponent(t.path)
    }

    /// 封面線索檔：artTrackId（有 tag 的軌）優先，否則專輯第一軌（資料夾封面）。
    func artworkURL(for albumId: String) -> URL? {
        guard let tracks = ui.tracksByAlbum[albumId], let first = tracks.first else { return nil }
        let art = ui.albums.first { $0.id == albumId }?.artTrackId
        let t = tracks.first { $0.id == art } ?? first
        return fileURL(for: t)
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
            albums: CrateCore.Scanner.groupAlbums(tracks).sorted { a, b in
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


/// Kotlin String.compareTo 對等（UTF-16 字典序；Swift 的 `<` 是正規等價比較，非此序）。
private func utf16Less(_ a: String, _ b: String) -> Bool {
    Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
}
