import XCTest
@testable import MuCore

/// 同步引擎契約測試：跑 contract/fixtures/sync_cases/ 全部案例。
/// 驅動 = script.json 步驟 → 真實暫存目錄樹（顯式 mtime）→ 每步一輪 sync()；
/// Swift 引擎輸出必須與 Python 參考實作的 expected.json byte-identical（sync-rules.md §3）。
final class SyncFixtureTest: XCTestCase {

    func testAllSyncFixtureCasesMatchByteForByte() throws {
        let casesDir = try XCTUnwrap(findDir("contract/fixtures/sync_cases"),
                                     "sync_cases not found")
        let assetsDir = try XCTUnwrap(findDir("contract/fixtures/sync_assets"),
                                      "sync_assets not found")
        let names = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
                .filter { name -> Bool in
                    var isDir: ObjCBool = false
                    let ok = FileManager.default.fileExists(
                        atPath: casesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                    return ok && isDir.boolValue
                }
                .sorted())
        XCTAssertGreaterThanOrEqual(names.count, 6)

        var failures: [String] = []
        for name in names {
            let caseDir = casesDir.appendingPathComponent(name)
            let expected = try String(contentsOf: caseDir.appendingPathComponent("expected.json"),
                                      encoding: .utf8)
            let script = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: try Data(contentsOf: caseDir.appendingPathComponent("script.json")))
                as? [String: Any])
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mu-sync-\(UUID().uuidString)", isDirectory: true)
            let root = tmp.appendingPathComponent("lib", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let engine = SyncEngine(provider: LocalFolderProvider(root: root))
            var reports: [CanonicalJson.JSONValue] = []
            for step in try XCTUnwrap(script["steps"] as? [[String: Any]]) {
                var deleteAfter: [String] = []
                for op in try XCTUnwrap(step["ops"] as? [[String: Any]]) {
                    try applyOp(root: root, assetsDir: assetsDir, op: op, deleteAfter: &deleteAfter)
                }
                let r = try engine.sync(afterDelta: deleteAfter.isEmpty ? nil : {
                    for p in deleteAfter {
                        try? FileManager.default.removeItem(
                            at: root.appendingPathComponent(p))
                    }
                })
                reports.append(engine.canonical(r))
            }
            let actual = CanonicalJson.render(.array(reports))
            if expected != actual {
                failures.append("case [\(name)]\n--- expected ---\n\(expected)\n" +
                    "--- actual ---\n\(actual)")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(names.count) sync cases drifted:\n\n" +
                failures.joined(separator: "\n\n========\n\n"))
        }
    }

    private func applyOp(
        root: URL, assetsDir: URL, op: [String: Any], deleteAfter: inout [String]
    ) throws {
        let fm = FileManager.default
        func s(_ k: String) -> String { op[k] as! String }
        switch s("op") {
        case "write":
            let url = root.appendingPathComponent(s("path"))
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let data: Data
            if let asset = op["asset"] as? String {
                data = try Data(contentsOf: assetsDir.appendingPathComponent(asset))
            } else {
                data = s("text").data(using: .utf8)!
            }
            try data.write(to: url)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: op["mtime"] as! Double)],
                ofItemAtPath: url.path)
        case "delete":
            try fm.removeItem(at: root.appendingPathComponent(s("path")))
        case "rename":
            let dst = root.appendingPathComponent(s("to"))
            try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: root.appendingPathComponent(s("from")), to: dst)
        case "touch":
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: op["mtime"] as! Double)],
                ofItemAtPath: root.appendingPathComponent(s("path")).path)
        case "delete_after_delta":
            deleteAfter.append(s("path"))
        default:
            XCTFail("unknown op: \(s("op"))")
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
