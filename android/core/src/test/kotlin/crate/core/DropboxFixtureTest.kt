package crate.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Dropbox provider 契約測試：跑 contract/fixtures/dropbox_cases/（provider.md §9）。
 * FakeDropbox = HTTP 語意層 in-memory（與 dropbox_generate.py 同語意）。
 */
class DropboxFixtureTest {

    @Test
    fun `all dropbox fixture cases match expected json byte for byte`() {
        val casesDir = findDir("contract/fixtures/dropbox_cases") ?: fail("dropbox_cases not found")
        val assetsDir = findDir("contract/fixtures/sync_assets") ?: fail("sync_assets not found")
        val names = casesDir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted()
            ?: fail("cannot list $casesDir")
        assertTrue(names.size >= 8, "expected >=8 dropbox cases, got ${names.size}")

        val failures = ArrayList<String>()
        for (name in names) {
            val caseDir = File(casesDir, name)
            val expected = File(caseDir, "expected.json").readBytes()
            val script = Json.parseToJsonElement(File(caseDir, "script.json").readText()).jsonObject
            val box = FakeDropbox(script["maxPage"]?.jsonPrimitive?.int ?: 2000)
            val provider = DropboxProvider(script["root"]?.jsonPrimitive?.contentOrNull ?: "/Music", box, box, sleep = {})
            val engine = SyncEngine(provider)
            val out = ArrayList<Map<String, Any?>>()
            for (step in script["steps"]!!.jsonArray) {
                val deleteAfter = ArrayList<String>()
                for (opEl in step.jsonObject["ops"]!!.jsonArray) applyOp(box, assetsDir, opEl.jsonObject, deleteAfter)
                box.requests = 0
                provider.beginRound()
                var error: String? = null
                var report: Map<String, Any?>? = null
                try {
                    val r = engine.sync(afterDelta = { deleteAfter.forEach { box.delete(it) } })
                    report = engine.toCanonical(r)
                } catch (e: ProviderException.Auth) {
                    error = "auth"
                } catch (e: ProviderException.Transient) {
                    error = "transient"
                }
                out.add(linkedMapOf(
                    "provider" to linkedMapOf<String, Any?>(
                        "error" to error, "reauths" to provider.reauths, "requests" to box.requests,
                        "reset" to provider.reset, "sleeps" to provider.sleeps,
                        "unscanned" to (if (error == null) engine.unscanned else emptyList()),
                    ),
                    "report" to report,
                ))
            }
            val actual = CanonicalJson.render(out).toByteArray(Charsets.UTF_8)
            if (!expected.contentEquals(actual)) {
                failures.add("case [$name]\n--- expected ---\n${expected.decodeToString()}\n" +
                    "--- actual ---\n${actual.decodeToString()}")
            }
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size}/${names.size} dropbox cases drifted:\n\n" + failures.joinToString("\n\n========\n\n"))
        }
    }

    @Test
    fun `state round trip and media request`() {
        val box = FakeDropbox(2000)
        box.mkdir("/Music")
        box.put("/Music/x.flac", byteArrayOf(1, 2, 3), 1700000001)
        val p1 = DropboxProvider("/music", box, box, sleep = {})
        val s1 = p1.snapshot()
        assertEquals(1, s1.size)
        val exported = p1.exportState() ?: fail("export")
        val p2 = DropboxProvider("/music", box, box, sleep = {})
        p2.restoreState(exported)
        box.requests = 0
        assertEquals(s1, p2.snapshot())
        assertEquals(1, box.requests, "還原後 = 純 continue")
        val id = p2.fileId("x.flac") ?: fail("id")
        val req = p2.mediaRequest(id, rangeStart = 10)
        assertEquals("bytes=10-", req.headers["Range"])
        assertEquals("{\"path\":\"$id\"}", req.headers["Dropbox-API-Arg"])
        val p3 = DropboxProvider("/nowhere", box, box, sleep = {})
        assertFailsWith<ProviderException.NotFound> { p3.snapshot() }
        p3.restoreState("{bad")
        assertNull(p3.exportState())
        assertEquals(64, FakeDropbox.contentHash(ByteArray(0)).length)
    }

    private fun applyOp(box: FakeDropbox, assetsDir: File, op: JsonObject, deleteAfter: MutableList<String>) {
        fun s(k: String) = op[k]!!.jsonPrimitive.contentOrNull!!
        fun bytes(): ByteArray = op["asset"]?.jsonPrimitive?.contentOrNull
            ?.let { File(assetsDir, it).readBytes() } ?: s("text").toByteArray(Charsets.UTF_8)
        when (s("op")) {
            "mkdir" -> box.mkdir(s("path"))
            "put" -> box.put(s("path"), bytes(), op["mtime"]!!.jsonPrimitive.int)
            "rename" -> box.rename(s("from"), s("to"))
            "delete" -> box.delete(s("path"))
            "touch" -> box.touch(s("path"), op["mtime"]!!.jsonPrimitive.int)
            "invalidate_cursor" -> box.invalidateCursor()
            "expire_token" -> box.tokenValid = false
            "fail" -> {
                repeat(op["count"]!!.jsonPrimitive.int) { box.forced.add(s("kind")) }
                box.skip = op["skip"]?.jsonPrimitive?.int ?: 0
            }
            "delete_after_delta" -> deleteAfter.add(s("path"))
            else -> fail("unknown op: ${s("op")}")
        }
    }

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

