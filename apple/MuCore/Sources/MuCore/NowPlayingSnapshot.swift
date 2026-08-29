import Foundation

/// 現正播放快照（model.md §1.11）：播放器 → Widget 的單向資料。
/// 純整數/字串；序列化與 Python/Kotlin byte-identical。
public struct NowPlayingSnapshot: Equatable {

    public enum DisplayState: String {
        case idle, paused, playing
    }

    /// 預設過期門檻：6 小時。
    public static let staleAfterMs = 6 * 60 * 60 * 1000
    /// 共享儲存鍵（App Group UserDefaults / SharedPreferences）。
    public static let storageKey = "nowPlaying"

    public let trackId: String?
    public let title: String?
    public let artist: String?
    public let albumId: String?
    public let isPlaying: Bool
    public let positionMs: Int
    public let durationMs: Int?
    public let updatedAtMs: Int

    public init(trackId: String? = nil, title: String? = nil, artist: String? = nil,
                albumId: String? = nil, isPlaying: Bool = false, positionMs: Int = 0,
                durationMs: Int? = nil, updatedAtMs: Int = 0) {
        self.trackId = (trackId?.isEmpty ?? true) ? nil : trackId
        self.title = (title?.isEmpty ?? true) ? nil : title
        self.artist = (artist?.isEmpty ?? true) ? nil : artist
        self.albumId = (albumId?.isEmpty ?? true) ? nil : albumId
        self.isPlaying = isPlaying
        self.positionMs = max(0, positionMs)
        self.durationMs = durationMs.map { max(0, $0) }
        self.updatedAtMs = updatedAtMs
    }

    public static let idle = NowPlayingSnapshot()

    /// 壞 JSON / 缺鍵 / 型別不符 → 該欄位取預設。
    public static func parse(_ text: String?) -> NowPlayingSnapshot {
        guard let text, !text.isEmpty, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .idle
        }
        func str(_ key: String) -> String? {
            guard let v = obj[key] as? String, !v.isEmpty else { return nil }
            return v
        }
        func int(_ key: String) -> Int? {
            guard let n = obj[key] as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
            return n.intValue
        }
        let playing = (obj["isPlaying"] as? NSNumber).map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
        } ?? false
        return NowPlayingSnapshot(
            trackId: str("trackId"), title: str("title"), artist: str("artist"),
            albumId: str("albumId"), isPlaying: playing,
            positionMs: int("positionMs") ?? 0, durationMs: int("durationMs"),
            updatedAtMs: int("updatedAtMs") ?? 0)
    }

    /// canonical（鍵序固定、無空白）——三方 byte-identical。
    public func serialize() -> String {
        func q(_ v: String?) -> String {
            guard let v else { return "null" }
            var out = ""
            CanonicalJson.escapeInto(v, &out) // 已含外層引號
            return out
        }
        return "{\"albumId\":\(q(albumId)),\"artist\":\(q(artist)),"
            + "\"durationMs\":\(durationMs.map(String.init) ?? "null"),"
            + "\"isPlaying\":\(isPlaying),\"positionMs\":\(positionMs),"
            + "\"title\":\(q(title)),\"trackId\":\(q(trackId)),\"updatedAtMs\":\(updatedAtMs)}"
    }

    public func displayState(nowMs: Int, staleAfterMs: Int = NowPlayingSnapshot.staleAfterMs)
        -> DisplayState {
        guard trackId != nil else { return .idle }
        if nowMs - updatedAtMs > staleAfterMs { return .idle }
        return isPlaying ? .playing : .paused
    }

    /// 推算目前位置（playing 才隨時鐘前進；clamp 到時長）。
    public func effectivePositionMs(nowMs: Int,
                                    staleAfterMs: Int = NowPlayingSnapshot.staleAfterMs) -> Int {
        guard displayState(nowMs: nowMs, staleAfterMs: staleAfterMs) == .playing else {
            return max(0, positionMs)
        }
        var pos = positionMs + max(0, nowMs - updatedAtMs)
        if let durationMs { pos = min(pos, durationMs) }
        return max(0, pos)
    }

    // MARK: - 共享儲存（App Group）

    public static func load(from defaults: UserDefaults?) -> NowPlayingSnapshot {
        parse(defaults?.string(forKey: storageKey))
    }

    public func save(to defaults: UserDefaults?) {
        defaults?.set(serialize(), forKey: Self.storageKey)
    }
}
