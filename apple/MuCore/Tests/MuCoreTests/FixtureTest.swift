import XCTest
@testable import MuCore

/// 契約測試：跑 contract/fixtures/cases/ 全部案例，
/// Swift 掃描器輸出必須與 Python 參考實作的 expected.json byte-identical。
/// （ acceptance.md A4/C1 — 在 Mac 上 `swift test` ）
final class FixtureTest: XCTestCase {

    func testAllFixtureCasesMatchByteForByte() throws {
        let casesDir = try XCTUnwrap(findCasesDir(), "contract/fixtures/cases not found")
        let names = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
                .filter { name -> Bool in
                    var isDir: ObjCBool = false
                    let ok = FileManager.default.fileExists(
                        atPath: casesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                    return ok && isDir.boolValue
                }
                .sorted())
        XCTAssertGreaterThanOrEqual(names.count, 20)

        var failures: [String] = []
        for name in names {
            let expected = try String(contentsOf: casesDir.appendingPathComponent("\(name)/expected.json"),
                                      encoding: .utf8)
            let result = try Scanner.scan(root: casesDir.appendingPathComponent("\(name)/lib"))
            let actual = CanonicalJson.render(CanonicalJson.canonical(result))
            if expected != actual {
                failures.append("case [\(name)]\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(names.count) cases drifted:\n\n" +
                failures.joined(separator: "\n\n========\n\n"))
        }
    }

    func testExtinfMsConversionIsFloatFreeDeterministic() {
        XCTAssertEqual(213500, Scanner.extinfToMs("213.5"))
        XCTAssertEqual(5000, Scanner.extinfToMs("5"))
        XCTAssertEqual(500, Scanner.extinfToMs(".5"))
        XCTAssertEqual(5400, Scanner.extinfToMs("5.4005"))
        XCTAssertEqual(-1500, Scanner.extinfToMs("-1.5"))
        XCTAssertNil(Scanner.extinfToMs(""))
        XCTAssertNil(Scanner.extinfToMs("abc"))
        XCTAssertNil(Scanner.extinfToMs("1.2.3"))
    }

    func testCanonicalJsonEscapingMatchesSpec() {
        let m = CanonicalJson.JSONValue.object([
            ("b", .string("引")), ("a", .array([])),
        ])
        XCTAssertEqual("{\n  \"a\": [],\n  \"b\": \"引\"\n}\n", CanonicalJson.render(m))
        let s = CanonicalJson.render(.string("\u{01} \n \" \\"))
        XCTAssertEqual("\"\\u0001 \\n \\\" \\\\\"\n", s)
    }

    private func findCasesDir() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            let c = dir.appendingPathComponent("contract/fixtures/cases")
            if FileManager.default.fileExists(atPath: c.path) { return c }
            if dir.path == "/" { return nil }
            dir = dir.deletingLastPathComponent()
        }
    }
}
