import XCTest
import CryptoKit
@testable import CrateCore

/// GDrive provider 契約測試：跑 contract/fixtures/gdrive_cases/。
/// FakeDrive = HTTP 語意層的 in-memory Drive（與 gdrive_generate.py 同語意）；
/// 每步輸出 {provider 統計, SyncReport} 必須與 Python 參考 byte-identical（provider.md §8）。
final class GDriveFixtureTest: XCTestCase {

    static let root = "root0"

    func testAllGDriveFixtureCasesMatchByteForByte() throws {
        let casesDir = try XCTUnwrap(findDir("contract/fixtures/gdrive_cases"), "gdrive_cases not found")
        let assetsDir = try XCTUnwrap(findDir("contract/fixtures/sync_assets"), "sync_assets not found")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { name -> Bool in
                var isDir: ObjCBool = false
                let ok = FileManager.default.fileExists(
                    atPath: casesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                return ok && isDir.boolValue
            }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 7)

        var failures: [String] = []
        for name in names {
            let caseDir = casesDir.appendingPathComponent(name)
            let expected = try String(contentsOf: caseDir.appendingPathComponent("expected.json"),
                                      encoding: .utf8)
            let script = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: try Data(contentsOf: caseDir.appendingPathComponent("script.json")))
                as? [String: Any])
            let drive = FakeDrive(maxPage: script["maxPage"] as? Int ?? 1000)
            let provider = GDriveProvider(rootId: Self.root, transport: drive,
                                          tokenSource: drive, sleep: { _ in })
            let engine = SyncEngine(provider: provider)
            var out: [CanonicalJson.JSONValue] = []
            for step in try XCTUnwrap(script["steps"] as? [[String: Any]]) {
                var deleteAfter: [String] = []
                for op in try XCTUnwrap(step["ops"] as? [[String: Any]]) {
                    try applyOp(drive: drive, assetsDir: assetsDir, op: op, deleteAfter: &deleteAfter)
                }
                drive.requests = 0
                provider.beginRound()
                var error: String? = nil
                var report: CanonicalJson.JSONValue = .null
                do {
                    let r = try engine.sync(afterDelta: {
                        for id in deleteAfter { drive.delete(id) }
                    })
                    report = engine.canonical(r)
                } catch ProviderError.auth {
                    error = "auth"
                } catch ProviderError.transient {
                    error = "transient"
                }
                out.append(.object([
                    ("provider", .object([
                        ("error", error.map { .string($0) } ?? .null),
                        ("reauths", .int(provider.reauths)),
                        ("requests", .int(drive.requests)),
                        ("reset", .bool(provider.reset)),
                        ("sleeps", .array(provider.sleeps.map { .int($0) })),
                        ("unscanned", .array(error == nil ? engine.unscanned.map { .string($0) } : [])),
                    ])),
                    ("report", report),
                ]))
            }
            let actual = CanonicalJson.render(.array(out))
            if expected != actual {
                failures.append("case [\(name)]\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(names.count) gdrive cases drifted:\n\n" +
                failures.joined(separator: "\n\n========\n\n"))
        }
    }

    func testResolveRootAndIsoParse() {
        XCTAssertEqual(GDriveProvider.resolveRoot("https://drive.google.com/drive/u/0/folders/abc123?usp=sharing"), "abc123")
        XCTAssertEqual(GDriveProvider.resolveRoot("https://drive.google.com/open?id=xyz"), "xyz")
        XCTAssertEqual(GDriveProvider.resolveRoot(" abc "), "abc")
        XCTAssertNil(GDriveProvider.resolveRoot(""))
        XCTAssertNil(GDriveProvider.resolveRoot("https://drive.google.com/drive/my-drive"))
        XCTAssertEqual(GDriveProvider.parseIsoMs("2023-11-14T22:15:00.000Z"), 1700000100_000)
        XCTAssertEqual(GDriveProvider.parseIsoMs("2023-11-14T22:15:00Z"), 1700000100_000)
        XCTAssertEqual(GDriveProvider.parseIsoMs("2023-11-14T22:15:00.5Z"), 1700000100_500)
        XCTAssertEqual(GDriveProvider.parseIsoMs("garbage"), 0)
    }

    func testStateRoundTrip() throws {
        let drive = FakeDrive(maxPage: 1000)
        drive.mkdir("d1", name: "A", parent: Self.root, mtime: 1700000000)
        drive.put("f1", name: "x.flac", parent: "d1", data: [1, 2, 3], mtime: 1700000001)
        let p1 = GDriveProvider(rootId: Self.root, transport: drive, tokenSource: drive, sleep: { _ in })
        let s1 = try p1.snapshot()
        XCTAssertEqual(s1.count, 1)
        let exported = try XCTUnwrap(p1.exportState())
        let p2 = GDriveProvider(rootId: Self.root, transport: drive, tokenSource: drive, sleep: { _ in })
        p2.restoreState(exported)
        drive.requests = 0
        XCTAssertEqual(try p2.snapshot(), s1)
        XCTAssertEqual(drive.requests, 1, "還原後 = 純 delta（一個 changes.list）")
        XCTAssertEqual(p2.fileId(for: "A/x.flac"), "f1")
        let req = try p2.mediaRequest(fileId: "f1", range: (10, nil))
        XCTAssertEqual(req.headers["Range"], "bytes=10-")
        XCTAssertEqual(req.url, "https://www.googleapis.com/drive/v3/files/f1?alt=media")
        // 壞狀態 → 視為無 cursor（下輪全量）
        let p3 = GDriveProvider(rootId: Self.root, transport: drive, tokenSource: drive, sleep: { _ in })
        p3.restoreState("{not json")
        XCTAssertNil(p3.exportState())
        // 其他 4xx → 直接傳播
        drive.forced = ["forbidden"]
        XCTAssertThrowsError(try p3.snapshot()) { e in
            XCTAssertEqual(e as? ProviderError, .http(403))
        }
    }

    // MARK: - script ops

    private func applyOp(drive: FakeDrive, assetsDir: URL, op: [String: Any],
                         deleteAfter: inout [String]) throws {
        func s(_ k: String) -> String { op[k] as! String }
        func bytes() throws -> [UInt8] {
            if let asset = op["asset"] as? String {
                return [UInt8](try Data(contentsOf: assetsDir.appendingPathComponent(asset)))
            }
            return Array(s("text").utf8)
        }
        switch s("op") {
        case "mkdir":
            drive.mkdir(s("id"), name: s("name"), parent: op["parent"] as? String,
                        mtime: op["mtime"] as? Int ?? 1700000000)
        case "put":
            drive.put(s("id"), name: s("name"), parent: op["parent"] as? String, data: try bytes(),
                      mtime: op["mtime"] as! Int,
                      mime: op["mime"] as? String ?? "application/octet-stream",
                      md5: op["md5"] as? Bool ?? true)
        case "update":
            drive.update(s("id"), data: try bytes(), mtime: op["mtime"] as! Int)
        case "rename": drive.rename(s("id"), name: s("name"))
        case "move": drive.move(s("id"), parent: op["parent"] as? String)
        case "trash": drive.setTrashed(s("id"), true)
        case "untrash": drive.setTrashed(s("id"), false)
        case "delete": drive.delete(s("id"))
        case "touch": drive.touch(s("id"), mtime: op["mtime"] as! Int)
        case "invalidate_cursor": drive.invalidateCursor()
        case "expire_token": drive.tokenValid = false
        case "fail":
            drive.forced += Array(repeating: s("kind"), count: op["count"] as! Int)
            drive.skip = op["skip"] as? Int ?? 0
        case "delete_after_delta": deleteAfter.append(s("id"))
        default: XCTFail("unknown op: \(s("op"))")
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

// MARK: - FakeDrive（HTTP 語意層；同 gdrive_generate.py）

final class FakeDrive: HttpTransport, TokenSource {

    struct Node {
        var name: String
        var mimeType: String
        var parent: String?
        var trashed: Bool
        var size: Int?
        var md5: String?
        var modifiedAt: Int
        var data: [UInt8]
    }

    static let folder = "application/vnd.google-apps.folder"
    let maxPage: Int
    var nodes: [String: Node] = [:]
    var log: [(Int, String)] = []
    var seq = 0
    var minToken = 1
    var forced: [String] = []
    var skip = 0
    var tokenN = 1
    var tokenValid = true
    var requests = 0

    init(maxPage: Int) { self.maxPage = maxPage }

    // TokenSource
    func token() throws -> String { "tok-\(tokenN)" }
    func refresh() throws -> String { tokenN += 1; tokenValid = true; return "tok-\(tokenN)" }

    // ops
    private func bump(_ id: String) { seq += 1; log.append((seq, id)) }

    func mkdir(_ id: String, name: String, parent: String?, mtime: Int) {
        nodes[id] = Node(name: name, mimeType: Self.folder, parent: parent, trashed: false,
                         size: nil, md5: nil, modifiedAt: mtime * 1000, data: [])
        bump(id)
    }

    func put(_ id: String, name: String, parent: String?, data: [UInt8], mtime: Int,
             mime: String = "application/octet-stream", md5: Bool = true) {
        nodes[id] = Node(name: name, mimeType: mime, parent: parent, trashed: false,
                         size: data.count, md5: md5 ? Self.md5Hex(data) : nil,
                         modifiedAt: mtime * 1000, data: data)
        bump(id)
    }

    func update(_ id: String, data: [UInt8], mtime: Int) {
        nodes[id]!.size = data.count
        nodes[id]!.md5 = Self.md5Hex(data)
        nodes[id]!.modifiedAt = mtime * 1000
        nodes[id]!.data = data
        bump(id)
    }

    func rename(_ id: String, name: String) { nodes[id]!.name = name; bump(id) }
    func move(_ id: String, parent: String?) { nodes[id]!.parent = parent; bump(id) }
    func setTrashed(_ id: String, _ t: Bool) { nodes[id]!.trashed = t; bump(id) }
    func delete(_ id: String) { nodes.removeValue(forKey: id); bump(id) }
    func touch(_ id: String, mtime: Int) { nodes[id]!.modifiedAt = mtime * 1000; bump(id) }
    func invalidateCursor() { seq += 1; minToken = seq + 1 }

    static func md5Hex(_ data: [UInt8]) -> String {
        Insecure.MD5.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined()
    }

    static func iso(_ ms: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: Double(ms / 1000)))
            + String(format: ".%03dZ", ms % 1000)
    }

    private func fileJson(_ id: String, withTrashed: Bool) -> [String: Any] {
        let n = nodes[id]!
        var out: [String: Any] = ["id": id, "name": n.name, "mimeType": n.mimeType,
                                  "parents": [n.parent ?? NSNull()] as [Any],
                                  "modifiedTime": Self.iso(n.modifiedAt)]
        if let s = n.size { out["size"] = String(s) }
        if let m = n.md5 { out["md5Checksum"] = m }
        if withTrashed { out["trashed"] = n.trashed }
        return out
    }

    private func jsonBody(_ obj: Any) -> [UInt8] {
        [UInt8](try! JSONSerialization.data(withJSONObject: obj))
    }

    private func err(_ code: Int, _ msg: String) -> HttpResponse {
        HttpResponse(status: code, body: jsonBody(["error": ["code": code, "message": msg]]))
    }

    // HttpTransport
    func send(_ req: HttpRequest) throws -> HttpResponse {
        requests += 1
        if !forced.isEmpty {
            if skip > 0 {
                skip -= 1
            } else {
                switch forced.removeFirst() {
                case "transient": return err(503, "Backend Error")
                case "ratelimit":
                    return HttpResponse(status: 403, body: jsonBody([
                        "error": ["code": 403, "errors": [["reason": "userRateLimitExceeded"]],
                                  "message": "User Rate Limit Exceeded"]]))
                case "notfound": return err(404, "File not found")
                case "forbidden": return err(403, "Insufficient Permission")
                case "offline": throw TransportError("offline")
                default: fatalError("unknown forced kind")
                }
            }
        }
        if req.headers["Authorization"] != "Bearer tok-\(tokenN)" || !tokenValid {
            return err(401, "Invalid Credentials")
        }
        let comps = URLComponents(string: req.url)!
        var q: [String: String] = [:]
        for it in comps.queryItems ?? [] { q[it.name] = it.value ?? "" }
        let path = comps.path
        if path == "/drive/v3/changes/startPageToken" {
            return HttpResponse(status: 200, body: jsonBody(["startPageToken": String(seq + 1)]))
        }
        if path == "/drive/v3/changes" {
            guard let t = q["pageToken"].flatMap(Int.init), t >= minToken, t <= seq + 1 else {
                return err(400, "Invalid Value")
            }
            let cap = min(q["pageSize"].flatMap(Int.init) ?? 1000, maxPage)
            let entries = log.filter { $0.0 >= t }
            let page = entries.prefix(cap)
            let rest = entries.dropFirst(cap)
            var changes: [[String: Any]] = []
            for (_, id) in page {
                if nodes[id] != nil {
                    changes.append(["fileId": id, "removed": false, "file": fileJson(id, withTrashed: true)])
                } else {
                    changes.append(["fileId": id, "removed": true])
                }
            }
            var out: [String: Any] = ["changes": changes]
            if let first = rest.first {
                out["nextPageToken"] = String(first.0)
            } else {
                out["newStartPageToken"] = String(seq + 1)
            }
            return HttpResponse(status: 200, body: jsonBody(out))
        }
        if path == "/drive/v3/files" {
            guard q["q"] == "trashed=false" else { return err(400, "Invalid Value") }
            let cap = min(q["pageSize"].flatMap(Int.init) ?? 1000, maxPage)
            let start = q["pageToken"].flatMap(Int.init) ?? 0
            let ids = nodes.filter { !$0.value.trashed }.keys.sorted(by: codePointCompare)
            let page = Array(ids.dropFirst(start).prefix(cap))
            var out: [String: Any] = ["files": page.map { fileJson($0, withTrashed: false) }]
            if start + cap < ids.count { out["nextPageToken"] = String(start + cap) }
            return HttpResponse(status: 200, body: jsonBody(out))
        }
        if path.hasPrefix("/drive/v3/files/") {
            let id = String(path.dropFirst("/drive/v3/files/".count))
            guard let n = nodes[id], !n.trashed, q["alt"] == "media" else {
                return err(404, "File not found")
            }
            if let rng = req.headers["Range"], rng.hasPrefix("bytes=") {
                let parts = rng.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                let a = Int(parts[0]) ?? 0
                let b = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : n.data.count - 1
                return HttpResponse(status: 206, body: Array(n.data[a...b]))
            }
            return HttpResponse(status: 200, body: n.data)
        }
        return err(404, "Not Found")
    }
}
