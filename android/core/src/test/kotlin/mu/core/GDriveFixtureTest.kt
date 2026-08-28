package mu.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * GDrive provider 契約測試：跑 contract/fixtures/gdrive_cases/。
 * FakeDrive = HTTP 語意層的 in-memory Drive（與 gdrive_generate.py 同語意）；
 * 每步輸出 {provider 統計, SyncReport} 必須與 Python 參考 byte-identical（provider.md §8）。
 */
class GDriveFixtureTest {

    companion object {
        const val ROOT = "root0"
    }

    @Test
    fun `all gdrive fixture cases match expected json byte for byte`() {
        val casesDir = findDir("contract/fixtures/gdrive_cases") ?: fail("gdrive_cases not found")
        val assetsDir = findDir("contract/fixtures/sync_assets") ?: fail("sync_assets not found")
        val names = casesDir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted()
            ?: fail("cannot list $casesDir")
        assertTrue(names.size >= 7, "expected >=7 gdrive cases, got ${names.size}")

        val failures = ArrayList<String>()
        for (name in names) {
            val caseDir = File(casesDir, name)
            val expected = File(caseDir, "expected.json").readBytes()
            val script = Json.parseToJsonElement(File(caseDir, "script.json").readText()).jsonObject
            val drive = FakeDrive(script["maxPage"]?.jsonPrimitive?.int ?: 1000)
            val provider = GDriveProvider(ROOT, drive, drive, sleep = {})
            val engine = SyncEngine(provider)
            val out = ArrayList<Map<String, Any?>>()
            for (step in script["steps"]!!.jsonArray) {
                val deleteAfter = ArrayList<String>()
                for (opEl in step.jsonObject["ops"]!!.jsonArray) {
                    applyOp(drive, assetsDir, opEl.jsonObject, deleteAfter)
                }
                drive.requests = 0
                provider.beginRound()
                var error: String? = null
                var report: Map<String, Any?>? = null
                try {
                    val r = engine.sync(afterDelta = { deleteAfter.forEach { drive.delete(it) } })
                    report = engine.toCanonical(r)
                } catch (e: ProviderException.Auth) {
                    error = "auth"
                } catch (e: ProviderException.Transient) {
                    error = "transient"
                }
                out.add(linkedMapOf(
                    "provider" to linkedMapOf<String, Any?>(
                        "error" to error,
                        "reauths" to provider.reauths,
                        "requests" to drive.requests,
                        "reset" to provider.reset,
                        "sleeps" to provider.sleeps,
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
            fail("${failures.size}/${names.size} gdrive cases drifted:\n\n" +
                failures.joinToString("\n\n========\n\n"))
        }
    }

    @Test
    fun `resolveRoot and iso parse`() {
        assertEquals("abc123", GDriveProvider.resolveRoot("https://drive.google.com/drive/u/0/folders/abc123?usp=sharing"))
        assertEquals("xyz", GDriveProvider.resolveRoot("https://drive.google.com/open?id=xyz"))
        assertEquals("abc", GDriveProvider.resolveRoot(" abc "))
        assertNull(GDriveProvider.resolveRoot(""))
        assertNull(GDriveProvider.resolveRoot("https://drive.google.com/drive/my-drive"))
        assertEquals(1700000100_000L, GDriveProvider.parseIsoMs("2023-11-14T22:15:00.000Z"))
        assertEquals(1700000100_000L, GDriveProvider.parseIsoMs("2023-11-14T22:15:00Z"))
        assertEquals(1700000100_500L, GDriveProvider.parseIsoMs("2023-11-14T22:15:00.5Z"))
        assertEquals(0L, GDriveProvider.parseIsoMs("garbage"))
    }

    @Test
    fun `state round trip and media request`() {
        val drive = FakeDrive(1000)
        drive.mkdir("d1", "A", ROOT, 1700000000)
        drive.put("f1", "x.flac", "d1", byteArrayOf(1, 2, 3), 1700000001)
        val p1 = GDriveProvider(ROOT, drive, drive, sleep = {})
        val s1 = p1.snapshot()
        assertEquals(1, s1.size)
        val exported = p1.exportState() ?: fail("export")
        val p2 = GDriveProvider(ROOT, drive, drive, sleep = {})
        p2.restoreState(exported)
        drive.requests = 0
        assertEquals(s1, p2.snapshot())
        assertEquals(1, drive.requests, "還原後 = 純 delta（一個 changes.list）")
        assertEquals("f1", p2.fileId("A/x.flac"))
        val req = p2.mediaRequest("f1", rangeStart = 10)
        assertEquals("bytes=10-", req.headers["Range"])
        assertEquals("https://www.googleapis.com/drive/v3/files/f1?alt=media", req.url)
        // 壞狀態 → 視為無 cursor
        val p3 = GDriveProvider(ROOT, drive, drive, sleep = {})
        p3.restoreState("{not json")
        assertNull(p3.exportState())
        // 其他 4xx → 直接傳播
        drive.forced.add("forbidden")
        val e = assertFailsWith<ProviderException.Http> { p3.snapshot() }
        assertEquals(403, e.status)
    }

    private fun applyOp(drive: FakeDrive, assetsDir: File, op: JsonObject, deleteAfter: MutableList<String>) {
        fun s(k: String) = op[k]!!.jsonPrimitive.contentOrNull!!
        fun opt(k: String) = op[k]?.jsonPrimitive?.contentOrNull
        fun bytes(): ByteArray = op["asset"]?.jsonPrimitive?.contentOrNull
            ?.let { File(assetsDir, it).readBytes() } ?: s("text").toByteArray(Charsets.UTF_8)
        when (s("op")) {
            "mkdir" -> drive.mkdir(s("id"), s("name"), opt("parent"), op["mtime"]?.jsonPrimitive?.int ?: 1700000000)
            "put" -> drive.put(s("id"), s("name"), opt("parent"), bytes(), op["mtime"]!!.jsonPrimitive.int,
                opt("mime") ?: "application/octet-stream", op["md5"]?.jsonPrimitive?.boolean ?: true)
            "update" -> drive.update(s("id"), bytes(), op["mtime"]!!.jsonPrimitive.int)
            "rename" -> drive.rename(s("id"), s("name"))
            "move" -> drive.move(s("id"), opt("parent"))
            "trash" -> drive.setTrashed(s("id"), true)
            "untrash" -> drive.setTrashed(s("id"), false)
            "delete" -> drive.delete(s("id"))
            "touch" -> drive.touch(s("id"), op["mtime"]!!.jsonPrimitive.int)
            "invalidate_cursor" -> drive.invalidateCursor()
            "expire_token" -> drive.tokenValid = false
            "fail" -> {
                repeat(op["count"]!!.jsonPrimitive.int) { drive.forced.add(s("kind")) }
                drive.skip = op["skip"]?.jsonPrimitive?.int ?: 0
            }
            "delete_after_delta" -> deleteAfter.add(s("id"))
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

/** FakeDrive（HTTP 語意層；同 gdrive_generate.py）。 */
class FakeDrive(private val maxPage: Int) : HttpTransport, TokenSource {

    class Node(
        var name: String, var mimeType: String, var parent: String?, var trashed: Boolean,
        var size: Long?, var md5: String?, var modifiedAt: Long, var data: ByteArray,
    )

    private val folder = "application/vnd.google-apps.folder"
    val nodes = HashMap<String, Node>()
    private val log = ArrayList<Pair<Int, String>>()
    private var seq = 0
    private var minToken = 1
    val forced = ArrayList<String>()
    var skip = 0
    private var tokenN = 1
    var tokenValid = true
    var requests = 0

    override fun token() = "tok-$tokenN"
    override fun refresh(): String { tokenN++; tokenValid = true; return "tok-$tokenN" }

    private fun bump(id: String) { seq++; log.add(seq to id) }

    fun mkdir(id: String, name: String, parent: String?, mtime: Int) {
        nodes[id] = Node(name, folder, parent, false, null, null, mtime * 1000L, ByteArray(0)); bump(id)
    }

    fun put(id: String, name: String, parent: String?, data: ByteArray, mtime: Int,
            mime: String = "application/octet-stream", md5: Boolean = true) {
        nodes[id] = Node(name, mime, parent, false, data.size.toLong(),
            if (md5) md5Hex(data) else null, mtime * 1000L, data)
        bump(id)
    }

    fun update(id: String, data: ByteArray, mtime: Int) {
        nodes.getValue(id).apply { size = data.size.toLong(); md5 = md5Hex(data); modifiedAt = mtime * 1000L; this.data = data }
        bump(id)
    }

    fun rename(id: String, name: String) { nodes.getValue(id).name = name; bump(id) }
    fun move(id: String, parent: String?) { nodes.getValue(id).parent = parent; bump(id) }
    fun setTrashed(id: String, t: Boolean) { nodes.getValue(id).trashed = t; bump(id) }
    fun delete(id: String) { nodes.remove(id); bump(id) }
    fun touch(id: String, mtime: Int) { nodes.getValue(id).modifiedAt = mtime * 1000L; bump(id) }
    fun invalidateCursor() { seq++; minToken = seq + 1 }

    private fun md5Hex(data: ByteArray) =
        MessageDigest.getInstance("MD5").digest(data).joinToString("") { "%02x".format(it) }

    private fun iso(ms: Long): String {
        val base = Instant.ofEpochSecond(ms / 1000).toString().removeSuffix("Z")
        return base + ".%03dZ".format(ms % 1000)
    }

    private fun fileJson(id: String, withTrashed: Boolean): JsonObject {
        val n = nodes.getValue(id)
        return buildJsonObject {
            put("id", id); put("name", n.name); put("mimeType", n.mimeType)
            put("parents", buildJsonArray { n.parent?.let { add(kotlinx.serialization.json.JsonPrimitive(it)) } ?: add(kotlinx.serialization.json.JsonNull) })
            put("modifiedTime", iso(n.modifiedAt))
            n.size?.let { put("size", it.toString()) }
            n.md5?.let { put("md5Checksum", it) }
            if (withTrashed) put("trashed", n.trashed)
        }
    }

    private fun err(code: Int, msg: String) = HttpResponse(code,
        buildJsonObject { put("error", buildJsonObject { put("code", code); put("message", msg) }) }
            .toString().toByteArray())

    override fun send(req: HttpRequest): HttpResponse {
        requests++
        if (forced.isNotEmpty()) {
            if (skip > 0) {
                skip--
            } else {
                when (forced.removeAt(0)) {
                    "transient" -> return err(503, "Backend Error")
                    "ratelimit" -> return HttpResponse(403,
                        """{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}],"message":"User Rate Limit Exceeded"}}"""
                            .toByteArray())
                    "notfound" -> return err(404, "File not found")
                    "forbidden" -> return err(403, "Insufficient Permission")
                    "offline" -> throw TransportException("offline")
                    else -> error("unknown forced kind")
                }
            }
        }
        if (req.headers["Authorization"] != "Bearer tok-$tokenN" || !tokenValid) {
            return err(401, "Invalid Credentials")
        }
        val uri = URI(req.url)
        val q = HashMap<String, String>()
        uri.rawQuery?.split('&')?.forEach { kv ->
            val i = kv.indexOf('=')
            if (i > 0) q[kv.substring(0, i)] = URLDecoder.decode(kv.substring(i + 1), "UTF-8")
        }
        val path = uri.path
        if (path == "/drive/v3/changes/startPageToken") {
            return HttpResponse(200, buildJsonObject { put("startPageToken", (seq + 1).toString()) }.toString().toByteArray())
        }
        if (path == "/drive/v3/changes") {
            val t = q["pageToken"]?.toIntOrNull()
            if (t == null || t < minToken || t > seq + 1) return err(400, "Invalid Value")
            val cap = minOf(q["pageSize"]?.toIntOrNull() ?: 1000, maxPage)
            val entries = log.filter { it.first >= t }
            val page = entries.take(cap)
            val rest = entries.drop(cap)
            val out = buildJsonObject {
                put("changes", buildJsonArray {
                    for ((_, id) in page) {
                        add(buildJsonObject {
                            put("fileId", id)
                            if (nodes.containsKey(id)) {
                                put("removed", false); put("file", fileJson(id, true))
                            } else {
                                put("removed", true)
                            }
                        })
                    }
                })
                if (rest.isNotEmpty()) put("nextPageToken", rest.first().first.toString())
                else put("newStartPageToken", (seq + 1).toString())
            }
            return HttpResponse(200, out.toString().toByteArray())
        }
        if (path == "/drive/v3/files") {
            if (q["q"] != "trashed=false") return err(400, "Invalid Value")
            val cap = minOf(q["pageSize"]?.toIntOrNull() ?: 1000, maxPage)
            val start = q["pageToken"]?.toIntOrNull() ?: 0
            val ids = nodes.filterValues { !it.trashed }.keys.sorted()
            val page = ids.drop(start).take(cap)
            val out = buildJsonObject {
                put("files", buildJsonArray { for (id in page) add(fileJson(id, false)) })
                if (start + cap < ids.size) put("nextPageToken", (start + cap).toString())
            }
            return HttpResponse(200, out.toString().toByteArray())
        }
        if (path.startsWith("/drive/v3/files/")) {
            val id = path.removePrefix("/drive/v3/files/")
            val n = nodes[id]
            if (n == null || n.trashed || q["alt"] != "media") return err(404, "File not found")
            val rng = req.headers["Range"]
            if (rng != null && rng.startsWith("bytes=")) {
                val parts = rng.removePrefix("bytes=").split('-', limit = 2)
                val a = parts[0].toIntOrNull() ?: 0
                val b = parts.getOrNull(1)?.takeIf { it.isNotEmpty() }?.toInt() ?: (n.data.size - 1)
                return HttpResponse(206, n.data.copyOfRange(a, b + 1))
            }
            return HttpResponse(200, n.data)
        }
        return err(404, "Not Found")
    }
}
