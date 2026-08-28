import AVFoundation
import Foundation
import MuCore
import MuKit

typealias Track = MuCore.Scanner.Track
typealias Album = MuCore.Scanner.Album

/// MuMac 播放：AVQueuePlayer 佇列（無 remote command/audio session——選單列 app 直出聲）。
final class MacPlayer: NSObject, ObservableObject {

    @Published private(set) var nowTitle: String?
    @Published private(set) var nowArtist: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var hasQueue = false
    @Published private(set) var nowTrack: Track?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0

    private let player = AVQueuePlayer()
    private var timeObs: Any?
    private var tracks: [Track] = []
    private var queueStart = 0
    private var index = 0
    private var resolveFile: ((Track) -> URL)?
    private var rateObs: NSKeyValueObservation?
    private var itemObs: NSKeyValueObservation?

    override init() {
        super.init()
        rateObs = player.observe(\.rate, options: [.initial, .new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = p.rate > 0
            }
        }
        itemObs = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.currentItemChanged() }
        }
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            guard let self, self.hasQueue else { return }
            let now = self.player.currentTime().seconds
            if now.isFinite { self.elapsed = now }
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
        }
    }

    func play(_ list: [Track], startIndex: Int, resolveFile: @escaping (Track) -> URL) {
        guard !list.isEmpty, list.indices.contains(startIndex) else { return }
        tracks = list
        self.resolveFile = resolveFile
        start(at: startIndex)
    }

    func toggle() {
        player.rate > 0 ? player.pause() : player.play()
    }

    func next() { start(at: index + 1) }

    /// 上一首：播放超過 3 秒則回到本首開頭（慣例），否則退一首。
    func previous() {
        if player.currentTime().seconds > 3 || index == 0 {
            player.seek(to: .zero)
        } else {
            start(at: index - 1)
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = seconds
    }

    private func start(at i: Int) {
        guard tracks.indices.contains(i) else { return }
        index = i
        queueStart = i
        player.removeAllItems()
        for t in tracks[i...] {
            let url = resolveFile?(t) ?? URL(fileURLWithPath: t.path)
            player.insert(AVPlayerItem(url: url), after: player.items().last)
        }
        hasQueue = !tracks.isEmpty
        currentItemChanged()
        player.play()
    }

    private func currentItemChanged() {
        if let cur = player.currentItem,
           let pos = player.items().firstIndex(of: cur) {
            index = queueStart + pos
        }
        let t = tracks.indices.contains(index) ? tracks[index] : nil
        nowTrack = t
        nowTitle = t?.title
        nowArtist = t?.artist
        elapsed = 0
        duration = Double(t?.durationMs ?? 0) / 1000
    }
}

/// MuMac 音樂庫狀態（≈ MuiOS AppModel 的 mac 版；引擎管線共用 MuKit.SyncRunner）。
/// macOS 非 sandbox：無 security-scoped bookmark，root 直接以路徑持久化於 DB。
@MainActor
final class MacModel: ObservableObject {

    struct PlaylistUi: Equatable {
        let name: String
        let tracks: [Track]
    }

    struct UiState: Equatable {
        var rootPath: String? = nil
        var scanning = false
        var albums: [Album] = []
        var tracksByAlbum: [String: [Track]] = [:]
        var playlists: [PlaylistUi] = []
        var pinStates: [String: PinManager.PinState] = [:]
    }

    @Published private(set) var ui = UiState()

    let player = MacPlayer()
    let artwork = ArtworkLoader(maxPixel: 400)
    let pinManager: PinManager
    private let db: MuDatabase
    private let runner: SyncRunner

    private var lastIndex: EngineState?
    private var lastResolved: [String: [String?]] = [:]
    private var rootPath: String?

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let db: MuDatabase
        do {
            db = try MuDatabase(url: support.appendingPathComponent("mumac.db"))
        } catch {
            fatalError("mumac.db open failed: \(error)")
        }
        self.db = db
        let pinManager = PinManager(db: db, pinsDir: support.appendingPathComponent("pins-mac"))
        self.pinManager = pinManager
        let runner = SyncRunner(db: db, pinManager: pinManager)
        self.runner = runner
        pinManager.onStatesChanged = { [weak self] _ in
            Task { @MainActor in self?.rebuildUi() }
        }
        #if DEBUG
        if let r = ProcessInfo.processInfo.environment["MU_ROOT"] {
            runner.open(url: URL(fileURLWithPath: r), bookmark: nil, hydrate: false) {
                [weak self] out in self?.apply(out)
            }
            return
        }
        #endif
        // 冷啟動：DB root 直接回填（mac 無需書籤）→ hydrate 即時 UI → delta 同步
        if let r = db.root() {
            let url = URL(fileURLWithPath: r)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                runner.open(url: url, bookmark: nil, hydrate: true) { [weak self] out in
                    self?.apply(out)
                }
            }
        }
    }

    func open(url: URL) {
        runner.open(url: url, bookmark: nil, hydrate: false) { [weak self] out in
            self?.apply(out)
        }
    }

    func rescan() {
        runner.rescan { [weak self] out in self?.apply(out) }
    }

    func pinAlbum(_ albumId: String) {
        pinManager.pin(ui.tracksByAlbum[albumId]?.map(\.id) ?? [])
    }

    func unpinAlbum(_ albumId: String) {
        pinManager.unpin(ui.tracksByAlbum[albumId]?.map(\.id) ?? [])
    }

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

    private func rebuildUi(scanning: Bool? = nil) {
        guard let st = lastIndex, let rootPath else { return }
        let pins = pinManager.snapshot()
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
            playlists: playlists,
            pinStates: pins)
    }
}

/// Kotlin String.compareTo 對等（UTF-16 字典序）。
private func utf16Less(_ a: String, _ b: String) -> Bool {
    Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
}
