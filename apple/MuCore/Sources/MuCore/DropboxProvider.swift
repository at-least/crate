import Foundation

/// Dropbox provider（provider.md §9）：root 底下檔案節點表（key = path_lower）+ list_folder/continue 增量
/// → 引擎 snapshot（path → content_hash）。與 GDriveProvider 同構；非 thread-safe（SyncRunner 序列 queue 獨占）。
public final class DropboxProvider: SyncProvider {

    public static let api = "https://api.dropboxapi.com/2"
    public static let content = "https://content.dropboxapi.com/2"
    static let limit = 2000

    struct Node {
        var display: String
        var id: String
        var size: Int
        var hash: String
        var modifiedAt: Int
    }

    struct CursorReset: Error {}

    /// 使用者輸入：`/Music`、`id:…`、或 `""`（整個 Dropbox）。
    public let root: String
    private let transport: any HttpTransport
    private let tokenSource: any TokenSource
    private let sleep: (Int) -> Void

    private var rootLower: String?
    private var rootDisplay: String?
    private var nodes: [String: Node] = [:]
    private var cursor: String?
    private var pathToId: [String: String] = [:]
    private var idToLower: [String: String] = [:]

    public private(set) var reauths = 0
    public private(set) var sleeps: [Int] = []
    public private(set) var reset = false

