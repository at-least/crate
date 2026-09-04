package at.least.crate.android

import kotlinx.coroutines.runBlocking
import at.least.crate.android.db.LibraryDao
import at.least.crate.android.db.PinEntity
import at.least.crate.android.db.PlaylistEntity
import at.least.crate.android.db.PlaylistItemEntity
import at.least.crate.android.db.CursorEntity
import at.least.crate.android.db.ScanErrorEntity
import at.least.crate.android.db.SyncStateEntity
import at.least.crate.android.db.TrackEntity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * PinManager（schema v0.3：內容定址下載層 + root-scoped 記錄層）的語意測試：
 * dedup、換庫休眠/重連、unpin GC、rev 重驗、legacy 搬遷。純 JVM——FakeDao 不經 Room。
 */
class PinManagerTest {

    /** 記憶體版 DAO（僅實作 PinManager 用到的面；其餘 no-op）。 */
    private class FakeDao : LibraryDao {
        val kv = mutableMapOf<String, String>()
        val pins = mutableMapOf<Pair<String, String>, PinEntity>() // (root, trackId)

        override suspend fun root() = kv["root"]
        override suspend fun allTracks(): List<TrackEntity> = emptyList()
        override suspend fun allPlaylists(): List<PlaylistEntity> = emptyList()
        override suspend fun allPlaylistItems(): List<PlaylistItemEntity> = emptyList()
        override suspend fun allErrors(): List<ScanErrorEntity> = emptyList()
        override suspend fun allCursor(): List<CursorEntity> = emptyList()
        override suspend fun insertTracks(xs: List<TrackEntity>) {}
        override suspend fun insertPlaylists(xs: List<PlaylistEntity>) {}
        override suspend fun insertPlaylistItems(xs: List<PlaylistItemEntity>) {}
        override suspend fun insertErrors(xs: List<ScanErrorEntity>) {}
        override suspend fun insertCursor(xs: List<CursorEntity>) {}
        override suspend fun upsertSyncState(x: SyncStateEntity) { kv[x.key] = x.value }
        override suspend fun clearTracks() {}
        override suspend fun clearPlaylists() {}
        override suspend fun clearErrors() {}
        override suspend fun clearCursor() {}
        override suspend fun allPins(root: String): List<PinEntity> =
            pins.values.filter { it.root == root }
        override suspend fun upsertPin(x: PinEntity) { pins[x.root to x.trackId] = x }
        override suspend fun deletePins(root: String, ids: List<String>) {
            ids.forEach { pins.remove(root to it) }
        }
        override suspend fun pinCountForHash(hash: String): Int =
            pins.values.count { it.contentHash == hash }
        override suspend fun clearPins() { pins.clear() }
    }

    private lateinit var dir: File
    private lateinit var dao: FakeDao
    private lateinit var pm: PinManager

    private val downloads get() = File(dir, "downloads")
    private fun downloadCount(): Int =
        downloads.listFiles()?.count { !it.name.startsWith("tmp-") } ?: -1

    @Before fun setUp() {
        dir = File.createTempFile("crate-pins", "").let { it.delete(); it.mkdirs(); it }
        dao = FakeDao()
    }

    @After fun tearDown() {
        dir.deleteRecursively()
    }

    // MARK: - helpers

    private fun makeRoot(name: String, vararg files: Pair<String, String>): File {
        val root = File(dir, name)
        for ((p, c) in files) {
            val f = File(root, p)
            f.parentFile?.mkdirs()
            f.writeText(c)
        }
        return root
    }

