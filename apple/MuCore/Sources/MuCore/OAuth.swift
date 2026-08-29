import CryptoKit
import Foundation

/// OAuth 2.0 + PKCE（provider.md §10）。只有「開瀏覽器同意」屬平台，其餘全在核心層。
public enum OAuth {

    public struct Config: Equatable {
        public let authorizeUrl: String
        public let tokenUrl: String
        public let scope: String
        /// 該後端的額外授權參數（附在固定參數之後，順序固定）。
        public let extra: [(String, String)]
        public let clientId: String
        public let redirectUri: String

        public init(authorizeUrl: String, tokenUrl: String, scope: String,
                    extra: [(String, String)], clientId: String, redirectUri: String) {
            self.authorizeUrl = authorizeUrl; self.tokenUrl = tokenUrl; self.scope = scope
            self.extra = extra; self.clientId = clientId; self.redirectUri = redirectUri
        }

        public static func == (a: Config, b: Config) -> Bool {
            a.authorizeUrl == b.authorizeUrl && a.tokenUrl == b.tokenUrl && a.scope == b.scope
                && a.clientId == b.clientId && a.redirectUri == b.redirectUri
                && a.extra.map(\.0) == b.extra.map(\.0) && a.extra.map(\.1) == b.extra.map(\.1)
        }

        public static func gdrive(clientId: String, redirectUri: String) -> Config {
            Config(authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
                   tokenUrl: "https://oauth2.googleapis.com/token",
                   scope: "https://www.googleapis.com/auth/drive.readonly",
                   extra: [("access_type", "offline"), ("prompt", "consent")],
                   clientId: clientId, redirectUri: redirectUri)
        }

        public static func dropbox(clientId: String, redirectUri: String) -> Config {
            Config(authorizeUrl: "https://www.dropbox.com/oauth2/authorize",
                   tokenUrl: "https://api.dropboxapi.com/oauth2/token",
                   scope: "files.metadata.read files.content.read",
                   extra: [("token_access_type", "offline")],
                   clientId: clientId, redirectUri: redirectUri)
        }
    }

    public enum RedirectStatus: String {
        case ok, denied, stateMismatch = "state_mismatch", invalid
    }

    public struct RedirectResult: Equatable {
        public let status: RedirectStatus
        public let code: String?
        public let error: String?
    }

    public enum TokenErrorClass: String {
        case ok, auth, transient, http
    }

    static let unreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