    public init(root: String, transport: any HttpTransport, tokenSource: any TokenSource,
                sleep: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000) }) {
        self.root = root
        self.transport = transport
        self.tokenSource = tokenSource
        self.sleep = sleep
    }

    public func beginRound() {
        reauths = 0; sleeps = []; reset = false
    }

    // MARK: 狀態匯出（App 層存 sync_state['cursor:dropbox:<root>']）

    public func exportState() -> String? {
        guard let cursor, let rootLower, let rootDisplay else { return nil }
        let arr: [[String: Any]] = nodes.keys.sorted(by: codePointCompare).map { pl in
            let n = nodes[pl]!
            return ["pl": pl, "display": n.display, "id": n.id, "size": n.size,
                    "hash": n.hash, "modifiedAt": n.modifiedAt]
        }
        let obj: [String: Any] = ["cursor": cursor, "rootLower": rootLower,
                                  "rootDisplay": rootDisplay, "nodes": arr]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func restoreState(_ s: String?) {
        nodes = [:]; cursor = nil; pathToId = [:]; idToLower = [:]; rootLower = nil; rootDisplay = nil
        guard let s, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = obj["cursor"] as? String, let rl = obj["rootLower"] as? String,
              let rd = obj["rootDisplay"] as? String,
              let arr = obj["nodes"] as? [[String: Any]] else { return }
        for d in arr {
            guard let pl = d["pl"] as? String, let display = d["display"] as? String,
                  let id = d["id"] as? String else { continue }
            nodes[pl] = Node(display: display, id: id, size: d["size"] as? Int ?? 0,
                             hash: d["hash"] as? String ?? "", modifiedAt: d["modifiedAt"] as? Int ?? 0)
        }
        cursor = c; rootLower = rl; rootDisplay = rd
    }

    // MARK: SyncProvider

    public func snapshot() throws -> [String: String] {
        if cursor == nil {
            try full()
        } else {
            do {
                try delta()
            } catch is CursorReset {
                reset = true
                cursor = nil
                try full()
            }
        }
        return paths()
    }

    public func open(_ path: String) throws -> (any ByteSource)? {
        guard let id = pathToId[path], let pl = idToLower[id] else { return nil }
        return DropboxSource(provider: self, fileId: id, size: nodes[pl]?.size ?? 0)
    }

    struct DropboxSource: ByteSource {
        let provider: DropboxProvider
        let fileId: String
        let size: Int

        func read(offset: Int, length: Int) throws -> [UInt8] {
            guard length > 0 else { return [] }
            let arg = "{\"path\":\"\(fileId)\"}"
            let (status, body) = try provider.call(
                "\(DropboxProvider.content)/files/download", body: [],
                headers: ["Dropbox-API-Arg": arg, "Range": "bytes=\(offset)-\(offset + length - 1)"])
            if status == 206 { return body }
            guard offset < body.count else { return [] }
            return Array(body[offset..<min(body.count, offset + length)])
        }
    }

    public func fileId(for path: String) -> String? { pathToId[path] }

    /// 串流/下載請求（App 層接 AVURLAsset headers / Media3 DataSource）。
    public func mediaRequest(fileId: String, range: (Int, Int?)? = nil) throws -> HttpRequest {
        var headers = ["Authorization": "Bearer \(try tokenSource.token())",
                       "Dropbox-API-Arg": "{\"path\":\"\(fileId)\"}"]
        if let (a, b) = range { headers["Range"] = "bytes=\(a)-\(b.map(String.init) ?? "")" }
        return HttpRequest(method: "POST", url: "\(Self.content)/files/download", headers: headers)
    }

    // MARK: 節點表

    private func listArg() -> [String: Any] {
        ["path": rootLower ?? "", "recursive": true, "include_deleted": false, "limit": Self.limit]
    }

    private func resolveRoot() throws {
        if rootLower != nil { return }
        if root.isEmpty { rootLower = ""; rootDisplay = ""; return }
        let m = try rpc("files/get_metadata", ["path": root])
        guard let pl = m["path_lower"] as? String, let pd = m["path_display"] as? String else {
            throw ProviderError.http(0)
        }
        rootLower = pl; rootDisplay = pd
    }

    private func apply(_ entries: [[String: Any]]) {
        for e in entries {
            guard let tag = e[".tag"] as? String, let pl = e["path_lower"] as? String else { continue }
            if tag == "file" {
                guard let display = e["path_display"] as? String, let id = e["id"] as? String,
                      let mt = e["server_modified"] as? String else { continue }
                let hash = (e["content_hash"] as? String) ?? (e["rev"] as? String) ?? ""
                nodes[pl] = Node(display: display, id: id,
                                 size: (e["size"] as? NSNumber)?.intValue ?? 0,
                                 hash: hash, modifiedAt: GDriveProvider.parseIsoMs(mt))
            } else if tag == "deleted" {
                nodes.removeValue(forKey: pl)
                for k in nodes.keys where k.hasPrefix(pl + "/") { nodes.removeValue(forKey: k) }
            }
        }
    }

    private func full() throws {
        try resolveRoot()
        guard let start = try rpc("files/list_folder/get_latest_cursor", listArg())["cursor"] as? String else {
            throw ProviderError.http(0)
        }
        nodes = [:]
        var r = try rpc("files/list_folder", listArg())
        apply(r["entries"] as? [[String: Any]] ?? [])
        while r["has_more"] as? Bool == true {
            r = try rpc("files/list_folder/continue", ["cursor": r["cursor"] as? String ?? ""])
            apply(r["entries"] as? [[String: Any]] ?? [])
        }
        cursor = start
    }

    private func delta() throws {
        var c = cursor!
        while true {
            let r = try rpc("files/list_folder/continue", ["cursor": c])
            apply(r["entries"] as? [[String: Any]] ?? [])
            guard let next = r["cursor"] as? String else { throw ProviderError.http(0) }
            c = next
            if r["has_more"] as? Bool != true { break }
        }
        cursor = c
    }

    private func paths() -> [String: String] {
        var snap: [String: String] = [:]
        pathToId = [:]; idToLower = [:]
        let prefix = (rootDisplay ?? "").isEmpty ? "/" : rootDisplay! + "/"
        for pl in nodes.keys.sorted(by: codePointCompare) {
            let n = nodes[pl]!
            guard n.display.hasPrefix(prefix) else { continue }
            let path = String(n.display.dropFirst(prefix.count))
            snap[path] = n.hash.isEmpty ? "\(n.size):\(n.modifiedAt)" : n.hash
            pathToId[path] = n.id
            idToLower[n.id] = pl
        }
        return snap
    }

    // MARK: HTTP + §2.1 重試

    private func rpc(_ endpoint: String, _ arg: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: arg, options: [.sortedKeys])
        let (_, out) = try call("\(Self.api)/\(endpoint)", body: [UInt8](body),
                                headers: ["Content-Type": "application/json"])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out)) as? [String: Any] else {
            throw ProviderError.http(0)
        }
        return obj
    }

    fileprivate func call(_ url: String, body: [UInt8], headers extra: [String: String]) throws -> (Int, [UInt8]) {
        var transient = 0
        var reauthUsed = false
        var token = try tokenSource.token()
        while true {
            var headers = extra
            headers["Authorization"] = "Bearer \(token)"
            let req = HttpRequest(method: "POST", url: url, headers: headers, body: body)
            let status: Int
            let rbody: [UInt8]
            do {
                let r = try transport.send(req)
                status = r.status; rbody = r.body
            } catch {
                status = 0; rbody = []
            }
            if (200..<300).contains(status) { return (status, rbody) }
            if status == 401 {
                if reauthUsed { throw ProviderError.auth }
                reauthUsed = true
                reauths += 1
                token = try tokenSource.refresh()
                continue
            }
            if status == 0 || status == 429 || status >= 500 {
                if transient >= RetryPolicy.maxTransientRetries { throw ProviderError.transient }
                let ms = RetryPolicy.transientDelaysMs[transient]
                sleep(ms)
                sleeps.append(ms)
                transient += 1
                continue
            }
            if status == 409 {
                let text = String(decoding: rbody, as: UTF8.self)
                if text.contains("not_found") { throw ProviderError.notFound }
                if text.contains("reset") { throw CursorReset() }
            }
            throw ProviderError.http(status)
        }
    }
}
