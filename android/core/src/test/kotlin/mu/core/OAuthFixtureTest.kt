package mu.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * OAuth + PKCE 契約測試：跑 contract/fixtures/oauth_cases/（provider.md §10）。
 * 另含 RefreshingTokenSource 的行為測試（fake transport）。
 */
class OAuthFixtureTest {

    @Test
    fun `all oauth fixture cases match expected json byte for byte`() {
        val casesDir = findDir("contract/fixtures/oauth_cases") ?: fail("oauth_cases not found")
        val names = casesDir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted()
            ?: fail("cannot list $casesDir")
        assertTrue(names.size >= 6, "expected >=6 oauth cases, got ${names.size}")

        val failures = ArrayList<String>()
        for (name in names) {
            val caseDir = File(casesDir, name)
            val expected = File(caseDir, "expected.json").readBytes()
            val script = Json.parseToJsonElement(File(caseDir, "script.json").readText()).jsonObject
            val out = ArrayList<Map<String, Any?>>()
            for (el in script["entries"]!!.jsonArray) {
                val e = el.jsonObject
                fun str(k: String) = e[k]?.jsonPrimitive?.contentOrNull ?: ""
                val kind = str("type")
                val entryName = str("name")
                val row = LinkedHashMap<String, Any?>()
                when (kind) {
                    "authorize" -> {
                        val config = config(str("provider"), str("clientId"), str("redirectUri"))
                        row["challenge"] = OAuth.codeChallenge(str("verifier"))
                        row["kind"] = kind
                        row["name"] = entryName
                        row["url"] = OAuth.authorizationUrl(config, str("verifier"), str("state"))
                    }
                    "redirect" -> {
                        val r = OAuth.parseRedirect(str("url"), str("state"))
                        val result = LinkedHashMap<String, Any?>()
                        r.code?.let { result["code"] = it }
                        r.error?.let { result["error"] = it }
                        result["status"] = r.status.key
                        row["kind"] = kind
                        row["name"] = entryName
                        row["result"] = result
                    }
                    "form" -> {
                        val config = OAuth.Config("", "", "", emptyList(), str("clientId"), str("redirectUri"))
                        row["exchange"] = OAuth.exchangeForm(config, str("code"), str("verifier"))
                        row["kind"] = kind
                        row["name"] = entryName
                        row["refresh"] = OAuth.refreshForm(config, str("refreshToken"))
                    }
                    "token_response" -> {
                        val now = e["nowMs"]!!.jsonPrimitive.long
                        val state = TokenState.parse(e["prev"]?.jsonPrimitive?.contentOrNull)
                            .applying(str("body"), now)
                        row["kind"] = kind
                        row["name"] = entryName
                        row["needsRefresh"] = state.needsRefresh(now)
                        row["serialized"] = state.serialize()
                        row["state"] = stateMap(state)
                        row["usable"] = state.isUsable(now)
                    }
                    "expiry" -> {
                        val now = e["nowMs"]!!.jsonPrimitive.long
                        val state = TokenState.parse(str("state"))
                        row["kind"] = kind
                        row["name"] = entryName
                        row["needsRefresh"] = state.needsRefresh(now)
                        row["usable"] = state.isUsable(now)
                    }
                    "error" -> {
                        row["class"] = OAuth.classifyTokenError(e["status"]!!.jsonPrimitive.int, str("body")).key
                        row["kind"] = kind
                        row["name"] = entryName
                    }
                    else -> fail("unknown entry type [$kind]")
                }
                out.add(row)
            }
            val actual = CanonicalJson.render(out).toByteArray(Charsets.UTF_8)
            if (!expected.contentEquals(actual)) {
                failures.add("case [$name]\n--- expected ---\n${expected.decodeToString()}\n" +
                    "--- actual ---\n${actual.decodeToString()}")
            }
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size}/${names.size} oauth cases drifted:\n\n" +
                failures.joinToString("\n\n========\n\n"))
        }
    }

    @Test
    fun `generated verifier is valid and distinct`() {
        val a = OAuth.makeCodeVerifier()
        assertEquals(64, a.length)
        assertNotEquals(a, OAuth.makeCodeVerifier())
        val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".toSet()
        assertTrue(a.all { it in allowed })
        assertEquals(43, OAuth.makeCodeVerifier(10).length)
        assertEquals(128, OAuth.makeCodeVerifier(999).length)
        assertEquals(43, OAuth.makeState().length)
    }

    @Test
    fun `refreshing token source`() {
        val config = OAuth.Config.gdrive("cid", "music.mu.android:/oauth2redirect")
        val fake = FakeTokenServer()
        val persisted = ArrayList<TokenState>()
        val sleeps = ArrayList<Long>()
        var clock = 1_700_000_000_000L
        val source = RefreshingTokenSource(
            config, fake,
            TokenState("at-1", "rt-1", clock + 3_600_000),
            now = { clock }, sleep = { sleeps.add(it) }, persist = { persisted.add(it) },
        )

        assertEquals("at-1", source.token())
        assertEquals(0, fake.requests.size, "未過期不打網路")

        clock += 3_600_000
        fake.responses.add(200 to """{"access_token":"at-2","expires_in":3599}""")
        assertEquals("at-2", source.token())
        assertEquals("rt-1", source.current.refreshToken, "回應無 refresh_token → 沿用")
        assertEquals(1, persisted.size)
        assertEquals(
            "client_id=cid&grant_type=refresh_token&refresh_token=rt-1",
            fake.requests[0].body.toString(Charsets.UTF_8),
        )

        clock += 3_600_000
        fake.responses.addAll(listOf(
            503 to "", 429 to "", 200 to """{"access_token":"at-3","expires_in":3599}""",
        ))
        assertEquals("at-3", source.token())
        assertEquals(listOf(1000L, 2000L), sleeps, "§2.1 退避序列")

        clock += 3_600_000
        fake.responses.add(400 to """{"error":"invalid_grant"}""")
        assertFailsWith<ProviderException.Auth> { source.token() }

        val empty = RefreshingTokenSource(config, fake, TokenState.EMPTY, now = { clock }, sleep = {})
        assertFailsWith<ProviderException.Auth> { empty.token() }
    }

    @Test
    fun `exchange flow`() {
        val config = OAuth.Config.dropbox("cid", "http://127.0.0.1:7777/callback")
        val fake = FakeTokenServer()
        fake.responses.add(200 to """{"access_token":"at","refresh_token":"rt","expires_in":14400}""")
        val source = RefreshingTokenSource(config, fake, TokenState.EMPTY,
            now = { 1_700_000_000_000L }, sleep = {})
        val state = source.exchange("the-code", "the-verifier")
        assertEquals("at", state.accessToken)
        assertEquals("rt", state.refreshToken)
        assertEquals(1_700_000_000_000L + 14_400_000, state.expiresAtMs)
        assertEquals(
            "client_id=cid&code=the-code&code_verifier=the-verifier&grant_type=authorization_code" +
                "&redirect_uri=http%3A%2F%2F127.0.0.1%3A7777%2Fcallback",
            fake.requests[0].body.toString(Charsets.UTF_8),
        )
    }

    private fun config(provider: String, clientId: String, redirectUri: String) = when (provider) {
        "gdrive" -> OAuth.Config.gdrive(clientId, redirectUri)
        "dropbox" -> OAuth.Config.dropbox(clientId, redirectUri)
        else -> fail("unknown provider $provider")
    }

    private fun stateMap(s: TokenState) = linkedMapOf<String, Any?>(
        "accessToken" to s.accessToken,
        "expiresAtMs" to s.expiresAtMs,
        "refreshToken" to s.refreshToken,
        "scope" to s.scope,
    )

    private fun findDir(rel: String): File? {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val c = File(dir, rel)
            if (c.isDirectory) return c
            dir = dir.parentFile
        }
        return null
    }
}

/** 腳本化 token 端點（空佇列 = 200 `{}`）。 */
class FakeTokenServer : HttpTransport {
    val responses = ArrayDeque<Pair<Int, String>>()
    val requests = ArrayList<HttpRequest>()

    override fun send(req: HttpRequest): HttpResponse {
        requests.add(req)
        val (status, body) = responses.removeFirstOrNull() ?: (200 to "{}")
        return HttpResponse(status, body.toByteArray(Charsets.UTF_8))
    }
}