    /// §10.2 百分比編碼：未保留字元原樣，其餘 %XX（大寫）。
    public static func pct(_ s: String) -> String {
        var out = ""
        for b in Array(s.utf8) {
            if unreserved.contains(b) {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// base64url(SHA-256(verifier))，去尾端 `=`。
    public static func codeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 密碼學亂數 verifier（43–128 字元，未保留字元集）。
    public static func makeCodeVerifier(length: Int = 64) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var out = ""
        for _ in 0..<max(43, min(128, length)) {
            var byte: UInt8 = 0
            _ = withUnsafeMutableBytes(of: &byte) { SecRandomCopyBytes(kSecRandomDefault, 1, $0.baseAddress!) }
            out.append(alphabet[Int(byte) % alphabet.count])
        }
        return out
    }

    public static func makeState() -> String { makeCodeVerifier(length: 43) }

    /// §10.2 授權 URL（參數順序固定）。
    public static func authorizationUrl(config: Config, verifier: String, state: String) -> String {
        let params: [(String, String)] = [
            ("client_id", config.clientId),
            ("code_challenge", codeChallenge(verifier)),
            ("code_challenge_method", "S256"),
            ("redirect_uri", config.redirectUri),
            ("response_type", "code"),
            ("scope", config.scope),
            ("state", state),
        ] + config.extra
        let query = params.map { "\(pct($0.0))=\(pct($0.1))" }.joined(separator: "&")
        return "\(config.authorizeUrl)?\(query)"
    }

    /// §10.3 回呼解析。
    public static func parseRedirect(url: String, expectedState: String) -> RedirectResult {
        guard let qIndex = url.firstIndex(of: "?") else {
            return RedirectResult(status: .invalid, code: nil, error: nil)
        }
        var query = String(url[url.index(after: qIndex)...])
        if let hash = query.firstIndex(of: "#") { query = String(query[..<hash]) }
        var params: [String: String] = [:]
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = unpct(String(kv[0]))
            let value = kv.count > 1 ? unpct(String(kv[1])) : ""
            if params[key] == nil { params[key] = value }
        }
        if let err = params["error"] {
            return params["state"] ?? "" == expectedState
                ? RedirectResult(status: .denied, code: nil, error: err)
                : RedirectResult(status: .stateMismatch, code: nil, error: nil)
        }
        guard let code = params["code"] else {
            return RedirectResult(status: .invalid, code: nil, error: nil)
        }
        guard params["state"] ?? "" == expectedState else {
            return RedirectResult(status: .stateMismatch, code: nil, error: nil)
        }
        return RedirectResult(status: .ok, code: code, error: nil)
    }

    public static func unpct(_ s: String) -> String {
        var out: [UInt8] = []
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func form(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(pct($0.0))=\(pct($0.1))" }.joined(separator: "&")
    }

    /// §10.3 授權碼交換表單（欄位序固定）。
    public static func exchangeForm(config: Config, code: String, verifier: String) -> String {
        form([("client_id", config.clientId), ("code", code), ("code_verifier", verifier),
              ("grant_type", "authorization_code"), ("redirect_uri", config.redirectUri)])
    }

    /// §10.3 更新表單（欄位序固定）。
    public static func refreshForm(config: Config, refreshToken: String) -> String {
        form([("client_id", config.clientId), ("grant_type", "refresh_token"),
              ("refresh_token", refreshToken)])
    }

    /// §10.3 token 端點錯誤分類。
    public static func classifyTokenError(status: Int, body: String) -> TokenErrorClass {
        if status == 0 || status == 429 || status >= 500 { return .transient }
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? String,
           ["invalid_grant", "invalid_client", "unauthorized_client"].contains(err) {
            return .auth
        }
        if (200..<300).contains(status) { return .ok }
        return .http
    }
}

/// token 狀態（provider.md §10.3）。存平台鑰匙串，不進 DB。
public struct TokenState: Equatable {
    public static let defaultSkewMs = 60_000

    public let accessToken: String
    public let refreshToken: String
    public let expiresAtMs: Int
    public let scope: String

    public init(accessToken: String = "", refreshToken: String = "",
                expiresAtMs: Int = 0, scope: String = "") {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAtMs = expiresAtMs; self.scope = scope
    }

    public static let empty = TokenState()

    public static func parse(_ text: String?) -> TokenState {
        guard let text, !text.isEmpty, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .empty
        }
        func str(_ k: String) -> String { (obj[k] as? String) ?? "" }
        var exp = 0
        if let n = obj["expiresAtMs"] as? NSNumber,
           CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) {
            exp = n.intValue
        }
        return TokenState(accessToken: str("accessToken"), refreshToken: str("refreshToken"),
                          expiresAtMs: exp, scope: str("scope"))
    }

    public func serialize() -> String {
        func q(_ v: String) -> String {
            var out = ""
            CanonicalJson.escapeInto(v, &out)
            return out
        }
        return "{\"accessToken\":\(q(accessToken)),\"expiresAtMs\":\(expiresAtMs),"
            + "\"refreshToken\":\(q(refreshToken)),\"scope\":\(q(scope))}"
    }

    public func needsRefresh(nowMs: Int, skewMs: Int = TokenState.defaultSkewMs) -> Bool {
        nowMs + skewMs >= expiresAtMs
    }

    public func isUsable(nowMs: Int, skewMs: Int = TokenState.defaultSkewMs) -> Bool {
        !accessToken.isEmpty && !needsRefresh(nowMs: nowMs, skewMs: skewMs)
    }

