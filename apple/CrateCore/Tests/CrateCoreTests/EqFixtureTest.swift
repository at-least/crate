import XCTest
@testable import CrateCore

/// EQ 契約測試：跑 contract/fixtures/eq_cases/（model.md §1.10；純整數三方 byte-identical）。
/// 另含 Biquad/AudioDsp 的性質測試（浮點，不入 byte 契約）。
final class EqFixtureTest: XCTestCase {

    func testAllEqFixtureCasesMatchByteForByte() throws {
        let casesDir = try XCTUnwrap(findDir("contract/fixtures/eq_cases"), "eq_cases not found")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { name -> Bool in
                var isDir: ObjCBool = false
                let ok = FileManager.default.fileExists(
                    atPath: casesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                return ok && isDir.boolValue
            }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 3)

        var failures: [String] = []
        for name in names {
            let caseDir = casesDir.appendingPathComponent(name)
            let expected = try String(contentsOf: caseDir.appendingPathComponent("expected.json"),
                                      encoding: .utf8)
            let script = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: try Data(contentsOf: caseDir.appendingPathComponent("script.json")))
                as? [String: Any])
            var out: [CanonicalJson.JSONValue] = []
            for e in try XCTUnwrap(script["entries"] as? [[String: Any]]) {
                let kind = e["type"] as? String ?? ""
                let entryName = e["name"] as? String ?? ""
                switch kind {
                case "parse", "preset":
                    let eq: EqSettings = kind == "parse"
                        ? EqSettings.parse(e["text"] as? String)
                        : EqSettings.preset(entryName,
                                            enabled: e["enabled"] as? Bool ?? true,
                                            preamp: e["preamp"] as? Int ?? 0)
                    out.append(.object([
                        ("activeBands", .array(eq.activeBands().map {
                            .array([.int($0.hz), .int($0.mb)])
                        })),
                        ("kind", .string(kind)),
                        ("name", .string(entryName)),
                        ("serialized", .string(eq.serialize())),
                        ("settings", settingsJson(eq)),
                    ]))
                case "gain":
                    let eq = EqSettings.parse(e["eq"] as? String)
                    let mode = ReplayGain.Mode(rawValue: e["mode"] as? String ?? "") ?? .off
                    let gain = eq.playbackGainMb(mode: mode,
                                                 trackMb: e["trackMb"] as? Int,
                                                 albumMb: e["albumMb"] as? Int)
                    out.append(.object([
                        ("gainMb", .int(gain)),
                        ("identity", .bool(eq.isIdentity(gainMb: gain))),
                        ("kind", .string(kind)),
                        ("name", .string(entryName)),
                    ]))
                default:
                    XCTFail("unknown entry type [\(kind)] in case [\(name)]")
                }
            }
            let actual = CanonicalJson.render(.array(out))
            if expected != actual {
                failures.append("case [\(name)]\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(names.count) eq cases drifted:\n\n" +
                failures.joined(separator: "\n\n========\n\n"))
        }
    }

    private func settingsJson(_ eq: EqSettings) -> CanonicalJson.JSONValue {
        .object([
            ("bands", .array(eq.bands.map { .int($0) })),
            ("enabled", .bool(eq.enabled)),
            ("preamp", .int(eq.preamp)),
            ("preset", .string(eq.preset)),
        ])
    }

    // MARK: - DSP 性質（浮點；不入 byte 契約）

    func testPeakingFilterMagnitudeResponse() {
        let fs = 48000.0
        for db in [-12.0, -6.0, 3.0, 12.0] {
            let bq = Biquad.peaking(sampleRate: fs, f0: 1000, gainDb: db)
            let atCenter = 20 * log10(bq.magnitude(atHz: 1000, sampleRate: fs))
            XCTAssertEqual(atCenter, db, accuracy: 0.01, "中心頻率增益 = 設定值")
            // 遠離中心 → 接近 0 dB（peaking 特性）
            XCTAssertEqual(20 * log10(bq.magnitude(atHz: 20, sampleRate: fs)), 0, accuracy: 0.6)
            XCTAssertEqual(20 * log10(bq.magnitude(atHz: 20000, sampleRate: fs)), 0, accuracy: 0.6)
        }
        // 退化情形 → identity
        XCTAssertEqual(Biquad.peaking(sampleRate: fs, f0: 1000, gainDb: 0), .identity)
        XCTAssertEqual(Biquad.peaking(sampleRate: 8000, f0: 16000, gainDb: 6), .identity,
                       "f0 ≥ Nyquist → 略過")
        XCTAssertEqual(Biquad.identity.magnitude(atHz: 1000, sampleRate: fs), 1, accuracy: 1e-12)
    }

    func testDspIdentityGainAndClipping() {
        let dsp = AudioDsp()
        let input: [Float] = (0..<64).map { Float(sin(Double($0) * 0.1)) }

        dsp.configure(settings: .default, gainMb: 0, sampleRate: 48000, channels: 2)
        XCTAssertTrue(dsp.isIdentity)
        XCTAssertEqual(dsp.processed(input, channels: 2), input, "直通不動樣本")

        // 純增益（負）：線性縮放
        dsp.configure(settings: .default, gainMb: -600, sampleRate: 48000, channels: 2)
        XCTAssertFalse(dsp.isIdentity)
        let scaled = dsp.processed(input, channels: 2)
        let expected = EqSettings.linear(mb: -600)
        for (a, b) in zip(scaled, input) {
            XCTAssertEqual(a, b * expected, accuracy: 1e-5)
        }

        // 正增益放大（v1.3）＋削峰保護
        dsp.configure(settings: .default, gainMb: 1200, sampleRate: 48000, channels: 1)
        XCTAssertGreaterThan(EqSettings.linear(mb: 1200), 1)
        let loud = dsp.processed([0.9, -0.9, 0.1], channels: 1)
        XCTAssertEqual(loud[0], 1, accuracy: 1e-6)
        XCTAssertEqual(loud[1], -1, accuracy: 1e-6)
        XCTAssertEqual(loud[2], 0.1 * EqSettings.linear(mb: 1200), accuracy: 1e-5)
    }

    func testDspBandBoostRaisesEnergyAndStaysStable() {
        let fs = 48000.0
        let dsp = AudioDsp()
        // 1 kHz 段 +12 dB；輸入 1 kHz 正弦 → 輸出振幅明顯放大且有界
        let eq = EqSettings(bands: [0, 0, 0, 0, 0, 1200, 0, 0, 0, 0], enabled: true)
        dsp.configure(settings: eq, gainMb: 0, sampleRate: fs, channels: 1)
        XCTAssertFalse(dsp.isIdentity)
        let n = 4800
        let input: [Float] = (0..<n).map { Float(0.2 * sin(2 * Double.pi * 1000 * Double($0) / fs)) }
        let out = dsp.processed(input, channels: 1)
        func rms(_ xs: ArraySlice<Float>) -> Double {
            (xs.reduce(0.0) { $0 + Double($1 * $1) } / Double(xs.count)).squareRoot()
        }
        let ratio = rms(out[(n / 2)...]) / rms(input[(n / 2)...])
        XCTAssertEqual(20 * log10(ratio), 12, accuracy: 0.5, "穩態增益 ≈ +12 dB")
        XCTAssertTrue(out.allSatisfy { $0.isFinite && abs($0) <= 1 }, "有界且無 NaN")

        // 未觸及的頻率（100 Hz）幾乎不變
        let low: [Float] = (0..<n).map { Float(0.2 * sin(2 * Double.pi * 100 * Double($0) / fs)) }
        dsp.reset()
        let lowOut = dsp.processed(low, channels: 1)
        let lowRatio = rms(lowOut[(n / 2)...]) / rms(low[(n / 2)...])
        XCTAssertEqual(20 * log10(lowRatio), 0, accuracy: 1.0)
    }

    func testDspInterleavedChannelsIndependent() {
        let dsp = AudioDsp()
        let eq = EqSettings(bands: [0, 0, 0, 0, 0, 1200, 0, 0, 0, 0], enabled: true)
        dsp.configure(settings: eq, gainMb: 0, sampleRate: 48000, channels: 2)
        // 左聲道有訊號、右聲道全 0 → 右聲道輸出仍為 0（狀態未串音）
        var buf = [Float](repeating: 0, count: 256)
        for i in stride(from: 0, to: 256, by: 2) { buf[i] = Float(sin(Double(i) * 0.05)) }
        let out = dsp.processed(buf, channels: 2)
        for i in stride(from: 1, to: 256, by: 2) {
            XCTAssertEqual(out[i], 0, accuracy: 1e-9)
        }
    }

    private func findDir(_ rel: String) -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            let c = dir.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: c.path) { return c }
            if dir.path == "/" { return nil }
            dir = dir.deletingLastPathComponent()
        }
    }
}