/** FakeDropbox（HTTP 語意層；同 dropbox_generate.py）。 */
class FakeDropbox(private val maxPage: Int) : HttpTransport, TokenSource {

    class FileNode(var display: String, val id: String, var data: ByteArray, var hash: String, var modifiedAt: Long)

    companion object {
        const val API = "https://api.dropboxapi.com/2"
        const val CONTENT = "https://content.dropboxapi.com/2"
        private const val BLOCK = 4 * 1024 * 1024

        /** Dropbox content_hash：4MB 分塊 SHA-256 串接後再 SHA-256。 */
        fun contentHash(data: ByteArray): String {
            val outer = MessageDigest.getInstance("SHA-256")
            var i = 0
            do {
                val end = minOf(data.size, i + BLOCK)
                outer.update(MessageDigest.getInstance("SHA-256").digest(data.copyOfRange(i, end)))
                i += BLOCK
            } while (i < data.size)
            return outer.digest().joinToString("") { "%02x".format(it) }
        }

        private const val NOT_FOUND =
            """{"error_summary":"path/not_found/..","error":{".tag":"path","path":{".tag":"not_found"}}}"""
    }

    val files = HashMap<String, FileNode>()
    val folders = HashMap<String, String>()
    private val log = ArrayList<Pair<Int, String>>()
    private var seq = 0
    private var minCursor = 1
    private var nextId = 1
    val forced = ArrayList<String>()
    var skip = 0
    private var tokenN = 1
    var tokenValid = true
    var requests = 0

    override fun token() = "tok-$tokenN"
    override fun refresh(): String { tokenN++; tokenValid = true; return "tok-$tokenN" }

    private fun bump(pl: String) { seq++; log.add(seq to pl) }
    private fun iso(ms: Long) = Instant.ofEpochSecond(ms / 1000).toString()

    fun mkdir(path: String) { folders[path.lowercase()] = path; bump(path.lowercase()) }

    fun put(path: String, data: ByteArray, mtime: Int) {
        val pl = path.lowercase()
        val id = files[pl]?.id ?: "id:f${nextId++}"
        files[pl] = FileNode(path, id, data, contentHash(data), mtime * 1000L)
        bump(pl)
    }

    fun touch(path: String, mtime: Int) { files.getValue(path.lowercase()).modifiedAt = mtime * 1000L; bump(path.lowercase()) }

    fun rename(src: String, dst: String) {
        val sl = src.lowercase(); val dl = dst.lowercase()
        files.remove(sl)?.let { e ->
            e.display = dst; files[dl] = e; bump(sl); bump(dl); return
        }
        folders.remove(sl); folders[dl] = dst; bump(sl); bump(dl)
        for (pl in (folders.keys + files.keys).filter { it.startsWith("$sl/") }.sorted()) {
            val rest = pl.substring(sl.length)
            folders.remove(pl)?.let { disp -> folders[dl + rest] = dst + disp.substring(src.length) }
                ?: files.remove(pl)?.let { e -> e.display = dst + e.display.substring(src.length); files[dl + rest] = e }
            bump(dl + rest)
        }
    }

    fun delete(path: String) {
        val pl = path.lowercase()
        if (files.remove(pl) == null) {
            folders.remove(pl)
            folders.keys.filter { it.startsWith("$pl/") }.forEach { folders.remove(it) }
            files.keys.filter { it.startsWith("$pl/") }.forEach { files.remove(it) }
        }
        bump(pl)
    }

    fun invalidateCursor() { seq++; minCursor = seq + 1 }

    private fun entry(pl: String): JsonObject = buildJsonObject {
        val f = files[pl]
        val d = folders[pl]
        when {
            f != null -> {
                put(".tag", "file"); put("name", f.display.substringAfterLast('/')); put("path_lower", pl)
                put("path_display", f.display); put("id", f.id); put("rev", f.hash.substring(0, 9))
                put("size", f.data.size); put("content_hash", f.hash)
                put("server_modified", iso(f.modifiedAt)); put("client_modified", iso(f.modifiedAt))
            }
            d != null -> {
                put(".tag", "folder"); put("name", d.substringAfterLast('/')); put("path_lower", pl)
                put("path_display", d); put("id", "id:d$pl")
            }
            else -> {
                put(".tag", "deleted"); put("name", pl.substringAfterLast('/')); put("path_lower", pl); put("path_display", pl)
            }
        }
    }