    /// §10.3：`expires_in` 缺 → 立即過期；回應無 `refresh_token` → 沿用既有。
    public func applying(responseBody body: String, nowMs: Int) -> TokenState {
        let obj = (body.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        } as? [String: Any]) ?? [:]
        func str(_ k: String, _ fallback: String) -> String { (obj[k] as? String) ?? fallback }
        var expiresIn = 0
        if let n = obj["expires_in"] as? NSNumber,
           CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) {
            expiresIn = n.intValue
        } else if let s = obj["expires_in"] as? String, let v = Int(s), s.allSatisfy(\.isNumber) {
            expiresIn = v
        }
        return TokenState(accessToken: str("access_token", accessToken),
                          refreshToken: str("refresh_token", refreshToken),
                          expiresAtMs: nowMs + expiresIn * 1000,
                          scope: str("scope", scope))
    }
}

/// 自動更新的 `TokenSource`（provider.md §10 + §2.1）：token 過期 → 以 refresh token 換新，
/// 失敗語意：`invalid_grant` 等 → `.auth`（需使用者重新授權）；429/5xx/傳輸 → 退避重試。
/// 非 thread-safe：由 provider 的序列 queue 獨占。
public final class RefreshingTokenSource: TokenSource {

    private let config: OAuth.Config
    private let transport: any HttpTransport
    private let now: () -> Int
    private let sleep: (Int) -> Void
    private let persist: (TokenState) -> Void
    private var state: TokenState

    public init(config: OAuth.Config, transport: any HttpTransport, state: TokenState,
                now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
                sleep: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000) },
                persist: @escaping (TokenState) -> Void = { _ in }) {
        self.config = config
        self.transport = transport
        self.state = state
        self.now = now
        self.sleep = sleep
        self.persist = persist
    }

    public var current: TokenState { state }

    public func token() throws -> String {
        if state.isUsable(nowMs: now()) { return state.accessToken }
        return try refresh()
    }

    @discardableResult
    public func refresh() throws -> String {
        guard !state.refreshToken.isEmpty else { throw ProviderError.auth }
        var transient = 0
        while true {
            let req = HttpRequest(
                method: "POST", url: config.tokenUrl,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Array(OAuth.refreshForm(config: config,
                                              refreshToken: state.refreshToken).utf8))
            var status = 0
            var body: [UInt8] = []
            do {
                let r = try transport.send(req)
                status = r.status
                body = r.body
            } catch {
                status = 0
            }
            let text = String(decoding: body, as: UTF8.self)
            switch OAuth.classifyTokenError(status: status, body: text) {
            case .ok:
                state = state.applying(responseBody: text, nowMs: now())
                persist(state)
                return state.accessToken
            case .auth:
                throw ProviderError.auth
            case .transient:
                if transient >= RetryPolicy.maxTransientRetries { throw ProviderError.transient }
                sleep(RetryPolicy.transientDelaysMs[transient])
                transient += 1
            case .http:
                throw ProviderError.http(status)
            }
        }
    }

    /// 授權碼 → token（首次授權；同樣套 §2.1 重試）。
    public func exchange(code: String, verifier: String) throws -> TokenState {
        var transient = 0
        while true {
            let req = HttpRequest(
                method: "POST", url: config.tokenUrl,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Array(OAuth.exchangeForm(config: config, code: code, verifier: verifier).utf8))
            var status = 0
            var body: [UInt8] = []
            do {
                let r = try transport.send(req)
                status = r.status
                body = r.body
            } catch {
                status = 0
            }
            let text = String(decoding: body, as: UTF8.self)
            switch OAuth.classifyTokenError(status: status, body: text) {
            case .ok:
                state = state.applying(responseBody: text, nowMs: now())
                persist(state)
                return state
            case .auth:
                throw ProviderError.auth
            case .transient:
                if transient >= RetryPolicy.maxTransientRetries { throw ProviderError.transient }
                sleep(RetryPolicy.transientDelaysMs[transient])
                transient += 1
            case .http:
                throw ProviderError.http(status)
            }
        }
    }
}
