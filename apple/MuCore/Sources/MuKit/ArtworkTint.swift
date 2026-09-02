import CoreGraphics
import Foundation

/// 由封面取「氛圍色」——現正播放頁的頂部淡染用。
///
/// 做法：整張降到 1×1 取平均色，只留色相與飽和度；亮度/飽和度由呼叫端統一正規化，
/// 避免亮封面染出刺眼的背景、暗封面染不出東西。灰階封面（平均飽和度過低）回 nil，
/// 由呼叫端退回專輯 id 的穩定色相或不染色。
public enum ArtworkTint {

    /// 灰階判定門檻：平均飽和度低於此值視為無色。
    public static let minSaturation = 0.08

    /// 回傳 (hue, saturation)，皆為 0…1；灰階或解碼失敗回 nil。
    public static func hueSaturation(from image: CGImage) -> (hue: Double, saturation: Double)? {
        guard let rgb = averageRGB(of: image) else { return nil }
        let hsb = Self.hsb(r: rgb.r, g: rgb.g, b: rgb.b)
        guard hsb.s >= minSaturation else { return nil }
        return (hsb.h, hsb.s)
    }

    /// 1×1 降取樣的平均色（0…1）。
    static func averageRGB(of image: CGImage) -> (r: Double, g: Double, b: Double)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let a = Double(pixel[3]) / 255
        guard a > 0 else { return nil }
        // premultiplied → 還原
        return (Double(pixel[0]) / 255 / a, Double(pixel[1]) / 255 / a, Double(pixel[2]) / 255 / a)
    }

    /// RGB → HSB（不依賴 UIColor/NSColor，iOS 與 macOS 共用）。
    static func hsb(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        guard delta > 0, maxV > 0 else { return (0, 0, maxV) }
        var h: Double
        switch maxV {
        case r: h = (g - b) / delta
        case g: h = 2 + (b - r) / delta
        default: h = 4 + (r - g) / delta
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, delta / maxV, maxV)
    }
}
