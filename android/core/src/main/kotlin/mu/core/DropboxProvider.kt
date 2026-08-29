package mu.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.IOException

/**
 * Dropbox provider（provider.md §9）：root 底下檔案節點表（key = path_lower）+ list_folder/continue 增量
 * → 引擎 snapshot（path → content_hash）。與 GDriveProvider 同構；非 thread-safe（syncMutex 序列化）。
 */
class DropboxProvider(
    /** 使用者輸入：`/Music`、`id:…`、或 `""`（整個 Dropbox）。 */
    val root: String,
    private val transport: HttpTransport,
    private val tokenSource: TokenSource,
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
) : SyncProvider {

    companion object {
        const val API = "https://api.dropboxapi.com/2"
        const val CONTENT = "https://content.dropboxapi.com/2"
        const val LIMIT = 2000
    }

    internal data class Node(val display: String, val id: String, val size: Long, val hash: String, val modifiedAt: Long)

    private class CursorReset : Exception()

    private var rootLower: String? = null
    private var rootDisplay: String? = null
    private val nodes = HashMap<String, Node>()
    private var cursor: String? = null
    private var pathToId: Map<String, String> = emptyMap()
    private var idToLower: Map<String, String> = emptyMap()

    var reauths = 0; private set
    var sleeps: List<Long> = emptyList(); private set
    var reset = false; private set

    fun beginRound() {
        reauths = 0; sleeps = emptyList(); reset = false
    }

    // ---- 狀態匯出（App 層存 sync_state['cursor:dropbox:<root>']）

    fun exportState(): String? {
        val c = cursor ?: return null
        val rl = rootLower ?: return null
        val rd = rootDisplay ?: return null
        return buildJsonObject {
            put("cursor", c); put("rootLower", rl); put("rootDisplay", rd)
            put("nodes", buildJsonArray {
                for (pl in nodes.keys.sorted()) {
                    val n = nodes.getValue(pl)
                    add(buildJsonObject {
                        put("pl", pl); put("display", n.display); put("id", n.id)
                        put("size", n.size); put("hash", n.hash); put("modifiedAt", n.modifiedAt)
                    })
                }
            })
        }.toString()
    }

    fun restoreState(s: String?) {
        nodes.clear(); cursor = null; pathToId = emptyMap(); idToLower = emptyMap()
        rootLower = null; rootDisplay = null
        if (s == null) return
        val obj = try { Json.parseToJsonElement(s).jsonObject } catch (e: Exception) { return }
        val c = obj.str("cursor") ?: return
        val rl = obj.str("rootLower") ?: return
        val rd = obj.str("rootDisplay") ?: return
        val arr = obj["nodes"] as? JsonArray ?: return
        for (el in arr) {
            val d = el as? JsonObject ?: continue
            val pl = d.str("pl") ?: continue
            nodes[pl] = Node(d.str("display") ?: continue, d.str("id") ?: continue,
                d["size"]?.jsonPrimitive?.longOrNull ?: 0L, d.str("hash") ?: "",
                d["modifiedAt"]?.jsonPrimitive?.longOrNull ?: 0L)
        }
        cursor = c; rootLower = rl; rootDisplay = rd
    }

    // ---- SyncProvider

    override fun snapshot(): Map<String, String> {
        if (cursor == null) {
            full()
        } else {
            try {
                delta()
            } catch (e: CursorReset) {
                reset = true
                cursor = null
                full()
            }
        }
        return paths()
    }

    override fun open(path: String): ByteSource? {
        val id = pathToId[path] ?: return null
        val pl = idToLower[id] ?: return null
        return DropboxSource(id, nodes[pl]?.size ?: 0L)
    }

    private inner class DropboxSource(private val fileId: String, override val size: Long) : ByteSource {
        override fun read(offset: Long, length: Int): ByteArray {
            if (length <= 0) return ByteArray(0)
            val (status, body) = call("$CONTENT/files/download", ByteArray(0),
                mapOf("Dropbox-API-Arg" to "{\"path\":\"$fileId\"}",
                    "Range" to "bytes=$offset-${offset + length - 1}"))
            if (status == 206) return body
            if (offset >= body.size) return ByteArray(0)
            val a = offset.toInt()
            return body.copyOfRange(a, minOf(body.size, a + length))
        }
    }

    fun fileId(path: String): String? = pathToId[path]

    /** 串流/下載請求（App 層接 Media3 DataSource）。 */
    fun mediaRequest(fileId: String, rangeStart: Long? = null, rangeEnd: Long? = null): HttpRequest {
        val headers = HashMap<String, String>()
        headers["Authorization"] = "Bearer ${tokenSource.token()}"
        headers["Dropbox-API-Arg"] = "{\"path\":\"$fileId\"}"
        if (rangeStart != null) headers["Range"] = "bytes=$rangeStart-${rangeEnd ?: ""}"
        return HttpRequest("POST", "$CONTENT/files/download", headers)
    }

    // ---- 節點表

    private fun listArg(): JsonObject = buildJsonObject {
        put("path", rootLower ?: ""); put("recursive", true); put("include_deleted", false); put("limit", LIMIT)
    }

    private fun resolveRoot() {
        if (rootLower != null) return
        if (root.isEmpty()) { rootLower = ""; rootDisplay = ""; return }
        val m = rpc("files/get_metadata", buildJsonObject { put("path", root) })
        rootLower = m.str("path_lower") ?: throw ProviderException.Http(0)
        rootDisplay = m.str("path_display") ?: throw ProviderException.Http(0)
    }

    private fun apply(entries: JsonArray?) {
        for (el in entries ?: return) {
            val e = el as? JsonObject ?: continue
            val pl = e.str("path_lower") ?: continue
            when (e.str(".tag")) {
                "file" -> {
                    val display = e.str("path_display") ?: continue
                    val id = e.str("id") ?: continue
                    val mt = e.str("server_modified") ?: continue
                    nodes[pl] = Node(display, id, e["size"]?.jsonPrimitive?.longOrNull ?: 0L,
                        e.str("content_hash") ?: e.str("rev") ?: "", GDriveProvider.parseIsoMs(mt))
                }
                "deleted" -> {
                    nodes.remove(pl)
                    nodes.keys.filter { it.startsWith("$pl/") }.forEach { nodes.remove(it) }
                }
            }
        }
    }

    private fun full() {
        resolveRoot()
        val start = rpc("files/list_folder/get_latest_cursor", listArg()).str("cursor")
            ?: throw ProviderException.Http(0)
        nodes.clear()
        var r = rpc("files/list_folder", listArg())
        apply(r["entries"] as? JsonArray)
        while (r["has_more"]?.jsonPrimitive?.booleanOrNull == true) {
            r = rpc("files/list_folder/continue", buildJsonObject { put("cursor", r.str("cursor") ?: "") })
            apply(r["entries"] as? JsonArray)
        }
        cursor = start
    }

    private fun delta() {
        var c = cursor!!
        while (true) {
            val r = rpc("files/list_folder/continue", buildJsonObject { put("cursor", c) })
            apply(r["entries"] as? JsonArray)
            c = r.str("cursor") ?: throw ProviderException.Http(0)
            if (r["has_more"]?.jsonPrimitive?.booleanOrNull != true) break
        }
        cursor = c
    }

    private fun paths(): Map<String, String> {
        val snap = LinkedHashMap<String, String>()
        val p2i = HashMap<String, String>()
        val i2l = HashMap<String, String>()
        val rd = rootDisplay ?: ""
        val prefix = if (rd.isEmpty()) "/" else "$rd/"
        for (pl in nodes.keys.sorted()) {
            val n = nodes.getValue(pl)
            if (!n.display.startsWith(prefix)) continue
            val path = n.display.substring(prefix.length)
            snap[path] = if (n.hash.isEmpty()) "${n.size}:${n.modifiedAt}" else n.hash
            p2i[path] = n.id
            i2l[n.id] = pl
        }
        pathToId = p2i; idToLower = i2l
        return snap
    }

    // ---- HTTP + §2.1 重試

    private fun JsonObject.str(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

    private fun rpc(endpoint: String, arg: JsonObject): JsonObject {
        val (_, out) = call("$API/$endpoint", arg.toString().toByteArray(Charsets.UTF_8),
            mapOf("Content-Type" to "application/json"))
        return try {
            Json.parseToJsonElement(out.toString(Charsets.UTF_8)).jsonObject
        } catch (e: Exception) {
            throw ProviderException.Http(0)
        }
    }

    private fun call(url: String, body: ByteArray, extra: Map<String, String>): Pair<Int, ByteArray> {
        var transient = 0
        var reauthUsed = false
        var token = tokenSource.token()
        val sleepsNow = ArrayList(sleeps)
        while (true) {
            val req = HttpRequest("POST", url, extra + ("Authorization" to "Bearer $token"), body)
            val resp = try {
                transport.send(req)
            } catch (e: IOException) {
                HttpResponse(0, ByteArray(0))
            }
            val status = resp.status
            if (status in 200..299) return status to resp.body
            if (status == 401) {
                if (reauthUsed) throw ProviderException.Auth()
                reauthUsed = true
                reauths++
                token = tokenSource.refresh()
                continue
            }
            if (status == 0 || status == 429 || status >= 500) {
                if (transient >= RetryPolicy.MAX_TRANSIENT_RETRIES) throw ProviderException.Transient()
                val ms = RetryPolicy.TRANSIENT_DELAYS_MS[transient]
                sleep(ms)
                sleepsNow.add(ms)
                sleeps = sleepsNow.toList()
                transient++
                continue
            }
            if (status == 409) {
                val text = resp.body.toString(Charsets.UTF_8)
                if (text.contains("not_found")) throw ProviderException.NotFound()
                if (text.contains("reset")) throw CursorReset()
            }
            throw ProviderException.Http(status)
        }
    }
}
