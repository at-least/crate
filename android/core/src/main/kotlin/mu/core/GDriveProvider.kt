package mu.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLDecoder
import java.time.Instant
import java.time.format.DateTimeParseException

// ---------------------------------------------------------------- 注入面（HTTP / token）

data class HttpRequest(val method: String, val url: String, val headers: Map<String, String>,
                       val body: ByteArray = ByteArray(0))
data class HttpResponse(val status: Int, val body: ByteArray)

/** 傳輸層失敗（連不上、逾時）→ provider 視為 transient。 */
class TransportException(message: String) : IOException(message)

/** 同步 HTTP（provider 在 Dispatchers.IO 上執行）。契約測試接 in-memory fake；正式接 HttpURLConnection。 */
fun interface HttpTransport {
    @Throws(TransportException::class)
    fun send(req: HttpRequest): HttpResponse
}

/** access token 來源。OAuth 流程（Custom Tab + PKCE + 鑰匙串）屬 App 層，依 D11 隨 client ID 進場。 */
interface TokenSource {
    fun token(): String

    /** 401 後重授權；回新 token。失敗拋錯 → provider 以 [ProviderException.Auth] 傳播。 */
    fun refresh(): String
}

// ---------------------------------------------------------------- GDriveProvider（provider.md §8）

/**
 * Google Drive provider：全 Drive 節點表 + changes 增量 → 引擎 snapshot（path → md5）。
 * 非 thread-safe：由 syncMutex 序列化的同步流程獨占（同 SyncEngine）。
 *
 * @param sleep 退避注入（測試收集；預設 Thread.sleep）。
 */
