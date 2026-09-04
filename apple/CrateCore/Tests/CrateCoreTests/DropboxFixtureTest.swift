import XCTest
import CryptoKit
@testable import CrateCore

/// Dropbox provider 契約測試：跑 contract/fixtures/dropbox_cases/（provider.md §9）。
/// FakeDropbox = HTTP 語意層 in-memory（與 dropbox_generate.py 同語意）。
final class DropboxFixtureTest: XCTestCase {

    func testAllDropboxFixtureCasesMatchByteForByte() throws {
        let casesDir = try XCTUnwrap(findDir("contract/fixtures/dropbox_cases"), "dropbox_cases not found")
        let assetsDir = try XCTUnwrap(findDir("contract/fixtures/sync_assets"), "sync_assets not found")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { name -> Bool in
                var isDir: ObjCBool = false
                let ok = FileManager.default.fileExists(
                    atPath: casesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                return ok && isDir.boolValue
            }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 8)

        var failures: [String] = []
        for name in names {
            let caseDir = casesDir.appendingPathComponent(name)
            let expected = try String(contentsOf: caseDir.appendingPathComponent("expected.json"),
                                      encoding: .utf8)
            let script = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: try Data(contentsOf: caseDir.appendingPathComponent("script.json")))
                as? [String: Any])
            let box = FakeDropbox(maxPage: script["maxPage"] as? Int ?? 2000)
            let provider = DropboxProvider(root: script["root"] as? String ?? "/Music",
                                           transport: box, tokenSource: box, sleep: { _ in })
            let engine = SyncEngine(provider: provider)
            var out: [CanonicalJson.JSONValue] = []
            for step in try XCTUnwrap(script["steps"] as? [[String: Any]]) {
                var deleteAfter: [String] = []
                for op in try XCTUnwrap(step["ops"] as? [[String: Any]]) {
                    try applyOp(box: box, assetsDir: assetsDir, op: op, deleteAfter: &deleteAfter)
                }
                box.requests = 0
                provider.beginRound()
                var error: String? = nil
                var report: CanonicalJson.JSONValue = .null
                do {
                    let r = try engine.sync(afterDelta: { for p in deleteAfter { box.delete(p) } })
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
                        ("requests", .int(box.requests)),
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
            XCTFail("\(failures.count)/\(names.count) dropbox cases drifted:\n\n" +
                failures.joined(separator: "\n\n========\n\n"))
        }
    }

    func testStateRoundTripAndMediaRequest() throws {
        let box = FakeDropbox(maxPage: 2000)
        box.mkdir("/Music")
        box.put("/Music/x.flac", data: [1, 2, 3], mtime: 1700000001)
        let p1 = DropboxProvider(root: "/music", transport: box, tokenSource: box, sleep: { _ in })
        let s1 = try p1.snapshot()
        XCTAssertEqual(s1.count, 1)
        let exported = try XCTUnwrap(p1.exportState())
        let p2 = DropboxProvider(root: "/music", transport: box, tokenSource: box, sleep: { _ in })
        p2.restoreState(exported)
        box.requests = 0
        XCTAssertEqual(try p2.snapshot(), s1)
        XCTAssertEqual(box.requests, 1, "還原後 = 純 continue（root 亦已還原，不再 get_metadata）")
        let id = try XCTUnwrap(p2.fileId(for: "x.flac"))
        let req = try p2.mediaRequest(fileId: id, range: (10, nil))
        XCTAssertEqual(req.headers["Range"], "bytes=10-")
        XCTAssertEqual(req.headers["Dropbox-API-Arg"], "{\"path\":\"\(id)\"}")
        let p3 = DropboxProvider(root: "/nowhere", transport: box, tokenSource: box, sleep: { _ in })
        XCTAssertThrowsError(try p3.snapshot()) { e in
            XCTAssertEqual(e as? ProviderError, .notFound, "root 不存在 → 傳播")
        }
        p3.restoreState("{bad")
        XCTAssertNil(p3.exportState())
        XCTAssertEqual(FakeDropbox.contentHash([]).count, 64)
    }

