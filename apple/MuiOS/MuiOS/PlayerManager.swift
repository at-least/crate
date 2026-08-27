import AVFoundation
import Foundation
import MediaPlayer
import MuCore

/// 播放核心（≈ Android PlaybackService + MediaController）：
/// AVQueuePlayer 佇列、Now Playing（鎖屏/Control Center）、遠端控制（MPRemoteCommandCenter）、
/// 中斷（來電）與拔耳線暫停。資料來源 = 本地檔 URL（釘選副本優先——resolver 由呼叫端注入）。
/// 全部在主執行緒驅動（UI、KVO/periodic observer、remote command 皆主執行緒回呼）。
final class PlayerManager: NSObject, ObservableObject {

    @Published private(set) var nowTitle: String?
    @Published private(set) var nowArtist: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var hasQueue = false

    private let player = AVQueuePlayer()
    private var tracks: [Track] = []
    private var queueStart = 0
    private var index = 0
    private var resolveFile: ((Track) -> URL)?
    private var rateObs: NSKeyValueObservation?
    private var itemObs: NSKeyValueObservation?
    private var timeObs: Any?

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        rateObs = player.observe(\.rate, options: [.initial, .new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = p.rate > 0
                self.updateNowPlaying()
            }
        }
        itemObs = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.currentItemChanged() }
        }
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            self?.updateElapsed()
        }
        registerRemoteCommands()
        observeSessionEvents()
    }

    /// 播放音軌清單（專輯/清單共用）：從 startIndex 起建佇列；檔案由 resolveFile 決定。
    func play(_ list: [Track], startIndex: Int,
              resolveFile: @escaping (Track) -> URL) {
        guard !list.isEmpty, list.indices.contains(startIndex) else { return }
        tracks = list
        self.resolveFile = resolveFile
        start(at: startIndex)
    }

    func toggle() {
        player.rate > 0 ? player.pause() : player.play()
    }

    func next() { start(at: index + 1) }

    func previous() { start(at: index - 1) }

    private func start(at i: Int) {
        guard tracks.indices.contains(i) else { return }
        index = i
        rebuildQueue(from: i)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    private func rebuildQueue(from i: Int) {
        queueStart = i
        player.removeAllItems()
        for t in tracks[i...] {
            let url = resolveFile?(t) ?? URL(fileURLWithPath: t.path)
            player.insert(AVPlayerItem(url: url), after: player.items().last)
        }
        hasQueue = !tracks.isEmpty
        currentItemChanged()
    }

    // MARK: - 佇列推進 / 現在播放

    private func currentItemChanged() {
        if let cur = player.currentItem,
           let pos = player.items().firstIndex(of: cur) {
            index = queueStart + pos
        }
        let t = tracks.indices.contains(index) ? tracks[index] : nil
        nowTitle = t?.title
        nowArtist = t?.artist
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard hasQueue else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowTitle ?? "",
            MPMediaItemPropertyArtist: nowArtist ?? "",
            MPNowPlayingInfoPropertyPlaybackRate: player.rate > 0 ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds,
        ]
        if let t = tracks.indices.contains(index) ? tracks[index] : nil {
            info[MPMediaItemPropertyAlbumTitle] = t.album
            if let n = t.trackNo { info[MPMediaItemPropertyAlbumTrackNumber] = n }
        }
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateElapsed() {
        guard hasQueue, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 遠端控制（鎖屏/Control Center/耳機）

    private func registerRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        // MPRemoteCommandCenter 在主佇列回呼；動作統一再繞主佇列一次（handler 內不假設進場緒）。
        func handle(_ f: @escaping (PlayerManager) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { [weak self] _ in
                guard let self else { return .commandFailed }
                if Thread.isMainThread {
                    f(self)
                } else {
                    DispatchQueue.main.async { f(self) }
                }
                return .success
            }
        }
        cc.playCommand.addTarget(handler: handle { $0.player.play() })
        cc.pauseCommand.addTarget(handler: handle { $0.player.pause() })
        cc.togglePlayPauseCommand.addTarget(handler: handle { $0.toggle() })
        cc.nextTrackCommand.addTarget(handler: handle { $0.start(at: $0.index + 1) })
        cc.previousTrackCommand.addTarget(handler: handle { $0.start(at: $0.index - 1) })
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self else { return .commandFailed }
            let secs = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            if Thread.isMainThread {
                self.player.seek(to: CMTime(seconds: secs, preferredTimescale: 600))
            } else {
                DispatchQueue.main.async {
                    self.player.seek(to: CMTime(seconds: secs, preferredTimescale: 600))
                }
            }
            return .success
        }
    }

    // MARK: - 音訊事件（來電中斷 / 拔耳線）

    private func observeSessionEvents() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.player.pause()
            case .ended:
                let optRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    // 中斷結束時 session 多半已被停用——恢復前重激活
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.player.play()
                }
            @unknown default:
                break
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else {
                return
            }
            self.player.pause() // 拔耳機自動暫停（= Android setHandleAudioBecomingNoisy）
        }
    }
}