class GDriveProvider(
    val rootId: String,
    private val transport: HttpTransport,
    private val tokenSource: TokenSource,
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
) : SyncProvider {

    companion object {
        const val BASE = "https://www.googleapis.com/drive/v3"
        const val PAGE_SIZE = 1000
        private const val FILE_FIELDS = "id,name,mimeType,parents,size,md5Checksum,modifiedTime"
        private const val LIST_FIELDS = "nextPageToken,files($FILE_FIELDS)"
        private const val CHANGE_FIELDS =
            "nextPageToken,newStartPageToken,changes(fileId,removed,file($FILE_FIELDS,trashed))"

        /** 資料夾 URL 或 id → id（`/folders/<id>`、`?id=`；純 id 原樣）。空 → null。 */
        fun resolveRoot(raw: String): String? {
            val s = raw.trim()
            if (s.isEmpty()) return null
            if (!s.contains("://")) return s
            val uri = try { URI(s) } catch (e: Exception) { return null }
            uri.rawQuery?.split('&')?.forEach { kv ->
                val i = kv.indexOf('=')
                if (i > 0 && kv.substring(0, i) == "id") {
                    val v = URLDecoder.decode(kv.substring(i + 1), "UTF-8")
                    if (v.isNotEmpty()) return v
                }
            }
            val segs = (uri.path ?: "").split('/').filter { it.isNotEmpty() }
            for (i in segs.indices) {
                if (segs[i] == "folders" && i + 1 < segs.size) return segs[i + 1]
            }
            return null
        }

        /** RFC3339（Drive 固定 UTC `Z`；小數秒可有可無）→ ms。解析失敗 → 0。 */
        fun parseIsoMs(s: String): Long = try {
            Instant.parse(s).toEpochMilli()
        } catch (e: DateTimeParseException) {
            0L
        }
    }

    internal data class Node(
        val name: String,
        val mimeType: String,
        val parent: String?,
        val trashed: Boolean,
        val size: Long?,
        val md5: String?,
        val modifiedAt: Long,
    )

    private val nodes = HashMap<String, Node>()
    private var cursor: String? = null
    private var pathToId: Map<String, String> = emptyMap()

    // 每輪統計（fixtures 觀測；App 層可顯示）
    var reauths = 0; private set
    var sleeps: List<Long> = emptyList(); private set
    var reset = false; private set

    /** 歸零本輪統計（每次 sync 前由 caller 呼叫；引擎不知道 provider 統計）。 */
    fun beginRound() {
        reauths = 0; sleeps = emptyList(); reset = false
    }

    // ---- 狀態匯出（App 層存 sync_state['cursor:gdrive:<rootId>']）

    fun exportState(): String? {
        val c = cursor ?: return null
        val obj = buildJsonObject {
            put("cursor", c)
            put("nodes", buildJsonArray {
                for (id in nodes.keys.sorted()) {
                    val n = nodes.getValue(id)
                    add(buildJsonObject {
                        put("id", id); put("name", n.name); put("mimeType", n.mimeType)
                        put("trashed", n.trashed); put("modifiedAt", n.modifiedAt)
                        n.parent?.let { put("parent", it) }
                        n.size?.let { put("size", it) }
                        n.md5?.let { put("md5", it) }
                    })
                }
            })
        }
        return obj.toString()
    }

    /** 還原失敗（格式不對）→ 視為無 cursor，下輪全量。 */
    fun restoreState(s: String?) {
        nodes.clear(); cursor = null; pathToId = emptyMap()
        if (s == null) return
        val obj = try { Json.parseToJsonElement(s).jsonObject } catch (e: Exception) { return }
        val c = obj["cursor"]?.jsonPrimitive?.contentOrNull ?: return
        val arr = obj["nodes"] as? JsonArray ?: return
        for (el in arr) {
            val d = el as? JsonObject ?: continue
            val id = d.str("id") ?: continue
            val name = d.str("name") ?: continue
            val mime = d.str("mimeType") ?: continue
            nodes[id] = Node(
                name, mime, d.str("parent"),
                d["trashed"]?.jsonPrimitive?.booleanOrNull ?: false,
                d["size"]?.jsonPrimitive?.longOrNull, d.str("md5"),
                d["modifiedAt"]?.jsonPrimitive?.longOrNull ?: 0L,
            )
        }
        cursor = c
    }

    // ---- SyncProvider

    override fun snapshot(): Map<String, String> {
        if (cursor == null) {
            full()
        } else {
            try {
                delta()
            } catch (e: ProviderException.NotFound) {
                resetAndFull()
            } catch (e: ProviderException.Http) {
                if (e.status != 400) throw e
                resetAndFull()
            }
        }
        return paths()
    }

    /** ByteSource：size 取自節點 metadata；read = Range 請求（206；200 整檔則本地裁切）。 */
    override fun open(path: String): ByteSource? {
        val id = pathToId[path] ?: return null
        return DriveSource(id, nodes[id]?.size ?: 0L)
    }

    private inner class DriveSource(private val fileId: String, override val size: Long) : ByteSource {
        override fun read(offset: Long, length: Int): ByteArray {
            if (length <= 0) return ByteArray(0)
            val (status, body) = getStatus("$BASE/files/$fileId?alt=media",
                mapOf("Range" to "bytes=$offset-${offset + length - 1}"))
            if (status == 206) return body
            if (offset >= body.size) return ByteArray(0)
            val a = offset.toInt()
            return body.copyOfRange(a, minOf(body.size, a + length))
        }
    }

    /** 播放/釘選用：目前索引裡 path 對應的 file id（無 → null）。 */
    fun fileId(path: String): String? = pathToId[path]

    /** 串流/下載請求（App 層接 Media3 DataSource headers）。 */
    fun mediaRequest(fileId: String, rangeStart: Long? = null, rangeEnd: Long? = null): HttpRequest {
        val headers = HashMap<String, String>()
        headers["Authorization"] = "Bearer ${tokenSource.token()}"
        if (rangeStart != null) headers["Range"] = "bytes=$rangeStart-${rangeEnd ?: ""}"
        return HttpRequest("GET", "$BASE/files/$fileId?alt=media", headers)
    }

    // ---- 節點表

    private fun resetAndFull() {
        reset = true
        cursor = null
        full()
    }

    private fun full() {
        val start = json(get("$BASE/changes/startPageToken")).str("startPageToken")
            ?: throw ProviderException.Http(0)
        nodes.clear()
        var page: String? = null
        while (true) {
            var url = "$BASE/files?q=trashed%3Dfalse&pageSize=$PAGE_SIZE&fields=$LIST_FIELDS"
            if (page != null) url += "&pageToken=$page"
            val r = json(get(url))
            for (f in r["files"]?.jsonArray ?: JsonArray(emptyList())) {
                val o = f.jsonObject
                val id = o.str("id") ?: continue
                node(o)?.let { nodes[id] = it }
            }
            page = r.str("nextPageToken") ?: break
        }
        cursor = start
    }

    private fun delta() {
        var page = cursor!!
        while (true) {
            val url = "$BASE/changes?pageToken=$page&pageSize=$PAGE_SIZE" +
                "&includeRemoved=true&fields=$CHANGE_FIELDS"
            val r = json(get(url))
            for (c in r["changes"]?.jsonArray ?: JsonArray(emptyList())) {
                val o = c.jsonObject
                val id = o.str("fileId") ?: continue
                val file = o["file"] as? JsonObject
                val removed = o["removed"]?.jsonPrimitive?.booleanOrNull == true
                val trashed = file?.get("trashed")?.jsonPrimitive?.booleanOrNull == true
                if (removed || trashed) {
                    nodes.remove(id)
                } else if (file != null) {
                    node(file)?.let { nodes[id] = it }
                }
            }
            val next = r.str("nextPageToken")
            if (next != null) {
                page = next
                continue
            }
            cursor = r.str("newStartPageToken") ?: throw ProviderException.Http(0)
            return
        }
    }

    private fun node(f: JsonObject): Node? {
        val name = f.str("name") ?: return null
        val mime = f.str("mimeType") ?: return null
        val mt = f.str("modifiedTime") ?: return null
        val parents = (f["parents"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?: emptyList()
        return Node(
            name, mime, parents.firstOrNull(),
            f["trashed"]?.jsonPrimitive?.booleanOrNull ?: false,
            f.str("size")?.toLongOrNull(), f.str("md5Checksum"), parseIsoMs(mt),
        )
    }

    /** 節點表 → path → rev（§8.2/§8.3）。 */
    private fun paths(): Map<String, String> {
        val snap = LinkedHashMap<String, String>()
        val p2i = HashMap<String, String>()
        for (id in nodes.keys.sorted()) {
            val n = nodes.getValue(id)
            if (n.mimeType.startsWith("application/vnd.google-apps.")) continue
            val names = ArrayList<String>()
            var cur = n
            val seen = hashSetOf(id)
            var ok = false
            while (true) {
                if (cur.trashed || '/' in cur.name) break
                names.add(cur.name)
                val pid = cur.parent ?: break
                if (pid == rootId) { ok = true; break }
                val next = nodes[pid] ?: break
                if (!seen.add(pid)) break
                cur = next
            }
            if (!ok) continue
            val path = names.asReversed().joinToString("/")
            if (path in snap) continue // 同 path 碰撞：id 字典序最小者勝
            snap[path] = n.md5 ?: "${n.size ?: 0}:${n.modifiedAt}"
            p2i[path] = id
        }
        pathToId = p2i
        return snap
    }

    // ---- HTTP + §2.1 重試

    private fun json(body: ByteArray): JsonObject = try {
        Json.parseToJsonElement(body.toString(Charsets.UTF_8)).jsonObject
    } catch (e: Exception) {
        throw ProviderException.Http(0)
    }

    private fun JsonObject.str(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

    private fun get(url: String): ByteArray = getStatus(url, emptyMap()).second

    private fun getStatus(url: String, extra: Map<String, String>): Pair<Int, ByteArray> {
        var transient = 0
        var reauthUsed = false
        var token = tokenSource.token()
        val sleepsNow = ArrayList(sleeps)
        while (true) {
            val req = HttpRequest("GET", url, extra + ("Authorization" to "Bearer $token"))
            val resp = try {
                transport.send(req)
            } catch (e: IOException) {
                HttpResponse(0, ByteArray(0))
            }
            val status = resp.status
            val body = resp.body
            if (status in 200..299) return status to body
            if (status == 401) {
                if (reauthUsed) throw ProviderException.Auth()
                reauthUsed = true
                reauths++
                token = tokenSource.refresh()
                continue
            }
            val isTransient = status == 0 || status == 429 || status >= 500 ||
                (status == 403 && body.toString(Charsets.UTF_8).contains("ateLimitExceeded"))
            if (isTransient) {
                if (transient >= RetryPolicy.MAX_TRANSIENT_RETRIES) throw ProviderException.Transient()
                val ms = RetryPolicy.TRANSIENT_DELAYS_MS[transient]
                sleep(ms)
                sleepsNow.add(ms)
                sleeps = sleepsNow.toList()
                transient++
                continue
            }
            if (status == 404) throw ProviderException.NotFound()
            throw ProviderException.Http(status)
        }
    }
}

// ---------------------------------------------------------------- HttpURLConnection transport（正式環境）

class HttpUrlConnectionTransport(
    private val connectTimeoutMs: Int = 15_000,
    private val readTimeoutMs: Int = 60_000,
) : HttpTransport {
    override fun send(req: HttpRequest): HttpResponse {
        val conn = try {
            (URL(req.url).openConnection() as HttpURLConnection).apply {
                requestMethod = req.method
                connectTimeout = connectTimeoutMs
                readTimeout = readTimeoutMs
                for ((k, v) in req.headers) setRequestProperty(k, v)
                if (req.body.isNotEmpty()) doOutput = true
            }
        } catch (e: IOException) {
            throw TransportException(e.message ?: "connect")
        }
        try {
            if (req.body.isNotEmpty()) conn.outputStream.use { it.write(req.body) }
            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            val body = stream?.use { it.readBytes() } ?: ByteArray(0)
            return HttpResponse(status, body)
        } catch (e: IOException) {
            throw TransportException(e.message ?: "io")
        } finally {
            conn.disconnect()
        }
    }
}
