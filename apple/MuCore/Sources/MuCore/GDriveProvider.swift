import Foundation

// MARK: - 注入面（HTTP / token）

public struct HttpRequest: Equatable {
    public let method: String
    public let url: String
    public let headers: [String: String]

    public init(method: String, url: String, headers: [String: String]) {
        self.method = method; self.url = url; self.headers = headers
    }
}

public struct HttpResponse {
    public let status: Int
    public let body: [UInt8]

    public init(status: Int, body: [UInt8]) {
        self.status = status; self.body = body
    }
}

/// 傳輸層失敗（連不上、逾時）→ provider 視為 transient。
public struct TransportError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// 同步 HTTP（provider 在自有背景 queue 上執行）。契約測試接 in-memory fake；正式接 URLSession。
public protocol HttpTransport {
    func send(_ req: HttpRequest) throws -> HttpResponse
}

/// access token 來源。OAuth 流程（ASWebAuthenticationSession + 鑰匙串）屬 App 層，依 D11 隨 client ID 進場。
public protocol TokenSource {
    func token() throws -> String
    /// 401 後重授權；回新 token。失敗拋錯 → provider 以 `.auth` 傳播。
    func refresh() throws -> String
}

// MARK: - GDriveProvider（provider.md §8）

/// Google Drive provider：全 Drive 節點表 + changes 增量 → 引擎 snapshot（path → md5）。
/// 非 thread-safe：由 SyncRunner 的序列 queue 獨占（同 SyncEngine）。
public final class GDriveProvider: SyncProvider {

    public static let base = "https://www.googleapis.com/drive/v3"
    static let folderMime = "application/vnd.google-apps.folder"
    static let pageSize = 1000
    static let fileFields = "id,name,mimeType,parents,size,md5Checksum,modifiedTime"
    static let listFields = "nextPageToken,files(\(fileFields))"
    static let changeFields =
        "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(fileFields),trashed))"

    struct Node: Equatable {
        var name: String
        var mimeType: String
        var parent: String?
        var trashed: Bool
        var size: Int?
        var md5: String?
        var modifiedAt: Int
    }

    public let rootId: String
    private let transport: any HttpTransport
    private let tokenSource: any TokenSource
    private let sleep: (Int) -> Void

    private var nodes: [String: Node] = [:]
    private var cursor: String?
    private var pathToId: [String: String] = [:]

    // 每輪統計（fixtures 觀測；App 層可顯示）
    public private(set) var reauths = 0
    public private(set) var sleeps: [Int] = []
    public private(set) var reset = false

