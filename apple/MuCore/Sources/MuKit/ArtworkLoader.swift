import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// 專輯封面載入（iOS/macOS 共用，UI 無關）：
/// 1. 音軌內嵌圖（ID3 APIC / MP4 covr / FLAC picture，經 AVFoundation commonMetadata）
/// 2. 同資料夾封面檔（cover/folder/front/album.{jpg,jpeg,png}，其次任一圖檔）
/// 解碼時以 ImageIO 縮圖降取樣（maxPixel），結果（含「無封面」）以 key 快取；同 key 併發請求共用一個 Task。
public final class ArtworkLoader {
    private let maxPixel: Int
    private let lock = NSLock()
    private var cache: [String: CGImage?] = [:]
    private var inflight: [String: Task<CGImage?, Never>] = [:]

    public init(maxPixel: Int = 640) {
        self.maxPixel = maxPixel
    }

    /// 已快取結果（同步；未載入回 nil，載入後無封面亦回 nil——用 `cached(key:)` 區分）。
    public func cached(key: String) -> CGImage?? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// 以 `trackURL` 為線索載入封面；`key` 通常為 albumId。
    public func image(key: String, trackURL: URL) async -> CGImage? {
        switch lookup(key: key, trackURL: trackURL) {
        case .hit(let img):
            return img
        case .join(let task):
            return await task.value
        case .started(let task):
            let img = await task.value
            store(key: key, image: img)
            return img
        }
    }

    private enum Lookup {
        case hit(CGImage?), join(Task<CGImage?, Never>), started(Task<CGImage?, Never>)
    }

    // 鎖只在同步函式內持有（async 函式內持鎖會跨 suspension point）。
    private func lookup(key: String, trackURL: URL) -> Lookup {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return .hit(hit) }
        if let running = inflight[key] { return .join(running) }
        let maxPixel = maxPixel
        let task = Task<CGImage?, Never>.detached(priority: .utility) {
            let data = await Self.embeddedArtwork(trackURL) ?? Self.folderArtwork(trackURL)
            return data.flatMap { Self.decode($0, maxPixel: maxPixel) }
        }
        inflight[key] = task
        return .started(task)
    }

    private func store(key: String, image: CGImage?) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = image
        inflight[key] = nil
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }

    // MARK: - sources

    private static func embeddedArtwork(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    private static let preferredNames = ["cover", "folder", "front", "album", "albumart"]
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    private static func folderArtwork(_ url: URL) -> Data? {
        let dir = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        let images = names.filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }
        let ranked = images.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.lowercased() < b.lowercased()
        }
        return try? Data(contentsOf: dir.appendingPathComponent(ranked[0]))
    }

    private static func rank(_ name: String) -> Int {
        let base = (name as NSString).deletingPathExtension.lowercased()
        return preferredNames.firstIndex(of: base) ?? preferredNames.count
    }

    private static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