    private fun waitState(id: String, target: PinManager.PinState, timeoutMs: Long = 5000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (pm.pins.value[id] == target) return
            Thread.sleep(20)
        }
        throw AssertionError("pin $id 未達 $target：${pm.pins.value}")
    }

    private fun waitUntil(timeoutMs: Long = 5000, cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (cond()) return
            Thread.sleep(20)
        }
        throw AssertionError("條件未成立")
    }

    // MARK: - 內容定址：同一份檔案跨庫只抓一次

    @Test fun dedupSameContentAcrossLibraries() = runBlocking {
        val a = makeRoot("a", "x/01.flac" to "AAA")
        val b = makeRoot("b", "x/01.flac" to "AAA") // 同內容、同相對路徑（不同檔案系統物件）
        pm = PinManager(dao, dir)

        pm.setRoot(a)
        pm.pin(listOf(PinManager.PinReq("x/01.flac", "1:1")))
        waitState("x/01.flac", PinManager.PinState.DONE)
        assertEquals(1, downloadCount())

        pm.setRoot(b) // 換庫：b 視角沒有釘選（記錄屬於 a）
        assertNull(pm.pins.value["x/01.flac"])

        pm.pin(listOf(PinManager.PinReq("x/01.flac", "1:1"))) // b 也釘同一份 → dedup 命中
        waitState("x/01.flac", PinManager.PinState.DONE)
        assertEquals(1, downloadCount())

        val ra = dao.allPins(a.absolutePath).first()
        val rb = dao.allPins(b.absolutePath).first()
        assertEquals(ra.contentHash, rb.contentHash)
        assertEquals(2, dao.pinCountForHash(ra.contentHash!!))
        Unit
    }

    // MARK: - 換庫休眠：rows 與檔案都保留，切回即重連

    @Test fun switchLibraryDormantThenReattach() = runBlocking {
        val a = makeRoot("a", "x/01.flac" to "AAA")
        val b = makeRoot("b", "y/02.flac" to "BBB")
        pm = PinManager(dao, dir)

        pm.setRoot(a)
        pm.pin(listOf(PinManager.PinReq("x/01.flac", "1:1")))
        waitState("x/01.flac", PinManager.PinState.DONE)
        val f = pm.pinnedFile("x/01.flac")!!

        pm.setRoot(b) // 休眠：不清 rows、不刪檔案
        assertTrue(pm.pins.value.isEmpty()) // 顯示層單庫視角
        assertTrue(f.isFile)
        assertEquals(1, dao.allPins(a.absolutePath).size)

        pm.setRoot(a) // 切回：重連，DONE 立即恢復（不重抓）
        assertEquals(PinManager.PinState.DONE, pm.pins.value["x/01.flac"])
        assertEquals(f, pm.pinnedFile("x/01.flac"))
        assertEquals(1, downloadCount())
        Unit
    }

    // MARK: - unpin GC：跨庫共用（同 hash）者保留

    @Test fun unpinGarbageCollectsOnlyUnreferencedHash() = runBlocking {
        val a = makeRoot("a", "x/01.flac" to "AAA")
        val b = makeRoot("b", "x/01.flac" to "AAA")
        pm = PinManager(dao, dir)

        pm.setRoot(a)
        pm.pin(listOf(PinManager.PinReq("x/01.flac", "1:1")))
        waitState("x/01.flac", PinManager.PinState.DONE)
        pm.setRoot(b)
        pm.pin(listOf(PinManager.PinReq("x/01.flac", "1:1")))
        waitState("x/01.flac", PinManager.PinState.DONE)

        pm.unpin(listOf("x/01.flac")) // b 取消：a 仍引用同 hash → 檔案保留
        waitUntil { runBlocking { dao.allPins(b.absolutePath).isEmpty() } }
        assertEquals(1, downloadCount())

        pm.setRoot(a)
        pm.unpin(listOf("x/01.flac")) // a 也取消：無引用 → 刪檔
        waitUntil { runBlocking { dao.allPins(a.absolutePath).isEmpty() } }
        waitUntil { downloadCount() == 0 }
        Unit
    }

    // MARK: - rev 重驗：來源變了 → 重抓新內容、舊 hash 回收

    @Test fun revalidateRequeuesWhenRevChanges() = runBlocking {
        val a = makeRoot("a", "x/01.flac" to "AAA")
        pm = PinManager(dao, dir)

        pm.setRoot(a)
        pm.pin(listOf(PinManager.PinReq("x/01.flac", "1:1")))
        waitState("x/01.flac", PinManager.PinState.DONE)

        File(a, "x/01.flac").writeText("BBB")
        pm.revalidate(mapOf("x/01.flac" to "2:2")) // sync 後 rev 已變
        waitState("x/01.flac", PinManager.PinState.DONE)

        assertEquals("BBB", pm.pinnedFile("x/01.flac")!!.readText())
        assertEquals(1, downloadCount()) // 舊 hash 副本應被回收

        pm.revalidate(mapOf("x/01.flac" to "2:2")) // rev 未變 → 不重抓
        assertEquals(PinManager.PinState.DONE, pm.pins.value["x/01.flac"])
        Unit
    }

    // MARK: - revalidate 失敗不卡死：來源暫時消失 → FAILED，回來後同 rev 重試成功

    @Test fun revalidateRetriesAfterFailedRefetch() = runBlocking {
        val a = makeRoot("a", "x/01.flac" to "AAA")
        pm = PinManager(dao, dir)
        pm.setRoot(a)
        pm.pin(listOf(PinManager.PinReq("x/01.flac", "1:1")))
        waitState("x/01.flac", PinManager.PinState.DONE)

        File(a, "x/01.flac").delete()
        pm.revalidate(mapOf("x/01.flac" to "2:2")) // rev 變但來源消失 → FAILED（新 rev 未提交）
        waitState("x/01.flac", PinManager.PinState.FAILED)

        File(a, "x/01.flac").writeText("BBB")
        pm.revalidate(mapOf("x/01.flac" to "2:2")) // 同 rev —— 失敗殘留重試（pendingNewRevs）
        waitState("x/01.flac", PinManager.PinState.DONE)
        assertEquals("BBB", pm.pinnedFile("x/01.flac")!!.readText())
        Unit
    }

    // MARK: - 來源消失：FAILED

    @Test fun pinMissingSourceFails() = runBlocking {
        val a = makeRoot("a")
        pm = PinManager(dao, dir)
        pm.setRoot(a)
        pm.pin(listOf(PinManager.PinReq("nope/01.flac", "1:1")))
        waitState("nope/01.flac", PinManager.PinState.FAILED)
        Unit
    }

    // MARK: - v0.2 pins/ 搬遷：算 hash 改名，成為之後重釘的 dedup 命中

    @Test fun legacyPinsMigration() = runBlocking {
        val legacy = File(dir, "pins").apply { mkdirs() }
        File(legacy, "x%2F01.flac").writeText("LEGACY")

        pm = PinManager(dao, dir)
        waitUntil { !legacy.exists() } // 遷移在建構 coroutine 上非同步執行（不佔呼叫執行緒）
        assertEquals(1, downloadCount())
        val expected = MessageDigest.getInstance("SHA-256").digest("LEGACY".toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        assertTrue(File(downloads, expected).isFile)

        // 重釘同內容 → 落到同一份檔案
        val a = makeRoot("a", "x/01.flac" to "LEGACY")
        pm.setRoot(a)
        pm.pin(listOf(PinManager.PinReq("x/01.flac", "1:1")))
        waitState("x/01.flac", PinManager.PinState.DONE)
        assertEquals(1, downloadCount())
        Unit
    }
}