    private func applyOp(box: FakeDropbox, assetsDir: URL, op: [String: Any],
                         deleteAfter: inout [String]) throws {
        func s(_ k: String) -> String { op[k] as! String }
        func bytes() throws -> [UInt8] {
            if let asset = op["asset"] as? String {
                return [UInt8](try Data(contentsOf: assetsDir.appendingPathComponent(asset)))
            }
            return Array(s("text").utf8)
        }
        switch s("op") {
        case "mkdir": box.mkdir(s("path"))
        case "put": box.put(s("path"), data: try bytes(), mtime: op["mtime"] as! Int)
        case "rename": box.rename(s("from"), s("to"))
        case "delete": box.delete(s("path"))
        case "touch": box.touch(s("path"), mtime: op["mtime"] as! Int)
        case "invalidate_cursor": box.invalidateCursor()
        case "expire_token": box.tokenValid = false
        case "fail":
            box.forced += Array(repeating: s("kind"), count: op["count"] as! Int)
            box.skip = op["skip"] as? Int ?? 0
        case "delete_after_delta": deleteAfter.append(s("path"))
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

// MARK: - FakeDropbox（HTTP 語意層；同 dropbox_generate.py）

final class FakeDropbox: HttpTransport, TokenSource {

    struct FileNode {
        var display: String
        var id: String
        var data: [UInt8]
        var hash: String
        var modifiedAt: Int
    }

    static let api = "https://api.dropboxapi.com/2"
    static let content = "https://content.dropboxapi.com/2"
    let maxPage: Int
    var files: [String: FileNode] = [:]
    var folders: [String: String] = [:]
    var log: [(Int, String)] = []
    var seq = 0
    var minCursor = 1
    var nextId = 1
    var forced: [String] = []
    var skip = 0
    var tokenN = 1
    var tokenValid = true
    var requests = 0

    init(maxPage: Int) { self.maxPage = maxPage }

    func token() throws -> String { "tok-\(tokenN)" }
    func refresh() throws -> String { tokenN += 1; tokenValid = true; return "tok-\(tokenN)" }

    /// Dropbox content_hash：4MB 分塊 SHA-256 串接後再 SHA-256。
    static func contentHash(_ data: [UInt8]) -> String {
        var outer = SHA256()
        var i = 0
        repeat {
            let end = min(data.count, i + 4 * 1024 * 1024)
            outer.update(data: Data(SHA256.hash(data: Data(data[i..<end]))))
            i += 4 * 1024 * 1024
        } while i < data.count
        return outer.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func iso(_ ms: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: Double(ms / 1000)))
    }

    private func bump(_ pl: String) { seq += 1; log.append((seq, pl)) }

    func mkdir(_ path: String) { folders[path.lowercased()] = path; bump(path.lowercased()) }

    func put(_ path: String, data: [UInt8], mtime: Int) {
        let pl = path.lowercased()
        let id: String
        if let old = files[pl] { id = old.id } else { id = "id:f\(nextId)"; nextId += 1 }
        files[pl] = FileNode(display: path, id: id, data: data, hash: Self.contentHash(data),
                             modifiedAt: mtime * 1000)
        bump(pl)
    }

    func touch(_ path: String, mtime: Int) {
        files[path.lowercased()]!.modifiedAt = mtime * 1000
        bump(path.lowercased())
    }

    func rename(_ src: String, _ dst: String) {
        let sl = src.lowercased(), dl = dst.lowercased()
        if var e = files.removeValue(forKey: sl) {
            e.display = dst
            files[dl] = e
            bump(sl); bump(dl)
            return
        }
        folders.removeValue(forKey: sl)
        folders[dl] = dst
        bump(sl); bump(dl)
        let children = (Array(folders.keys) + Array(files.keys)).filter { $0.hasPrefix(sl + "/") }
            .sorted(by: codePointCompare)
        for pl in children {
            let rest = String(pl.dropFirst(sl.count))
            if let disp = folders.removeValue(forKey: pl) {
                folders[dl + rest] = dst + String(disp.dropFirst(src.count))
            } else if var e = files.removeValue(forKey: pl) {
                e.display = dst + String(e.display.dropFirst(src.count))
                files[dl + rest] = e
            }
            bump(dl + rest)
        }
    }

    func delete(_ path: String) {
        let pl = path.lowercased()
        if files.removeValue(forKey: pl) == nil {
            folders.removeValue(forKey: pl)
            for k in Array(folders.keys) where k.hasPrefix(pl + "/") { folders.removeValue(forKey: k) }
            for k in Array(files.keys) where k.hasPrefix(pl + "/") { files.removeValue(forKey: k) }
        }
        bump(pl)
    }

    func invalidateCursor() { seq += 1; minCursor = seq + 1 }

    private func entry(_ pl: String) -> [String: Any] {
        if let f = files[pl] {
            return [".tag": "file", "name": String(f.display.split(separator: "/").last ?? ""),
                    "path_lower": pl, "path_display": f.display, "id": f.id,
                    "rev": String(f.hash.prefix(9)), "size": f.data.count, "content_hash": f.hash,
                    "server_modified": Self.iso(f.modifiedAt), "client_modified": Self.iso(f.modifiedAt)]
        }
        if let d = folders[pl] {
            return [".tag": "folder", "name": String(d.split(separator: "/").last ?? ""),
                    "path_lower": pl, "path_display": d, "id": "id:d" + pl]
        }
        return [".tag": "deleted", "name": String(pl.split(separator: "/").last ?? ""),
                "path_lower": pl, "path_display": pl]
    }

    private func under(_ rootLower: String, _ pl: String) -> Bool {
        rootLower.isEmpty || pl == rootLower || pl.hasPrefix(rootLower + "/")
    }

    private func jsonBody(_ obj: Any) -> [UInt8] { [UInt8](try! JSONSerialization.data(withJSONObject: obj)) }

    private func notFound() -> HttpResponse {
        HttpResponse(status: 409, body: Array(
            "{\"error_summary\":\"path/not_found/..\",\"error\":{\".tag\":\"path\",\"path\":{\".tag\":\"not_found\"}}}".utf8))
    }

    private func allKeys() -> [String] { Array(folders.keys) + Array(files.keys) }

    func send(_ req: HttpRequest) throws -> HttpResponse {
        requests += 1
        if !forced.isEmpty {
            if skip > 0 {
                skip -= 1
            } else {
                switch forced.removeFirst() {
                case "transient": return HttpResponse(status: 503, body: Array("{\"error_summary\":\"internal\"}".utf8))
                case "ratelimit": return HttpResponse(status: 429, body: Array(
                    "{\"error_summary\":\"too_many_requests/..\",\"error\":{\"reason\":{\".tag\":\"too_many_requests\"}}}".utf8))
                case "notfound": return notFound()
                case "offline": throw TransportError("offline")
                default: fatalError("unknown forced kind")
                }
            }
        }
        if req.headers["Authorization"] != "Bearer tok-\(tokenN)" || !tokenValid {
            return HttpResponse(status: 401, body: Array(
                "{\"error_summary\":\"expired_access_token/..\",\"error\":{\".tag\":\"expired_access_token\"}}".utf8))
        }
        let arg = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any] ?? [:]
        switch req.url {
        case "\(Self.api)/files/get_metadata":
            let pl = (arg["path"] as? String ?? "").lowercased()
            if folders[pl] != nil || files[pl] != nil { return HttpResponse(status: 200, body: jsonBody(entry(pl))) }
            return notFound()
        case "\(Self.api)/files/list_folder/get_latest_cursor":
            let rl = (arg["path"] as? String ?? "").lowercased()
            return HttpResponse(status: 200, body: jsonBody(["cursor": "c\(seq + 1):\(rl)"]))
        case "\(Self.api)/files/list_folder":
            let rl = (arg["path"] as? String ?? "").lowercased()
            if !rl.isEmpty && folders[rl] == nil { return notFound() }
            let cap = min(arg["limit"] as? Int ?? 2000, maxPage)
            let keys = allKeys().filter { under(rl, $0) && $0 != rl }.sorted(by: codePointCompare)
            return HttpResponse(status: 200, body: jsonBody(listPage(keys, cap: cap, rootLower: rl)))
        case "\(Self.api)/files/list_folder/continue":
            let cursor = arg["cursor"] as? String ?? ""
            if cursor.hasPrefix("l") {
                let parts = cursor.dropFirst().split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                let cap = Int(parts[0])!, rl = String(parts[1]), start = String(parts[2])
                let keys = allKeys().filter { under(rl, $0) && $0 != rl && !codePointCompare($0, start) }
                    .sorted(by: codePointCompare)
                return HttpResponse(status: 200, body: jsonBody(listPage(keys, cap: cap, rootLower: rl)))
            }
            guard cursor.hasPrefix("c") else {
                return HttpResponse(status: 400, body: Array("{\"error_summary\":\"invalid cursor\"}".utf8))
            }
            let parts = cursor.dropFirst().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let t = Int(parts[0])!, rl = String(parts[1])
            if t < minCursor || t > seq + 1 {
                return HttpResponse(status: 409, body: Array(
                    "{\"error_summary\":\"reset/..\",\"error\":{\".tag\":\"reset\"}}".utf8))
            }
            let entries = log.filter { $0.0 >= t && under(rl, $0.1) }
            let page = entries.prefix(maxPage), rest = entries.dropFirst(maxPage)
            let next = rest.first.map { "c\($0.0):\(rl)" } ?? "c\(seq + 1):\(rl)"
            return HttpResponse(status: 200, body: jsonBody([
                "entries": page.map { entry($0.1) }, "cursor": next, "has_more": !rest.isEmpty]))
        case "\(Self.content)/files/download":
            let argHeader = (try? JSONSerialization.jsonObject(
                with: Data((req.headers["Dropbox-API-Arg"] ?? "{}").utf8))) as? [String: Any] ?? [:]
            let ref = argHeader["path"] as? String ?? ""
            let f = ref.hasPrefix("id:") ? files.values.first { $0.id == ref } : files[ref.lowercased()]
            guard let f else { return notFound() }
            if let rng = req.headers["Range"], rng.hasPrefix("bytes=") {
                let parts = rng.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                let a = Int(parts[0]) ?? 0
                let b = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : f.data.count - 1
                return HttpResponse(status: 206, body: Array(f.data[a...b]))
            }
            return HttpResponse(status: 200, body: f.data)
        default:
            return HttpResponse(status: 404, body: Array("{\"error_summary\":\"unknown endpoint\"}".utf8))
        }
    }

    private func listPage(_ keys: [String], cap: Int, rootLower: String) -> [String: Any] {
        let page = Array(keys.prefix(cap)), rest = Array(keys.dropFirst(cap))
        let cursor = rest.first.map { "l\(cap):\(rootLower):\($0)" } ?? "c\(seq + 1):\(rootLower)"
        return ["entries": page.map { entry($0) }, "cursor": cursor, "has_more": !rest.isEmpty]
    }
}
