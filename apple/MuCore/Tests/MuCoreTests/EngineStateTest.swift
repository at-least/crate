import XCTest
@testable import MuCore

/// EngineState export/restore 往返（sync-rules §3：儲存形態是實作細節）。
/// 冷啟動還原後 sync() 必須是 delta——rev 未變的檔案不重讀。
final class EngineStateTest: XCTestCase {

    func testRestoreRoundTripSkipsUnchangedFilesAndCatchesRealDeltas() throws {
        let assetsDir = try XCTUnwrap(findDir("contract/fixtures/sync_assets"), "sync_assets not found")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mu-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func writeAsset(_ rel: String, _ asset: String, _ mtimeSec: TimeInterval) throws {
            let p = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: p.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: assetsDir.appendingPathComponent(asset), to: p)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtimeSec)],
                                                  ofItemAtPath: p.path)
        }
        try writeAsset("A/a1.flac", "flac_a", 100)
        try writeAsset("A/a2.flac", "flac_b", 100)
        let pl = root.appendingPathComponent("lists/favorites.m3u8")
        try FileManager.default.createDirectory(at: pl.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "#EXTM3U\n#EXTINF:10,First\n../A/a1.flac\n".write(to: pl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                                              ofItemAtPath: pl.path)

        // 首掃
        let e1 = SyncEngine(provider: LocalFolderProvider(root: root))
        let r1 = try e1.sync()
        XCTAssertFalse(r1.scanned.isEmpty, "first scan should read files")

        // 匯出 → 新引擎（模擬重啟）→ 還原 → delta：零變更零重讀
        let state = e1.exportState()
        XCTAssertNotNil(state.cursor, "cursor exported")
        let e2 = SyncEngine(provider: LocalFolderProvider(root: root))
        e2.restoreState(state)
        let r2 = try e2.sync()
        XCTAssertTrue(r2.changes.isEmpty, "no changes after restore, got \(r2.changes)")
        XCTAssertTrue(r2.scanned.isEmpty, "no rescans after restore, got \(r2.scanned)")
        XCTAssertEqual(r1.tracks, r2.tracks)
        XCTAssertEqual(r1.playlists, r2.playlists)
        XCTAssertEqual(r1.errors, r2.errors)

        // 改一個檔的 mtime（rev 變）→ 只重掃該檔
        let touched = root.appendingPathComponent("A/a2.flac")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 999)],
                                              ofItemAtPath: touched.path)
        let r3 = try e2.sync()
        XCTAssertEqual(r3.changes.count, 1)
        XCTAssertEqual(r3.changes.first?.path, "A/a2.flac")
        XCTAssertEqual(r3.changes.first?.kind, .modified)
        XCTAssertEqual(r3.scanned, ["A/a2.flac"])
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
