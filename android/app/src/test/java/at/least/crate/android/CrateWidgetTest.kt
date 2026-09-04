package at.least.crate.android

import crate.core.NowPlayingSnapshot
import org.junit.Assert.assertEquals
import org.junit.Test

/** Widget 顯示字串（model.md §1.11 的消費端；顯示狀態/位置推算由 :core 契約測試涵蓋）。 */
class CrateWidgetTest {

    private val base = NowPlayingSnapshot.create(
        trackId = "A/B/01.flac", title = "Rise", artist = "Aurora",
        isPlaying = true, positionMs = 83_000, durationMs = 213_000,
        updatedAtMs = 1_700_000_000_000,
    )

    @Test
    fun `playing shows advanced position and duration`() {
        val now = 1_700_000_010_000 // +10s
        assertEquals(
            "▶ 1:33 / 3:33",
            CrateWidget.progressLabel(base, now, base.displayState(now)),
        )
    }

    @Test
    fun `paused keeps stored position`() {
        val paused = base.copy(isPlaying = false)
        val now = 1_700_000_600_000
        assertEquals("⏸ 1:23 / 3:33", CrateWidget.progressLabel(paused, now, paused.displayState(now)))
    }

    @Test
    fun `no duration omits total`() {
        val noDur = base.copy(durationMs = null)
        val now = 1_700_000_000_000
        assertEquals("▶ 1:23", CrateWidget.progressLabel(noDur, now, noDur.displayState(now)))
    }

    @Test
    fun `position clamps to duration`() {
        val now = 1_700_000_600_000 // +600s，超過時長
        assertEquals("▶ 3:33 / 3:33", CrateWidget.progressLabel(base, now, base.displayState(now)))
    }
}
