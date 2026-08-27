package mu.core

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * EngineState export/restore 往返（sync-rules §3：儲存形態是實作細節）。
 * 冷啟動還原后 sync() 必須是 delta——rev 未變的檔案不重讀。
 */
class EngineStateTest {

    @Test
    fun `restore round trip skips unchanged files and catches real deltas`() {
        val assetsDir = findDir("contract/fixtures/sync_assets") ?: fail("sync_assets not found")
        val tmp = createTempDirectory("mu-state-").toFile()
        try {
            val root = File(tmp, "lib").apply { mkdirs() }
            fun writeAsset(rel: String, asset: String, mtimeSec: Long) {
                val p = File(root, rel).apply { parentFile?.mkdirs() }
                p.writeBytes(File(assetsDir, asset).readBytes())
                p.setLastModified(mtimeSec * 1000)
            }
            writeAsset("A/a1.flac", "flac_a", 100)
            writeAsset("A/a2.flac", "flac_b", 100)
            val pl = File(root, "lists/favorites.m3u8").apply { parentFile?.mkdirs() }
            pl.writeBytes("#EXTM3U\n#EXTINF:10,First\n../A/a1.flac\n".toByteArray(Charsets.UTF_8))
            pl.setLastModified(100 * 1000)

            // 首掃
            val e1 = SyncEngine(LocalFolderProvider(root))
            val r1 = e1.sync()
            assertTrue(r1.scanned.isNotEmpty(), "first scan should read files")

            // 匯出 → 新引擎（模擬重啟）→ 還原 → delta：零變更零重讀
            val state = e1.exportState()
            assertTrue(state.cursor != null, "cursor exported")
            val e2 = SyncEngine(LocalFolderProvider(root))
            e2.restoreState(state)
            val r2 = e2.sync()
            assertTrue(r2.changes.isEmpty(), "no changes after restore, got ${r2.changes}")
            assertTrue(r2.scanned.isEmpty(), "no rescans after restore, got ${r2.scanned}")
            assertEquals(r1.tracks, r2.tracks)
            assertEquals(r1.playlists, r2.playlists)
            assertEquals(r1.errors, r2.errors)

            // 改一個檔的 mtime（rev 變）→ 只重掃該檔
            val touched = File(root, "A/a2.flac")
            touched.setLastModified(999 * 1000)
            val r3 = e2.sync()
            assertEquals(listOf(SyncEngine.SyncChange("A/a2.flac", SyncEngine.Kind.MODIFIED, touched.rev())),
                r3.changes)
            assertEquals(listOf("A/a2.flac"), r3.scanned)
        } finally {
            tmp.deleteRecursively()
        }
    }

    private fun File.rev(): String = "${length()}:${lastModified()}"

    private fun findDir(rel: String): File? {
        var dir = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val c = File(dir, rel)
            if (c.isDirectory) return c
            dir = dir.parentFile
        }
        return null
    }
}
