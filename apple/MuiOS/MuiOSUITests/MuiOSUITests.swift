import XCTest

/// App 層 UI 冒煙（B3/B5 在 iOS 模擬器的機器版）：
/// 掃描 → 專輯瀏覽 → 點播（迷你播放列）→ 專輯釘選（狀態機 + 離線標記）→ 重啟還原。
/// 庫來源 = contract fixture（無 tag FLAC：檔名 fallback，兩軌標題相異利於查詢）。
final class MuiOSUITests: XCTestCase {

    private var lib: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let repo = URL(fileURLWithPath: #filePath)     // …/apple/MuiOS/MuiOSUITests/MuiOSUITests.swift
            .deletingLastPathComponent()               // MuiOSUITests
            .deletingLastPathComponent()               // MuiOS
            .deletingLastPathComponent()               // apple
            .deletingLastPathComponent()               // repo root
        let src = repo.appendingPathComponent(
            "contract/fixtures/cases/flac_no_tags/lib/Aurora/Northern Lights/01 - Rise.flac")
        lib = FileManager.default.temporaryDirectory
            .appendingPathComponent("mu-uitest-\(UUID().uuidString)")
        let albumDir = lib.appendingPathComponent("Aurora/Northern Lights")
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: albumDir.appendingPathComponent("01 - Rise.flac"))
        try FileManager.default.copyItem(at: src, to: albumDir.appendingPathComponent("02 - Awakening.flac"))
    }

    override func tearDownWithError() throws {
        if let lib { try? FileManager.default.removeItem(at: lib) }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MU_ROOT"] = lib.path
        app.launch()
        return app
    }

    func testScanBrowsePlay() throws {
        let app = launch()
        let albumCell = app.staticTexts["Northern Lights"]
        XCTAssertTrue(albumCell.waitForExistence(timeout: 30))
        albumCell.tap()

        let track = app.buttons["track.0"]
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()

        // 迷你播放卡出現（現正播放標題）
        let title = app.staticTexts["player.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Rise")

        // 下一首 → 佇列推進
        app.buttons["player.next"].tap()
        let advanced = expectation(
            for: NSPredicate(format: "label == %@", "Awakening"), evaluatedWith: title)
        wait(for: [advanced], timeout: 10)

        // 播/暫 toggle 不炸
        app.buttons["player.toggle"].tap()
        app.buttons["player.toggle"].tap()
    }

    func testPinAlbumPersistsAcrossRelaunch() throws {
        let app = launch()
        app.staticTexts["Northern Lights"].tap()

        let chip = app.buttons["pinChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertEqual(chip.label, "釘選離線（2 軌）")
        chip.tap()

        let done = expectation(
            for: NSPredicate(format: "label == %@", "已釘選（2 軌，點擊取消）"),
            evaluatedWith: chip)
        wait(for: [done], timeout: 15)

        // 離線標記出現（釘選完成 → 該軌顯示「離線」圖示）
        XCTAssertTrue(app.images["離線"].firstMatch.waitForExistence(timeout: 5))

        // 重啟：索引與釘選都從 DB 還原（同庫不清釘）
        app.terminate()
        let app2 = launch()
        XCTAssertTrue(app2.staticTexts["Northern Lights"].waitForExistence(timeout: 30))
        app2.staticTexts["Northern Lights"].tap()
        let chip2 = app2.buttons["pinChip"]
        XCTAssertTrue(chip2.waitForExistence(timeout: 10))
        XCTAssertEqual(chip2.label, "已釘選（2 軌，點擊取消）")
    }
}
