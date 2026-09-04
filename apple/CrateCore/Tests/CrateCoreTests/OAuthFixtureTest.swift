import XCTest
@testable import CrateCore

/// OAuth + PKCE 契約測試：跑 contract/fixtures/oauth_cases/（provider.md §10）。
/// 另含 RefreshingTokenSource 的行為測試（fake transport）。
final class OAuthFixtureTest: XCTestCase {

    func testAllOAuthFixtureCasesMatchByteForByte() throws {
        let casesDir = try XCTUnwrap(findDir("contract/fixtures/oauth_cases"), "oauth_cases not found")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { name -> Bool in
                var isDir: ObjCBool = false
                let ok = FileManager.default.fileExists(
                    atPath: casesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                return ok && isDir.boolValue
            }
            .sorted()
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
            var out: [CanonicalJson.JSONValue] = []
            for e in try XCTUnwrap(script["entries"] as? [[String: Any]]) {
                let kind = e["type"] as? String ?? ""
                let entryName = e["name"] as? String ?? ""
                var pairs: [(String, CanonicalJson.JSONValue)] = []
                switch kind {
                case "authorize":
                    let config = try makeConfig(provider: e["provider"] as? String ?? "",
                                                clientId: e["clientId"] as? String ?? "",
                                                redirectUri: e["redirectUri"] as? String ?? "")
                    let verifier = e["verifier"] as? String ?? ""
                    pairs = [
                        ("challenge", .string(OAuth.codeChallenge(verifier))),
                        ("kind", .string(kind)),
                        ("name", .string(entryName)),
                        ("url", .string(OAuth.authorizationUrl(
                            config: config, verifier: verifier,
                            state: e["state"] as? String ?? ""))),
                    ]
                case "redirect":
                    let r = OAuth.parseRedirect(url: e["url"] as? String ?? "",
                                                expectedState: e["state"] as? String ?? "")
                    var resultPairs: [(String, CanonicalJson.JSONValue)] = []
                    if let code = r.code { resultPairs.append(("code", .string(code))) }
                    if let err = r.error { resultPairs.append(("error", .string(err))) }
                    resultPairs.append(("status", .string(r.status.rawValue)))
                    pairs = [("kind", .string(kind)), ("name", .string(entryName)),
                             ("result", .object(resultPairs))]
                case "form":
                    let config = OAuth.Config(authorizeUrl: "", tokenUrl: "", scope: "", extra: [],
                                              clientId: e["clientId"] as? String ?? "",
                                              redirectUri: e["redirectUri"] as? String ?? "")
                    pairs = [
                        ("exchange", .string(OAuth.exchangeForm(
                            config: config, code: e["code"] as? String ?? "",
                            verifier: e["verifier"] as? String ?? ""))),
                        ("kind", .string(kind)),
                        ("name", .string(entryName)),
                        ("refresh", .string(OAuth.refreshForm(
                            config: config, refreshToken: e["refreshToken"] as? String ?? ""))),
                    ]
                case "token_response":
                    let now = e["nowMs"] as? Int ?? 0
                    let state = TokenState.parse(e["prev"] as? String)
                        .applying(responseBody: e["body"] as? String ?? "", nowMs: now)
                    pairs = [
                        ("kind", .string(kind)), ("name", .string(entryName)),
                        ("needsRefresh", .bool(state.needsRefresh(nowMs: now))),
                        ("serialized", .string(state.serialize())),
                        ("state", stateJson(state)),
                        ("usable", .bool(state.isUsable(nowMs: now))),
                    ]
                case "expiry":
                    let now = e["nowMs"] as? Int ?? 0
                    let state = TokenState.parse(e["state"] as? String)
                    pairs = [
                        ("kind", .string(kind)), ("name", .string(entryName)),
                        ("needsRefresh", .bool(state.needsRefresh(nowMs: now))),
                        ("usable", .bool(state.isUsable(nowMs: now))),
                    ]
                case "error":
                    pairs = [
                        ("class", .string(OAuth.classifyTokenError(
                            status: e["status"] as? Int ?? 0,
                            body: e["body"] as? String ?? "").rawValue)),
                        ("kind", .string(kind)), ("name", .string(entryName)),
                    ]
                default:
                    XCTFail("unknown entry type [\(kind)]")
                }
                out.append(.object(pairs))
            }
            let actual = CanonicalJson.render(.array(out))
            if expected != actual {
                failures.append("case [\(name)]\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(names.count) oauth cases drifted:\n\n" +
                failures.joined(separator: "\n\n========\n\n"))
        }
    }

    func testGeneratedVerifierIsValidAndDistinct() {
        let a = OAuth.makeCodeVerifier()
        let b = OAuth.makeCodeVerifier()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(a.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(OAuth.makeCodeVerifier(length: 10).count, 43, "下限 43")
        XCTAssertEqual(OAuth.makeCodeVerifier(length: 999).count, 128, "上限 128")
        XCTAssertEqual(OAuth.makeState().count, 43)
    }

    func testRefreshingTokenSource() throws {
        let config = OAuth.Config.gdrive(clientId: "cid", redirectUri: "at.least.crate.ios:/oauth2redirect")
        let fake = FakeTokenServer()
        var persisted: [TokenState] = []
        var sleeps: [Int] = []
        var clock = 1_700_000_000_000
        let source = RefreshingTokenSource(
            config: config, transport: fake,
            state: TokenState(accessToken: "at-1", refreshToken: "rt-1",
                              expiresAtMs: clock + 3_600_000),
            now: { clock }, sleep: { sleeps.append($0) }, persist: { persisted.append($0) })

        XCTAssertEqual(try source.token(), "at-1", "未過期 → 直接用")
        XCTAssertEqual(fake.requests.count, 0, "未過期不打網路")

        clock += 3_600_000 // 過期
        fake.responses = [(200, #"{"access_token":"at-2","expires_in":3599}"#)]
        XCTAssertEqual(try source.token(), "at-2")
        XCTAssertEqual(source.current.refreshToken, "rt-1", "回應無 refresh_token → 沿用")
        XCTAssertEqual(persisted.count, 1)
        let body = String(decoding: fake.requests[0].body, as: UTF8.self)
        XCTAssertEqual(body, "client_id=cid&grant_type=refresh_token&refresh_token=rt-1")
        XCTAssertEqual(fake.requests[0].headers["Content-Type"], "application/x-www-form-urlencoded")

        // 暫時性失敗 → 退避後成功
        clock += 3_600_000
        fake.responses = [(503, ""), (429, ""), (200, #"{"access_token":"at-3","expires_in":3599}"#)]
        XCTAssertEqual(try source.token(), "at-3")
        XCTAssertEqual(sleeps, [1000, 2000], "§2.1 退避序列")

        // invalid_grant → auth（需重新授權），不重試
        clock += 3_600_000
        fake.responses = [(400, #"{"error":"invalid_grant"}"#)]
        XCTAssertThrowsError(try source.token()) { XCTAssertEqual($0 as? ProviderError, .auth) }

        // 無 refresh token → 直接 auth
        let empty = RefreshingTokenSource(config: config, transport: fake, state: .empty,
                                          now: { clock }, sleep: { _ in })
        XCTAssertThrowsError(try empty.token()) { XCTAssertEqual($0 as? ProviderError, .auth) }
    }

    func testExchangeFlow() throws {
        let config = OAuth.Config.dropbox(clientId: "cid", redirectUri: "http://127.0.0.1:7777/callback")
        let fake = FakeTokenServer()
        fake.responses = [(200, #"{"access_token":"at","refresh_token":"rt","expires_in":14400}"#)]
        let source = RefreshingTokenSource(config: config, transport: fake, state: .empty,
                                           now: { 1_700_000_000_000 }, sleep: { _ in })
        let state = try source.exchange(code: "the-code", verifier: "the-verifier")
        XCTAssertEqual(state.accessToken, "at")
        XCTAssertEqual(state.refreshToken, "rt")
        XCTAssertEqual(state.expiresAtMs, 1_700_000_000_000 + 14_400_000)
        XCTAssertTrue(state.isUsable(nowMs: 1_700_000_000_000))
        XCTAssertEqual(String(decoding: fake.requests[0].body, as: UTF8.self),
                       "client_id=cid&code=the-code&code_verifier=the-verifier"
                       + "&grant_type=authorization_code"
                       + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A7777%2Fcallback")
    }

    private func makeConfig(provider: String, clientId: String, redirectUri: String) throws
        -> OAuth.Config {
        switch provider {
        case "gdrive": return .gdrive(clientId: clientId, redirectUri: redirectUri)
        case "dropbox": return .dropbox(clientId: clientId, redirectUri: redirectUri)
        default:
            XCTFail("unknown provider \(provider)")
            throw NSError(domain: "test", code: 1)
        }
    }

    private func stateJson(_ s: TokenState) -> CanonicalJson.JSONValue {
        .object([
            ("accessToken", .string(s.accessToken)),
            ("expiresAtMs", .int(s.expiresAtMs)),
            ("refreshToken", .string(s.refreshToken)),
            ("scope", .string(s.scope)),
        ])
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

/// 腳本化 token 端點（空佇列 = 200 空 body）。
final class FakeTokenServer: HttpTransport {
    var responses: [(Int, String)] = []
    var requests: [HttpRequest] = []

    func send(_ req: HttpRequest) throws -> HttpResponse {
        requests.append(req)
        guard !responses.isEmpty else { return HttpResponse(status: 200, body: Array("{}".utf8)) }
        let (status, body) = responses.removeFirst()
        return HttpResponse(status: status, body: Array(body.utf8))
    }
}
