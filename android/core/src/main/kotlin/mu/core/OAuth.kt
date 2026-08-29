package mu.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** OAuth 2.0 + PKCE（provider.md §10）。只有「開瀏覽器同意」屬平台，其餘全在核心層。 */
object OAuth {

    data class Config(
        val authorizeUrl: String,
        val tokenUrl: String,
        val scope: String,
        /** 該後端的額外授權參數（附在固定參數之後，順序固定）。 */
        val extra: List<Pair<String, String>>,
        val clientId: String,
        val redirectUri: String,
    ) {
        companion object {
            fun gdrive(clientId: String, redirectUri: String) = Config(
                "https://accounts.google.com/o/oauth2/v2/auth",
                "https://oauth2.googleapis.com/token",
                "https://www.googleapis.com/auth/drive.readonly",
                listOf("access_type" to "offline", "prompt" to "consent"),
                clientId, redirectUri,
            )

            fun dropbox(clientId: String, redirectUri: String) = Config(
                "https://www.dropbox.com/oauth2/authorize",
                "https://api.dropboxapi.com/oauth2/token",
                "files.metadata.read files.content.read",
                listOf("token_access_type" to "offline"),
                clientId, redirectUri,
            )
        }
    }

    enum class RedirectStatus(val key: String) {
        OK("ok"), DENIED("denied"), STATE_MISMATCH("state_mismatch"), INVALID("invalid")
    }

    data class RedirectResult(
        val status: RedirectStatus,
        val code: String? = null,
        val error: String? = null,
    )

    enum class TokenErrorClass(val key: String) {
        OK("ok"), AUTH("auth"), TRANSIENT("transient"), HTTP("http")
    }

    private const val ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    private val UNRESERVED = ALPHABET.toSet()

    /** §10.2 百分比編碼：未保留字元原樣，其餘 %XX（大寫）。 */
    fun pct(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xFF).toChar()
            if (c in UNRESERVED) sb.append(c) else sb.append("%%%02X".format(b.toInt() and 0xFF))
        }
        return sb.toString()
    }

    /** base64url(SHA-256(verifier))，去尾端 `=`。 */
    fun codeChallenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }

    /** 密碼學亂數 verifier（43–128 字元，未保留字元集）。 */
    fun makeCodeVerifier(length: Int = 64): String {
        val rnd = SecureRandom()
        val n = length.coerceIn(43, 128)
        return buildString { repeat(n) { append(ALPHABET[rnd.nextInt(ALPHABET.length)]) } }
    }

    fun makeState(): String = makeCodeVerifier(43)

    /** §10.2 授權 URL（參數順序固定）。 */
    fun authorizationUrl(config: Config, verifier: String, state: String): String {
        val params = listOf(
            "client_id" to config.clientId,
            "code_challenge" to codeChallenge(verifier),
            "code_challenge_method" to "S256",
            "redirect_uri" to config.redirectUri,
            "response_type" to "code",
            "scope" to config.scope,
            "state" to state,
        ) + config.extra
        return config.authorizeUrl + "?" + params.joinToString("&") { "${pct(it.first)}=${pct(it.second)}" }
    }

    /** §10.3 回呼解析。 */
    fun parseRedirect(url: String, expectedState: String): RedirectResult {
        val q = url.indexOf('?')
        if (q < 0) return RedirectResult(RedirectStatus.INVALID)
        val query = url.substring(q + 1).substringBefore('#')
        val params = LinkedHashMap<String, String>()
        for (part in query.split('&')) {
            if (part.isEmpty()) continue
            val i = part.indexOf('=')
            val key = unpct(if (i < 0) part else part.substring(0, i))
            val value = if (i < 0) "" else unpct(part.substring(i + 1))
            params.putIfAbsent(key, value)
        }
        params["error"]?.let { err ->
            return if ((params["state"] ?: "") == expectedState) {
                RedirectResult(RedirectStatus.DENIED, error = err)
            } else {
                RedirectResult(RedirectStatus.STATE_MISMATCH)
            }
        }
        val code = params["code"] ?: return RedirectResult(RedirectStatus.INVALID)
        if ((params["state"] ?: "") != expectedState) return RedirectResult(RedirectStatus.STATE_MISMATCH)
        return RedirectResult(RedirectStatus.OK, code = code)
    }

    fun unpct(s: String): String {
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        val bytes = s.toByteArray(Charsets.UTF_8)
        while (i < bytes.size) {
            val c = bytes[i].toInt() and 0xFF
            if (c == '%'.code && i + 2 < bytes.size) {
                val hex = String(bytes, i + 1, 2, Charsets.US_ASCII).toIntOrNull(16)
                if (hex != null) {
                    out.write(hex)
                    i += 3
                    continue
                }
            }
            out.write(c)
            i++
        }
        return out.toString(Charsets.UTF_8)
    }

    private fun form(pairs: List<Pair<String, String>>) =
        pairs.joinToString("&") { "${pct(it.first)}=${pct(it.second)}" }

    /** §10.3 授權碼交換表單（欄位序固定）。 */
    fun exchangeForm(config: Config, code: String, verifier: String) = form(listOf(
        "client_id" to config.clientId, "code" to code, "code_verifier" to verifier,
        "grant_type" to "authorization_code", "redirect_uri" to config.redirectUri,
    ))

    /** §10.3 更新表單（欄位序固定）。 */
    fun refreshForm(config: Config, refreshToken: String) = form(listOf(
        "client_id" to config.clientId, "grant_type" to "refresh_token",
        "refresh_token" to refreshToken,
    ))

    /** §10.3 token 端點錯誤分類。 */
    fun classifyTokenError(status: Int, body: String): TokenErrorClass {
        if (status == 0 || status == 429 || status >= 500) return TokenErrorClass.TRANSIENT
        val err = try {
            ((Json.parseToJsonElement(body) as? JsonObject)?.get("error") as? JsonPrimitive)
                ?.takeIf { it.isString }?.content
        } catch (e: Exception) {
            null
        }
        if (err in setOf("invalid_grant", "invalid_client", "unauthorized_client")) {
            return TokenErrorClass.AUTH
        }
        if (status in 200..299) return TokenErrorClass.OK
        return TokenErrorClass.HTTP
    }
}