    /// - sleep: 退避注入（測試收集；預設 Thread.sleep）。
    public init(rootId: String, transport: any HttpTransport, tokenSource: any TokenSource,
                sleep: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000) }) {
        self.rootId = rootId
        self.transport = transport
        self.tokenSource = tokenSource
        self.sleep = sleep
    }

    /// 歸零本輪統計（每次 sync 前由 caller 呼叫；引擎不知道 provider 統計）。
    public func beginRound() {
        reauths = 0; sleeps = []; reset = false
    }

    // MARK: 狀態匯出（App 層存 sync_state['cursor:gdrive:<rootId>']）

    public func exportState() -> String? {
        guard let cursor else { return nil }
        let arr: [[String: Any]] = nodes.keys.sorted(by: codePointCompare).map { id in
            let n = nodes[id]!
            var d: [String: Any] = ["id": id, "name": n.name, "mimeType": n.mimeType,
                                    "trashed": n.trashed, "modifiedAt": n.modifiedAt]
            if let p = n.parent { d["parent"] = p }
            if let s = n.size { d["size"] = s }
            if let m = n.md5 { d["md5"] = m }
            return d
        }
        let obj: [String: Any] = ["cursor": cursor, "nodes": arr]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 還原失敗（格式不對）→ 視為無 cursor，下輪全量。
    public func restoreState(_ s: String?) {
        nodes = [:]; cursor = nil; pathToId = [:]
        guard let s, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = obj["cursor"] as? String,
              let arr = obj["nodes"] as? [[String: Any]] else { return }
        for d in arr {
            guard let id = d["id"] as? String, let name = d["name"] as? String,
                  let mime = d["mimeType"] as? String else { continue }
            nodes[id] = Node(name: name, mimeType: mime, parent: d["parent"] as? String,
                             trashed: d["trashed"] as? Bool ?? false, size: d["size"] as? Int,
                             md5: d["md5"] as? String, modifiedAt: d["modifiedAt"] as? Int ?? 0)
        }
        cursor = c
    }

    // MARK: SyncProvider

    public func snapshot() throws -> [String: String] {
        if cursor == nil {
            try full()
        } else {
            do {
                try delta()
            } catch ProviderError.notFound {
                try resetAndFull()
            } catch ProviderError.http(400) {
                try resetAndFull()
            }
        }
        return paths()
    }

    /// ByteSource：size 取自節點 metadata；read = Range 請求（206；200 整檔則本地裁切）。
    public func open(_ path: String) throws -> (any ByteSource)? {
        guard let id = pathToId[path] else { return nil }
        return DriveSource(provider: self, fileId: id, size: nodes[id]?.size ?? 0)
    }

    struct DriveSource: ByteSource {
        let provider: GDriveProvider
        let fileId: String
        let size: Int

        func read(offset: Int, length: Int) throws -> [UInt8] {
            guard length > 0 else { return [] }
            let (status, body) = try provider.getStatus(
                "\(GDriveProvider.base)/files/\(fileId)?alt=media",
                extra: ["Range": "bytes=\(offset)-\(offset + length - 1)"])
            if status == 206 { return body }
            guard offset < body.count else { return [] }
            return Array(body[offset..<min(body.count, offset + length)])
        }
    }

    /// 播放/釘選用：目前索引裡 path 對應的 file id（無 → nil）。
    public func fileId(for path: String) -> String? { pathToId[path] }

    /// 串流/下載請求（App 層接 AVURLAsset headers / Media3 DataSource）。
    public func mediaRequest(fileId: String, range: (Int, Int?)? = nil) throws -> HttpRequest {
        var headers = ["Authorization": "Bearer \(try tokenSource.token())"]
        if let (a, b) = range {
            headers["Range"] = "bytes=\(a)-\(b.map(String.init) ?? "")"
        }
        return HttpRequest(method: "GET", url: "\(Self.base)/files/\(fileId)?alt=media", headers: headers)
    }

    // MARK: 節點表

    private func resetAndFull() throws {
        reset = true
        cursor = nil
        try full()
    }

    private func full() throws {
        let startObj = try json(get("\(Self.base)/changes/startPageToken"))
        guard let start = startObj["startPageToken"] as? String else { throw ProviderError.http(0) }
        nodes = [:]
        var page: String? = nil
        while true {
            var url = "\(Self.base)/files?q=trashed%3Dfalse&pageSize=\(Self.pageSize)&fields=\(Self.listFields)"
            if let page { url += "&pageToken=\(page)" }
            let r = try json(get(url))
            for f in r["files"] as? [[String: Any]] ?? [] {
                if let id = f["id"] as? String, let n = Self.node(f) { nodes[id] = n }
            }
            page = r["nextPageToken"] as? String
            if page == nil { break }
        }
        cursor = start
    }

    private func delta() throws {
        var page = cursor!
        while true {
            let url = "\(Self.base)/changes?pageToken=\(page)&pageSize=\(Self.pageSize)"
                + "&includeRemoved=true&fields=\(Self.changeFields)"
            let r = try json(get(url))
            for c in r["changes"] as? [[String: Any]] ?? [] {
                guard let id = c["fileId"] as? String else { continue }
                let file = c["file"] as? [String: Any]
                if c["removed"] as? Bool == true || file?["trashed"] as? Bool == true {
                    nodes.removeValue(forKey: id)
                } else if let file, let n = Self.node(file) {
                    nodes[id] = n
                }
            }
            if let next = r["nextPageToken"] as? String {
                page = next
                continue
            }
            guard let newStart = r["newStartPageToken"] as? String else { throw ProviderError.http(0) }
            cursor = newStart
            return
        }
    }

    static func node(_ f: [String: Any]) -> Node? {
        guard let name = f["name"] as? String, let mime = f["mimeType"] as? String,
              let mt = f["modifiedTime"] as? String else { return nil }
        let parents = f["parents"] as? [String] ?? []
        return Node(name: name, mimeType: mime, parent: parents.first,
                    trashed: f["trashed"] as? Bool ?? false,
                    size: (f["size"] as? String).flatMap { Int($0) },
                    md5: f["md5Checksum"] as? String,
                    modifiedAt: parseIsoMs(mt))
    }

    /// 節點表 → path → rev（§8.2/§8.3）。
    private func paths() -> [String: String] {
        var snap: [String: String] = [:]
        pathToId = [:]
        for id in nodes.keys.sorted(by: codePointCompare) {
            let n = nodes[id]!
            if n.mimeType.hasPrefix("application/vnd.google-apps.") { continue }
            var names: [String] = []
            var cur = n
            var seen: Set<String> = [id]
            var ok = false
            while true {
                if cur.trashed || cur.name.contains("/") { break }
                names.append(cur.name)
                guard let pid = cur.parent else { break }
                if pid == rootId { ok = true; break }
                guard let next = nodes[pid], !seen.contains(pid) else { break }
                seen.insert(pid)
                cur = next
            }
            guard ok else { continue }
            let path = names.reversed().joined(separator: "/")
            if snap[path] != nil { continue } // 同 path 碰撞：id 字典序最小者勝
            snap[path] = n.md5 ?? "\(n.size ?? 0):\(n.modifiedAt)"
            pathToId[path] = id
        }
        return snap
    }

    // MARK: HTTP + §2.1 重試

    private func json(_ body: [UInt8]) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else {
            throw ProviderError.http(0)
        }
        return obj
    }

    private func get(_ url: String) throws -> [UInt8] {
        try getStatus(url, extra: [:]).1
    }

    private func getStatus(_ url: String, extra: [String: String]) throws -> (Int, [UInt8]) {
        var transient = 0
        var reauthUsed = false
        var token = try tokenSource.token()
        while true {
            var headers = extra
            headers["Authorization"] = "Bearer \(token)"
            let req = HttpRequest(method: "GET", url: url, headers: headers)
            let status: Int
            let body: [UInt8]
            do {
                let r = try transport.send(req)
                status = r.status; body = r.body
            } catch {
                status = 0; body = []
            }
            if (200..<300).contains(status) { return (status, body) }
            if status == 401 {
                if reauthUsed { throw ProviderError.auth }
                reauthUsed = true
                reauths += 1
                token = try tokenSource.refresh()
                continue
            }
            let isTransient = status == 0 || status == 429 || status >= 500
                || (status == 403 && String(decoding: body, as: UTF8.self).contains("ateLimitExceeded"))
            if isTransient {
                if transient >= RetryPolicy.maxTransientRetries { throw ProviderError.transient }
                let ms = RetryPolicy.transientDelaysMs[transient]
                sleep(ms)
                sleeps.append(ms)
                transient += 1
                continue
            }
            if status == 404 { throw ProviderError.notFound }
            throw ProviderError.http(status)
        }
    }

    // MARK: 工具

    /// 資料夾 URL 或 id → id（`/folders/<id>`、`?id=`；純 id 原樣）。空 → nil。
    public static func resolveRoot(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { return s }
        guard let comps = URLComponents(string: s) else { return nil }
        if let id = comps.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty {
            return id
        }
        let segs = comps.path.split(separator: "/").map(String.init)
        for (i, seg) in segs.enumerated() where seg == "folders" && i + 1 < segs.count {
            return segs[i + 1]
        }
        return nil
    }

    /// RFC3339（Drive 固定 UTC `Z`；小數秒可有可無）→ ms。解析失敗 → 0。
    static func parseIsoMs(_ s0: String) -> Int {
        var s = s0
        if s.hasSuffix("Z") { s.removeLast() }
        var frac = 0
        if let dot = s.firstIndex(of: ".") {
            let f = String(s[s.index(after: dot)...])
            frac = Int((f + "000").prefix(3)) ?? 0
            s = String(s[..<dot])
        }
        let parts = s.split(whereSeparator: { $0 == "T" || $0 == "-" || $0 == ":" }).compactMap { Int($0) }
        guard parts.count == 6 else { return 0 }
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        dc.hour = parts[3]; dc.minute = parts[4]; dc.second = parts[5]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = cal.date(from: dc) else { return 0 }
        return Int(d.timeIntervalSince1970) * 1000 + frac
    }
}

// MARK: - URLSession transport（正式環境）

/// 同步 URLSession（semaphore；只在背景 queue 使用）。
public final class URLSessionTransport: HttpTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ req: HttpRequest) throws -> HttpResponse {
        guard let url = URL(string: req.url) else { throw TransportError("bad url") }
        var r = URLRequest(url: url)
        r.httpMethod = req.method
        for (k, v) in req.headers { r.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var out: Result<HttpResponse, Error> = .failure(TransportError("no response"))
        session.dataTask(with: r) { data, resp, err in
            if let err {
                out = .failure(TransportError(err.localizedDescription))
            } else if let http = resp as? HTTPURLResponse {
                out = .success(HttpResponse(status: http.statusCode, body: [UInt8](data ?? Data())))
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try out.get()
    }
}
