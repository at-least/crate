package music.mu.android

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import music.mu.android.db.LibraryDao
import music.mu.android.db.PinEntity
import java.io.File

/**
 * 釘選離線（schema.sql pins 表的狀態機）：pin → 檔案複製到 filesDir/pins/ →
 * 來源消失後仍可由 [pinnedFile] 播放。循序佇列；本地 provider = File 複製，
 * 雲端 provider 進場時換 provider.download，語意不變（provider.md §1）。
 */
class PinManager(private val dao: LibraryDao, filesDir: File) {

    enum class PinState { WANTED, DOWNLOADING, DONE, FAILED }

    private val pinsDir = File(filesDir, "pins").apply { mkdirs() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()

    private val _pins = MutableStateFlow<Map<String, PinState>>(emptyMap())
    val pins: StateFlow<Map<String, PinState>> = _pins

    private var root: File? = null
    private val pumping = java.util.concurrent.atomic.AtomicBoolean(false)

    init {
        scope.launch {
            mutex.withLock {
                // 行程中斷殘留的 DOWNLOADING 重置為 WANTED，自動續傳
                val rows = dao.allPins()
                val states = rows.associate { it.trackId to pinStateOf(it.state) }
                for ((id, st) in states) {
                    if (st == PinState.DOWNLOADING) {
                        dao.upsertPin(PinEntity(id, System.currentTimeMillis(), PinState.WANTED.name))
                    }
                }
                _pins.value = states.mapValues { (id, st) ->
                    if (st == PinState.DOWNLOADING) PinState.WANTED else st
                }
            }
            pump()
        }
    }

    /**
     * 換庫 = 清釘選（單庫語意）；同庫冷啟動 = 接回 root，不清。
     * 以 DB 持久化的 root 判斷（syncLocked 在 replaceLibrary 之前呼叫，此時 DB 仍是舊 root）。
     */
    suspend fun setRoot(newRoot: File) {
        mutex.withLock {
            if (root?.absolutePath == newRoot.absolutePath) return@withLock
            val persisted = dao.root()
            if (persisted != null && persisted == newRoot.absolutePath) {
                root = newRoot // 同庫重開：釘選保留
                return@withLock
            }
            root = newRoot
            dao.clearPins()
            pinsDir.listFiles()?.forEach { it.delete() }
            _pins.value = emptyMap()
        }
        pump()
    }

    fun pin(trackIds: List<String>) {
        if (trackIds.isEmpty()) return
        scope.launch {
            mutex.withLock {
                val now = System.currentTimeMillis()
                // DONE 且檔案在 → 跳過：重釘整張專輯（新增軌）不得把已離線的軌打成 WANTED
                //（來源已消失的軌重跑會 FAILED，等於弄丟離線副本）
                val queue = trackIds.filter { id ->
                    _pins.value[id] != PinState.DONE || !fileFor(id).isFile
                }
                queue.forEach { dao.upsertPin(PinEntity(it, now, PinState.WANTED.name)) }
                _pins.value = _pins.value + queue.associateWith { PinState.WANTED }
            }
            pump()
        }
    }

    fun unpin(trackIds: List<String>) {
        if (trackIds.isEmpty()) return
        scope.launch {
            mutex.withLock {
                dao.deletePins(trackIds)
                _pins.value = _pins.value - trackIds.toSet()
                trackIds.forEach { fileFor(it).delete() }
            }
        }
    }

    /** 釘選完成且檔案在 → 副本檔案；否則 null。同步呼叫（播放解析用）。 */
    fun pinnedFile(trackId: String): File? {
        if (_pins.value[trackId] != PinState.DONE) return null
        val f = fileFor(trackId)
        return if (f.isFile) f else null
    }

    /** 消費 WANTED → 複製 → DONE/FAILED。單一 worker 循序執行（對雲端友善）。 */
    private suspend fun pump() {
        if (!pumping.compareAndSet(false, true)) return
        try {
            while (true) {
                val next = mutex.withLock {
                    val entry = _pins.value.entries.firstOrNull { it.value == PinState.WANTED }
                        ?: return@withLock null
                    val r = root ?: return@withLock null
                    setState(entry.key, PinState.DOWNLOADING)
                    entry.key to File(r, entry.key)
                } ?: break
                val (id, src) = next
                val dst = fileFor(id)
                val ok = try {
                    dst.parentFile?.mkdirs()
                    if (src.isFile) {
                        src.copyTo(dst, overwrite = true)
                        true
                    } else false
                } catch (_: Exception) {
                    false
                }
                mutex.withLock {
                    // 複製期間被 unpin → 狀態已移除，不回寫
                    if (_pins.value[id] == PinState.DOWNLOADING) {
                        setState(id, if (ok) PinState.DONE else PinState.FAILED)
                    }
                }
            }
        } finally {
            pumping.set(false)
        }
    }

    /** 需持有 [mutex] 呼叫。 */
    private suspend fun setState(trackId: String, state: PinState) {
        dao.upsertPin(PinEntity(trackId, System.currentTimeMillis(), state.name))
        _pins.value = _pins.value + (trackId to state)
    }

    private fun fileFor(trackId: String): File =
        File(pinsDir, trackId.replace("%", "%25").replace("/", "%2F"))

    private fun pinStateOf(s: String): PinState =
        PinState.entries.firstOrNull { it.name == s } ?: PinState.FAILED
}
