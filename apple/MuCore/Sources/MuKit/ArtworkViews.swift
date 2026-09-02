#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

/// 專輯封面（SwiftUI，iOS/macOS 共用）：正方形、連續圓角；載入中/無封面顯示 `PlaceholderArt`。
/// 首次顯示先取同步快取（避免閃佔位圖），再以 `.task(id: url)` 非同步載入。
public struct ArtworkImage: View {
    public let key: String
    public let url: URL?
    public let loader: ArtworkLoader
    public let cornerRadius: CGFloat
    @State private var image: CGImage?

    public init(key: String, url: URL?, loader: ArtworkLoader, cornerRadius: CGFloat = 12) {
        self.key = key
        self.url = url
        self.loader = loader
        self.cornerRadius = cornerRadius
        _image = State(initialValue: loader.cached(key: key) ?? nil)
    }

    public var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    PlaceholderArt(key: key)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                guard let url else { return }
                let img = await loader.image(key: key, trackURL: url)
                if !Task.isCancelled { image = img }
            }
    }
}

/// 無封面佔位：由 key（albumId）穩定雜湊出色相的雙色漸層 + 音符，每張專輯顏色固定。
public struct PlaceholderArt: View {
    public let key: String
    public let symbol: String

    public init(key: String, symbol: String = "music.note") {
        self.key = key
        self.symbol = symbol
    }

    public var body: some View {
        let hue = Self.hue(for: key)
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.42, brightness: 0.62),
                    Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1),
                          saturation: 0.55, brightness: 0.34),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                if !symbol.isEmpty {
                    Image(systemName: symbol)
                    .font(.system(size: max(10, g.size.width * 0.34), weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
        }
    }

    /// djb2（Swift `hashValue` 每次啟動隨機，不可用於穩定配色）。
    public static func hue(for key: String) -> Double {
        var h: UInt32 = 5381
        for b in key.utf8 { h = h &* 33 &+ UInt32(b) }
        h ^= h >> 16  // 尾端字元不獨佔低位——相鄰 id 也拉開色相
        h = h &* 0x45d9f3b
        h ^= h >> 16
        return Double(h % 360) / 360
    }
}
#endif

/// 空狀態 / 訊息頁：符號 + 標題 + 說明（歡迎頁除外的所有「沒東西可顯示」畫面共用）。
public struct EmptyState: View {
    public let symbol: String
    public let title: String
    public let message: String?

    public init(symbol: String, title: String, message: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}
