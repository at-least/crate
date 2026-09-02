import CoreGraphics
import XCTest
@testable import MuKit

/// 封面氛圍色（ArtworkTint）：純色 → 對應色相；灰階 → nil（呼叫端退回專輯色相）。
final class ArtworkTintTests: XCTestCase {

    private func solid(r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                         blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    func testPrimaryColorsMapToExpectedHue() {
        let cases: [(UInt8, UInt8, UInt8, Double)] = [
            (255, 0, 0, 0),        // 紅
            (0, 255, 0, 1.0 / 3),  // 綠
            (0, 0, 255, 2.0 / 3),  // 藍
        ]
        for (r, g, b, expected) in cases {
            let hs = ArtworkTint.hueSaturation(from: solid(r: r, g: g, b: b))
            XCTAssertNotNil(hs, "純色應取得色相")
            XCTAssertEqual(hs!.hue, expected, accuracy: 0.01)
            XCTAssertEqual(hs!.saturation, 1, accuracy: 0.02)
        }
    }

    func testGrayscaleArtworkHasNoTint() {
        XCTAssertNil(ArtworkTint.hueSaturation(from: solid(r: 128, g: 128, b: 128)))
        XCTAssertNil(ArtworkTint.hueSaturation(from: solid(r: 255, g: 255, b: 255)))
        XCTAssertNil(ArtworkTint.hueSaturation(from: solid(r: 0, g: 0, b: 0)))
    }

    /// 近灰但略帶色偏（低於門檻）也視為無色——避免掃出莫名其妙的染色。
    func testNearlyGrayIsBelowThreshold() {
        XCTAssertNil(ArtworkTint.hueSaturation(from: solid(r: 130, g: 128, b: 128)))
    }

    func testHsbConversionIsHueStable() {
        XCTAssertEqual(ArtworkTint.hsb(r: 1, g: 1, b: 0).h, 1.0 / 6, accuracy: 0.001)  // 黃
        XCTAssertEqual(ArtworkTint.hsb(r: 0, g: 1, b: 1).h, 0.5, accuracy: 0.001)      // 青
        XCTAssertEqual(ArtworkTint.hsb(r: 1, g: 0, b: 1).h, 5.0 / 6, accuracy: 0.001)  // 洋紅
    }
}
