import XCTest
@testable import MuCore

/// 錯誤語意契約測試：跑 contract/fixtures/err_cases/。
/// RetryPolicy 輸出必須與 Python 參考實作 byte-identical（provider.md §2.1）。
final class ErrFixtureTest: XCTestCase {

    func testAllErrFixtureCasesMatchByteForByte() throws {
        let casesDir = try XCTUnwrap(findDir("contract/fixtures/err_cases"),
                                     "err_cases not found")
        let names = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
                .filter { name -> Bool in
                    var isDir: ObjCBool = false
                    let ok = FileManager.default.fileExists(
                        atPath: casesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                    return ok && isDir.boolValue
                }
                .sorted())
        XCTAssertFalse(names.isEmpty)

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
                XCTAssertEqual(e["type"] as? String, "retry", "unknown entry type in case [\(name)]")
                var queue = (e["script"] as? [String]) ?? []
                let o = RetryPolicy.run(
                    op: {
                        guard let s = queue.first else { return nil }
                        queue.removeFirst()
                        return s == "ok" ? nil : RetryPolicy.kind(from: s)
                    },
                    onReauth: {},
                    sleep: { _ in })
                out.append(.object([
                    ("reauths", .int(o.reauths)),
                    ("result", .string(o.result)),
                    ("sleeps", .array(o.sleeps.map { .int($0) })),
                ]))
            }
            let actual = CanonicalJson.render(.array(out))
            if expected != actual {
                failures.append("case [\(name)]\n--- expected ---\n\(expected)\n" +
                    "--- actual ---\n\(actual)")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(names.count) err cases drifted:\n\n" +
                failures.joined(separator: "\n\n========\n\n"))
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
