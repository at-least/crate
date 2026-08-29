import XCTest
@testable import MuCore

/// 現正播放快照契約測試：跑 contract/fixtures/nowplaying_cases/（model.md §1.11）。
final class NowPlayingFixtureTest: XCTestCase {

    func testAllNowPlayingFixtureCasesMatchByteForByte() throws {
        let casesDir = try XCTUnwrap(findDir("contract/fixtures/nowplaying_cases"),
                                     "nowplaying_cases not found")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { name -> Bool in
                var isDir: ObjCBool = false
                let ok = FileManager.default.fileExists(
                    atPath: casesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                return ok && isDir.boolValue
            }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 2)

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
                let snap = NowPlayingSnapshot.parse(e["text"] as? String)
                var pairs: [(String, CanonicalJson.JSONValue)] = []
                if let now = e["nowMs"] as? Int {
                    pairs.append(("displayState", .string(snap.displayState(nowMs: now).rawValue)))
                    pairs.append(("effectivePositionMs", .int(snap.effectivePositionMs(nowMs: now))))
                }
                pairs.append(("name", .string(e["name"] as? String ?? "")))
                pairs.append(("serialized", .string(snap.serialize())))
                pairs.append(("snapshot", .object([
                    ("albumId", snap.albumId.map { .string($0) } ?? .null),
                    ("artist", snap.artist.map { .string($0) } ?? .null),
                    ("durationMs", snap.durationMs.map { .int($0) } ?? .null),
                    ("isPlaying", .bool(snap.isPlaying)),
                    ("positionMs", .int(snap.positionMs)),
                    ("title", snap.title.map { .string($0) } ?? .null),
                    ("trackId", snap.trackId.map { .string($0) } ?? .null),
                    ("updatedAtMs", .int(snap.updatedAtMs)),
                ])))
                out.append(.object(pairs))
            }
            let actual = CanonicalJson.render(.array(out))
            if expected != actual {
                failures.append("case [\(name)]\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(names.count) nowplaying cases drifted:\n\n" +
                failures.joined(separator: "\n\n========\n\n"))
        }
    }

    func testStorageRoundTripAndEscaping() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mu.nowplaying.test"))
        defer { defaults.removePersistentDomain(forName: "mu.nowplaying.test") }
        let snap = NowPlayingSnapshot(trackId: "A/\"quoted\"/01.flac", title: "Ri\\se",
                                      artist: "Aurora\n2", albumId: "alb|A|B",
                                      isPlaying: true, positionMs: 1000,
                                      durationMs: 2000, updatedAtMs: 1700000000000)
        snap.save(to: defaults)
        let back = NowPlayingSnapshot.load(from: defaults)
        XCTAssertEqual(back, snap, "轉義字串來回一致")
        XCTAssertEqual(NowPlayingSnapshot.load(from: nil), .idle, "無共享容器 → idle")
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