    private fun under(rl: String, pl: String) = rl.isEmpty() || pl == rl || pl.startsWith("$rl/")
    private fun resp(code: Int, s: String) = HttpResponse(code, s.toByteArray())

    private fun listPage(keys: List<String>, cap: Int, rl: String): HttpResponse {
        val page = keys.take(cap); val rest = keys.drop(cap)
        val cursor = rest.firstOrNull()?.let { "l$cap:$rl:$it" } ?: "c${seq + 1}:$rl"
        return resp(200, buildJsonObject {
            put("entries", buildJsonArray { page.forEach { add(entry(it)) } })
            put("cursor", cursor); put("has_more", rest.isNotEmpty())
        }.toString())
    }

    override fun send(req: HttpRequest): HttpResponse {
        requests++
        if (forced.isNotEmpty()) {
            if (skip > 0) skip-- else when (forced.removeAt(0)) {
                "transient" -> return resp(503, """{"error_summary":"internal"}""")
                "ratelimit" -> return resp(429, """{"error_summary":"too_many_requests/..","error":{"reason":{".tag":"too_many_requests"}}}""")
                "notfound" -> return resp(409, NOT_FOUND)
                "offline" -> throw TransportException("offline")
                else -> error("unknown forced kind")
            }
        }
        if (req.headers["Authorization"] != "Bearer tok-$tokenN" || !tokenValid) {
            return resp(401, """{"error_summary":"expired_access_token/..","error":{".tag":"expired_access_token"}}""")
        }
        val arg = if (req.body.isEmpty()) JsonObject(emptyMap())
        else Json.parseToJsonElement(req.body.toString(Charsets.UTF_8)).jsonObject
        fun argStr(k: String) = (arg[k] as? JsonPrimitive)?.contentOrNull ?: ""
        when (req.url) {
            "$API/files/get_metadata" -> {
                val pl = argStr("path").lowercase()
                return if (folders.containsKey(pl) || files.containsKey(pl)) resp(200, entry(pl).toString()) else resp(409, NOT_FOUND)
            }
            "$API/files/list_folder/get_latest_cursor" ->
                return resp(200, buildJsonObject { put("cursor", "c${seq + 1}:${argStr("path").lowercase()}") }.toString())
            "$API/files/list_folder" -> {
                val rl = argStr("path").lowercase()
                if (rl.isNotEmpty() && !folders.containsKey(rl)) return resp(409, NOT_FOUND)
                val cap = minOf(arg["limit"]?.jsonPrimitive?.int ?: 2000, maxPage)
                return listPage((folders.keys + files.keys).filter { under(rl, it) && it != rl }.sorted(), cap, rl)
            }
            "$API/files/list_folder/continue" -> {
                val cursor = argStr("cursor")
                if (cursor.startsWith("l")) {
                    val parts = cursor.substring(1).split(':', limit = 3)
                    val cap = parts[0].toInt(); val rl = parts[1]; val start = parts[2]
                    return listPage((folders.keys + files.keys).filter { under(rl, it) && it != rl && it >= start }.sorted(), cap, rl)
                }
                if (!cursor.startsWith("c")) return resp(400, """{"error_summary":"invalid cursor"}""")
                val parts = cursor.substring(1).split(':', limit = 2)
                val t = parts[0].toInt(); val rl = parts[1]
                if (t < minCursor || t > seq + 1) return resp(409, """{"error_summary":"reset/..","error":{".tag":"reset"}}""")
                val entries = log.filter { it.first >= t && under(rl, it.second) }
                val page = entries.take(maxPage); val rest = entries.drop(maxPage)
                val next = rest.firstOrNull()?.let { "c${it.first}:$rl" } ?: "c${seq + 1}:$rl"
                return resp(200, buildJsonObject {
                    put("entries", buildJsonArray { page.forEach { add(entry(it.second)) } })
                    put("cursor", next); put("has_more", rest.isNotEmpty())
                }.toString())
            }
            "$CONTENT/files/download" -> {
                val ref = (Json.parseToJsonElement(req.headers["Dropbox-API-Arg"] ?: "{}").jsonObject["path"]
                    as? JsonPrimitive)?.contentOrNull ?: ""
                val f = (if (ref.startsWith("id:")) files.values.firstOrNull { it.id == ref } else files[ref.lowercase()])
                    ?: return resp(409, NOT_FOUND)
                val rng = req.headers["Range"]
                if (rng != null && rng.startsWith("bytes=")) {
                    val parts = rng.removePrefix("bytes=").split('-', limit = 2)
                    val a = parts[0].toIntOrNull() ?: 0
                    val b = parts.getOrNull(1)?.takeIf { it.isNotEmpty() }?.toInt() ?: (f.data.size - 1)
                    return HttpResponse(206, f.data.copyOfRange(a, b + 1))
                }
                return HttpResponse(200, f.data)
            }
            else -> return resp(404, """{"error_summary":"unknown endpoint"}""")
        }
    }
}
