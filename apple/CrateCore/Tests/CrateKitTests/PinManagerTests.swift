import CryptoKit
import XCTest
@testable import CrateKit

/// PinManager（schema v0.3：內容定址下載層 + root-scoped 記錄層）的語意測試：
/// dedup、換庫休眠/重連、unpin GC、rev 重驗、legacy 搬遷。
final class PinManagerTests: XCTestCase {

    private var dir: URL!
    private var db: CrateDatabase!
    private var pm: PinManager!
    private var dl: URL { dir.appendingPathComponent("dl") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-pins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CrateDatabase(url: dir.appendingPathComponent("test.db"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - helpers

    private func makeRoot(_ name: String, files: [String: String]) throws -> URL {
        let root = dir.appendingPathComponent(name)
        for (path, content) in files {
            let u = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: u, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func waitState(_ id: String, _ target: PinManager.PinState,
                           timeout: TimeInterval = 5, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pm.snapshot()[id] == target { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("pin \(id) 未達 \(target)：\(pm.snapshot())", line: line)
    }

    private func waitUntil(_ cond: @autoclosure () -> Bool,
                           timeout: TimeInterval = 5, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("條件未成立", line: line)
    }

    /// 下載層檔案數（排除進行中暫存檔）。
    private var downloadCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dl.path))?
            .filter { !$0.hasPrefix("tmp-") }.count ?? -1
    }

    // MARK: - 內容定址：同一份檔案跨庫只抓一次

    func testDedupSameContentAcrossLibraries() throws {
        let a = try makeRoot("a", files: ["x/01.flac": "AAA"])
        let b = try makeRoot("b", files: ["x/01.flac": "AAA"]) // 同內容、同相對路徑（不同檔案系統物件）
        pm = PinManager(db: db, downloadsDir: dl)

        pm.setRootSync(a)
        pm.pin([.init(trackId: "x/01.flac", rev: "1:1")])
        waitState("x/01.flac", .done)
        XCTAssertEqual(downloadCount, 1)

        pm.setRootSync(b) // 換庫：b 視角沒有釘選（記錄屬於 a）
        XCTAssertNil(pm.snapshot()["x/01.flac"])

        pm.pin([.init(trackId: "x/01.flac", rev: "1:1")]) // b 也釘同一份 → dedup 命中
        waitState("x/01.flac", .done)
        XCTAssertEqual(downloadCount, 1, "同內容不得產生第二份副本")

        let ra = db.allPins(root: a.path)[0]
        let rb = db.allPins(root: b.path)[0]
        XCTAssertEqual(ra.contentHash, rb.contentHash)
        XCTAssertEqual(db.pinCount(contentHash: ra.contentHash!), 2)
    }

    // MARK: - 換庫休眠：rows 與檔案都保留，切回即重連

    func testSwitchLibraryDormantThenReattach() throws {
        let a = try makeRoot("a", files: ["x/01.flac": "AAA"])
        let b = try makeRoot("b", files: ["y/02.flac": "BBB"])
        pm = PinManager(db: db, downloadsDir: dl)

        pm.setRootSync(a)
        pm.pin([.init(trackId: "x/01.flac", rev: "1:1")])
        waitState("x/01.flac", .done)
        let url = try XCTUnwrap(pm.pinnedFile("x/01.flac"))

        pm.setRootSync(b) // 休眠：不清 rows、不刪檔案
        XCTAssertEqual(pm.snapshot().count, 0) // 顯示層單庫視角
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(db.allPins(root: a.path).count, 1)

        pm.setRootSync(a) // 切回：重連，done 立即恢復（不重抓）
        XCTAssertEqual(pm.snapshot()["x/01.flac"], .done)
        XCTAssertEqual(pm.pinnedFile("x/01.flac"), url)
        XCTAssertEqual(downloadCount, 1)
    }

    // MARK: - unpin GC：跨庫共用（同 hash）者保留

    func testUnpinGarbageCollectsOnlyUnreferencedHash() throws {
        let a = try makeRoot("a", files: ["x/01.flac": "AAA"])
        let b = try makeRoot("b", files: ["x/01.flac": "AAA"])
        pm = PinManager(db: db, downloadsDir: dl)

        pm.setRootSync(a)
        pm.pin([.init(trackId: "x/01.flac", rev: "1:1")])
        waitState("x/01.flac", .done)
        pm.setRootSync(b)
        pm.pin([.init(trackId: "x/01.flac", rev: "1:1")])
        waitState("x/01.flac", .done)

        pm.unpin(["x/01.flac"]) // b 取消：a 仍引用同 hash → 檔案保留
        waitUntil(db.allPins(root: b.path).isEmpty)
        XCTAssertEqual(downloadCount, 1)

        pm.setRootSync(a)
        pm.unpin(["x/01.flac"]) // a 也取消：無引用 → 刪檔
        waitUntil(db.allPins(root: a.path).isEmpty)
        waitUntil(downloadCount == 0)
    }

    // MARK: - rev 重驗：來源變了 → 重抓新內容、舊 hash 回收

    func testRevalidateRequeuesWhenRevChanges() throws {
        let a = try makeRoot("a", files: ["x/01.flac": "AAA"])
        pm = PinManager(db: db, downloadsDir: dl)

        pm.setRootSync(a)
        pm.pin([.init(trackId: "x/01.flac", rev: "1:1")])
        waitState("x/01.flac", .done)

        try "BBB".write(to: a.appendingPathComponent("x/01.flac"), atomically: true, encoding: .utf8)
        pm.revalidateSync(["x/01.flac": "2:2"]) // sync 後 rev 已變
        waitState("x/01.flac", .done)

        let url = try XCTUnwrap(pm.pinnedFile("x/01.flac"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "BBB")
        XCTAssertEqual(downloadCount, 1, "舊 hash 副本應被回收")

        pm.revalidateSync(["x/01.flac": "2:2"]) // rev 未變 → 不重抓
        XCTAssertEqual(pm.snapshot()["x/01.flac"], .done)
    }

    // MARK: - revalidate 失敗不卡死：來源暫時消失 → FAILED，回來後同 rev 重試成功

    func testRevalidateRetriesAfterFailedRefetch() throws {
        let a = try makeRoot("a", files: ["x/01.flac": "AAA"])
        pm = PinManager(db: db, downloadsDir: dl)
        pm.setRootSync(a)
        pm.pin([.init(trackId: "x/01.flac", rev: "1:1")])
        waitState("x/01.flac", .done)

        try FileManager.default.removeItem(at: a.appendingPathComponent("x/01.flac"))
        pm.revalidateSync(["x/01.flac": "2:2"]) // rev 變但來源消失 → FAILED（新 rev 未提交）
        waitState("x/01.flac", .failed)

        try "BBB".write(to: a.appendingPathComponent("x/01.flac"), atomically: true, encoding: .utf8)
        pm.revalidateSync(["x/01.flac": "2:2"]) // 同 rev —— 失敗殘留重試（pendingNewRevs）
        waitState("x/01.flac", .done)
        let url = try XCTUnwrap(pm.pinnedFile("x/01.flac"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "BBB")
    }

    // MARK: - 來源消失：FAILED（重跑不弄丟既有副本的語意由 pin() skip 承擔）

    func testPinMissingSourceFails() throws {
        let a = try makeRoot("a", files: [:])
        pm = PinManager(db: db, downloadsDir: dl)
        pm.setRootSync(a)
        pm.pin([.init(trackId: "nope/01.flac", rev: "1:1")])
        waitState("nope/01.flac", .failed)
    }

    // MARK: - v0.2 pins/ 搬遷：算 hash 改名，成為之後重釘的 dedup 命中

    func testLegacyPinsMigration() throws {
        let legacy = dir.appendingPathComponent("pins")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let content = "LEGACY"
        try content.write(to: legacy.appendingPathComponent("x%2F01.flac"),
                          atomically: true, encoding: .utf8)

        pm = PinManager(db: db, downloadsDir: dl, legacyPinsDir: legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(downloadCount, 1)
        let expected = SHA256.hash(data: Data("LEGACY".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dl.appendingPathComponent(expected).path))

        // 重釘同內容 → 立即命中（實際上仍會跑一次 fetch，但落到同一份檔案）
        let a = try makeRoot("a", files: ["x/01.flac": content])
        pm.setRootSync(a)
        pm.pin([.init(trackId: "x/01.flac", rev: "1:1")])
        waitState("x/01.flac", .done)
        XCTAssertEqual(downloadCount, 1)
    }
}
