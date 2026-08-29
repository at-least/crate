import Foundation

/// ReplayGain 播放套用（model.md §1.9 的消費端）。
/// v1 以播放器音量套增益：線性 = 10^(mb/2000)，**上限 1.0**（只衰減、不放大——AVPlayer/ExoPlayer 音量無法 >1；
/// 正增益要放大需 audio processor，Phase 4 EQ 相位再議）。無前置增益。
public enum ReplayGain {

    public enum Mode: String, CaseIterable {
        case off, track, album

        public var label: String {
            switch self {
            case .off: return "關閉"
            case .track: return "音軌"
            case .album: return "專輯"
            }
        }
    }

    public static let defaultsKey = "replayGainMode"

    /// 依模式取用的增益（millibel）；album 缺值退回 track；無 → nil。
    public static func gainMb(mode: Mode, trackMb: Int?, albumMb: Int?) -> Int? {
        switch mode {
        case .off: return nil
        case .track: return trackMb
        case .album: return albumMb ?? trackMb
        }
    }

    /// 播放器音量（0…1）。
    public static func volume(mode: Mode, trackMb: Int?, albumMb: Int?) -> Float {
        guard let mb = gainMb(mode: mode, trackMb: trackMb, albumMb: albumMb) else { return 1 }
        return Float(min(1.0, pow(10.0, Double(mb) / 2000.0)))
    }

    public static func volume(mode: Mode, track: Scanner.Track?) -> Float {
        volume(mode: mode, trackMb: track?.replayGainTrackMb, albumMb: track?.replayGainAlbumMb)
    }

    public static func mode(from defaults: UserDefaults = .standard) -> Mode {
        Mode(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .album
    }
}