/** token 狀態（provider.md §10.3）。存平台鑰匙串，不進 DB。 */
data class TokenState(
    val accessToken: String = "",
    val refreshToken: String = "",
    val expiresAtMs: Long = 0,
    val scope: String = "",
) {
    companion object {
        const val DEFAULT_SKEW_MS = 60_000L
        val EMPTY = TokenState()

        fun parse(text: String?): TokenState {
            if (text.isNullOrEmpty()) return EMPTY
            val obj = try {
                Json.parseToJsonElement(text) as? JsonObject ?: return EMPTY
            } catch (e: Exception) {
                return EMPTY
            }
            fun str(k: String) = (obj[k] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: ""
            val exp = (obj["expiresAtMs"] as? JsonPrimitive)?.takeIf { !it.isString }
                ?.content?.toLongOrNull() ?: 0
            return TokenState(str("accessToken"), str("refreshToken"), exp, str("scope"))
        }
    }

    fun serialize(): String =
        """{"accessToken":${CanonicalJson.quoted(accessToken)},"expiresAtMs":$expiresAtMs,""" +
            """"refreshToken":${CanonicalJson.quoted(refreshToken)},"scope":${CanonicalJson.quoted(scope)}}"""

    fun needsRefresh(nowMs: Long, skewMs: Long = DEFAULT_SKEW_MS) = nowMs + skewMs >= expiresAtMs

    fun isUsable(nowMs: Long, skewMs: Long = DEFAULT_SKEW_MS) =
        accessToken.isNotEmpty() && !needsRefresh(nowMs, skewMs)

    /** §10.3：`expires_in` 缺 → 立即過期；回應無 `refresh_token` → 沿用既有。 */
    fun applying(responseBody: String, nowMs: Long): TokenState {
        val obj = try {
            Json.parseToJsonElement(responseBody) as? JsonObject
        } catch (e: Exception) {
            null
        }
        fun str(k: String, fallback: String) =
            (obj?.get(k) as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fallback
        val expiresIn = (obj?.get("expires_in") as? JsonPrimitive)?.content?.toLongOrNull() ?: 0
        return TokenState(
            str("access_token", accessToken),
            str("refresh_token", refreshToken),
            nowMs + expiresIn * 1000,
            str("scope", scope),
        )
    }
}

/**
 * 自動更新的 [TokenSource]（provider.md §10 + §2.1）：token 過期 → 以 refresh token 換新。
 * 失敗語意：`invalid_grant` 等 → [ProviderException.Auth]（需重新授權）；429/5xx/傳輸 → 退避重試。
 * 非 thread-safe：由 provider 的序列流程獨占。
 */
class RefreshingTokenSource(
    private val config: OAuth.Config,
    private val transport: HttpTransport,
    state: TokenState,
    private val now: () -> Long = { System.currentTimeMillis() },
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
    private val persist: (TokenState) -> Unit = {},
) : TokenSource {

    var current: TokenState = state
        private set

    override fun token(): String {
        if (current.isUsable(now())) return current.accessToken
        return refresh()
    }

    override fun refresh(): String {
        if (current.refreshToken.isEmpty()) throw ProviderException.Auth()
        return post(OAuth.refreshForm(config, current.refreshToken)).accessToken
    }

    /** 授權碼 → token（首次授權；同樣套 §2.1 重試）。 */
    fun exchange(code: String, verifier: String): TokenState =
        post(OAuth.exchangeForm(config, code, verifier))

    private fun post(body: String): TokenState {
        var transient = 0
        while (true) {
            val req = HttpRequest(
                "POST", config.tokenUrl,
                mapOf("Content-Type" to "application/x-www-form-urlencoded"),
                body.toByteArray(Charsets.UTF_8),
            )
            val resp = try {
                transport.send(req)
            } catch (e: IOException) {
                HttpResponse(0, ByteArray(0))
            }
            val text = resp.body.toString(Charsets.UTF_8)
            when (OAuth.classifyTokenError(resp.status, text)) {
                OAuth.TokenErrorClass.OK -> {
                    current = current.applying(text, now())
                    persist(current)
                    return current
                }
                OAuth.TokenErrorClass.AUTH -> throw ProviderException.Auth()
                OAuth.TokenErrorClass.TRANSIENT -> {
                    if (transient >= RetryPolicy.MAX_TRANSIENT_RETRIES) throw ProviderException.Transient()
                    sleep(RetryPolicy.TRANSIENT_DELAYS_MS[transient])
                    transient++
                }
                OAuth.TokenErrorClass.HTTP -> throw ProviderException.Http(resp.status)
            }
        }
    }
}
