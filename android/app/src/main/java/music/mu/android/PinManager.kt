package music.mu.android

import kotlinx.coroutines.CompletableDeferred
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
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 釘選離線（schema.sql v0.3 pins 狀態機 + 內容定址下載層，D13）：
 * - 下載層：downloads/<sha256>——bytes 相同 = 同一份副本，跨庫共用、只抓一次；
 *   換庫不清（休眠），unpin 時無其他 pin 引用同 hash 才刪檔。
 * - 記錄層：pins 按 (root, trackId)——釘選意圖屬於庫；pins flow 只含當前 root（顯示單庫視角）。
 * - 重驗：sync 後以 rev 比對（revalidate），rev 變 → 重抓（內容 hash 即終極 rev）。
 * 本地 provider = 邊複製邊算 SHA-256（零額外 IO）；雲端 provider 進場時換 provider.download，
 * 語意不變（provider.md §1/§7）。
 */
class PinManager(private val dao: LibraryDao, filesDir: File) {

    enum class PinState { WANTED, DOWNLOADING, DONE, FAILED }

    data class PinReq(val trackId: String, val rev: String)

    private val downloadsDir = File(filesDir, "downloads").apply { mkdirs() }
    private val legacyPinsDir = File(filesDir, "pins")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()

    private val _pins = MutableStateFlow<Map<String, PinState>>(emptyMap())
    val pins: StateFlow<Map<String, PinState>> = _pins

    // 僅當前 root（顯示單庫視角）。寫入一律持 [mutex]；pinnedFile 從播放執行緒點讀——ConcurrentHashMap
    private val hashes = ConcurrentHashMap<String, String>()  // trackId → 副本 SHA-256（done 軌）
    private val revs = ConcurrentHashMap<String, String>()    // trackId → 已提交的 rev（抓成功才更新）
    /** revalidate 重抓的目標 rev——成功才提交進 revs；失敗則留下次 sync 重試（不卡死 FAILED）。 */
    private val pendingNewRevs = ConcurrentHashMap<String, String>()

    @Volatile private var root: File? = null
    private val pumping = AtomicBoolean(false)

    /** init 的初始載入完成前，setRoot/pin/unpin/revalidate 等待（避免覆蓋競態）。 */
    private val initialized = CompletableDeferred<Unit>()

    init {
        scope.launch {
            migrateLegacyPins() // 檔案搬遷（hash 舊檔）——不佔建構執行緒
            mutex.withLock {
                dao.root()?.let { persisted ->
                    root = File(persisted)
                    loadLocked(persisted) // 行程中斷殘留的 DOWNLOADING 重置為 WANTED，自動續傳
                }
            }
            initialized.complete(Unit)
            pump()
        }
    }

    /**
     * 換庫 = 記錄休眠（不清 rows、不刪檔案）；同庫冷啟動 = 保留。
     * 換到的庫若有自己的 rows → 重連（切回舊庫即離線可用，不重抓）。
     * 以 DB 持久化的 root 判斷（syncLocked 在 replaceLibrary 之前呼叫，此時 DB 仍是舊 root）。
     */
    suspend fun setRoot(newRoot: File) {
        initialized.await()
        mutex.withLock {
            if (root?.absolutePath == newRoot.absolutePath) return@withLock
            val persisted = dao.root()
            root = newRoot
            if (persisted == null || persisted != newRoot.absolutePath) {
                loadLocked(newRoot.absolutePath) // 換庫：載入新庫 rows（他庫休眠）
            } // 同庫重開：init 已載入
        }
        scope.launch { pump() } // 不阻塞 sync 管線等整批下載（旗標保證單一 worker）
    }

    fun pin(reqs: List<PinReq>) {
        if (reqs.isEmpty()) return
        val rootPath = root?.absolutePath ?: return // 呼叫時點的庫（換庫搶先則不誤寫新庫）
        scope.launch {
            initialized.await()
            mutex.withLock {
                // DONE 且副本在 → 跳過：重釘整張專輯（新增軌）不得把已離線的軌打成 WANTED
                //（來源已消失的軌重跑會 FAILED，等於弄丟離線副本）
                val queue = reqs.filter { r ->
                    _pins.value[r.trackId] != PinState.DONE || pinnedFileLocked(r.trackId) == null
                }
                if (queue.isEmpty()) return@withLock
                val now = System.currentTimeMillis()
                for (r in queue) {
                    revs[r.trackId] = r.rev
                    pendingNewRevs.remove(r.trackId)
                    dao.upsertPin(PinEntity(rootPath, r.trackId, hashes[r.trackId], r.rev, now, PinState.WANTED.name))
                }
                _pins.value = _pins.value + queue.associate { it.trackId to PinState.WANTED }
            }
            pump()
        }
    }

    fun unpin(trackIds: List<String>) {
        if (trackIds.isEmpty()) return
        val rootPath = root?.absolutePath ?: return // 呼叫時點的庫
        scope.launch {
            initialized.await()
            mutex.withLock {
                val affected = trackIds.mapNotNull { hashes[it] }.toSet()
                dao.deletePins(rootPath, trackIds)
                trackIds.forEach {
                    hashes.remove(it)
                    revs.remove(it)
                    pendingNewRevs.remove(it)
                }
                _pins.value = _pins.value - trackIds.toSet()
                // GC：跨庫共用（同 hash 他釘）者保留
                for (h in affected) if (dao.pinCountForHash(h) == 0) File(downloadsDir, h).delete()
            }
        }
    }

    /** 釘選完成且副本在 → 副本檔案；否則 null。同步呼叫（播放解析用）。 */
    fun pinnedFile(trackId: String): File? = pinnedFileLocked(trackId)

    /** sync 後重驗（syncLocked 呼叫）：done 且來源 rev 已變 → 重抓。不在索引的軌（來源消失／B5）不動。 */
    suspend fun revalidate(currentRevs: Map<String, String>) {
        initialized.await()
        mutex.withLock {
            val rootPath = root?.absolutePath ?: return@withLock
            val doneChanged = _pins.value.entries
                .filter { it.value == PinState.DONE }
                .mapNotNull { (id, _) -> currentRevs[id]?.takeIf { it != revs[id] }?.let { id } }
            // 上次 revalidate 觸發的重抓失敗 → 重試（revs 仍是舊值，同 rev 也會再進場）
            val retry = _pins.value.entries
                .filter { it.value == PinState.FAILED && pendingNewRevs.containsKey(it.key) }
                .map { it.key }
            val refresh = (doneChanged + retry).toSet()
            if (refresh.isEmpty()) return@withLock
            for (id in refresh) {
                currentRevs[id]?.let { pendingNewRevs[id] = it }
                // revs 維持舊值：抓成功才提交新 rev
                dao.upsertPin(PinEntity(rootPath, id, hashes[id], revs[id] ?: "",
                    System.currentTimeMillis(), PinState.WANTED.name))
            }
            _pins.value = _pins.value + refresh.associateWith { PinState.WANTED }
        }
        scope.launch { pump() } // 不阻塞 sync 管線等整批下載
    }

    // MARK: - 佇列段

    /** 需持有 [mutex] 呼叫。 */
    private suspend fun loadLocked(rootPath: String) {
        hashes.clear()
        revs.clear()
        pendingNewRevs.clear()
        val map = mutableMapOf<String, PinState>()
        for (row in dao.allPins(rootPath)) {
            var st = pinStateOf(row.state)
            if (st == PinState.DOWNLOADING) {
                st = PinState.WANTED
                // 殘留重置保留 contentHash：崩潰後舊副本檔案仍可被 GC/unpin 追蹤
                dao.upsertPin(row.copy(state = PinState.WANTED.name))
            }
            map[row.trackId] = st
            row.contentHash?.let { hashes[row.trackId] = it }
            revs[row.trackId] = row.rev
        }
        _pins.value = map
    }

    /** 消費 WANTED → 複製＋SHA-256 → downloads/<hash> → DONE/FAILED。
     *  單一 worker 循序執行（對雲端友善）；外層迴圈為丟失喚醒防護——放旗後仍有 WANTED 則再進場。 */
    private suspend fun pump() {
        if (!pumping.compareAndSet(false, true)) return
        outer@ while (true) {
            try {
                while (true) {
                    val next = mutex.withLock {
                        val entry = _pins.value.entries.firstOrNull { it.value == PinState.WANTED }
                            ?: return@withLock null
                        val r = root ?: return@withLock null // 無 root → 不標 DOWNLOADING，收工
                        setStateLocked(entry.key, PinState.DOWNLOADING)
                        entry.key to File(r, entry.key)
                    } ?: break
                    val (id, src) = next
                    val hash = fetch(src)
                    mutex.withLock {
                        // 抓取期間被 unpin/換庫 → 狀態已移除，不回寫
                        if (_pins.value[id] == PinState.DOWNLOADING) {
                            val oldHash = hashes[id]
                            if (hash != null) {
                                hashes[id] = hash
                                // revalidate 觸發的重抓：成功才提交新 rev（失敗留下次 sync 重試）
                                pendingNewRevs.remove(id)?.let { revs[id] = it }
                                setStateLocked(id, PinState.DONE)
                                if (!File(downloadsDir, hash).isFile) {
                                    // 完成瞬間被併發刪除（unpin 的 GC 競態）→ 重排重抓
                                    setStateLocked(id, PinState.WANTED)
                                }
                            } else {
                                setStateLocked(id, PinState.FAILED)
                            }
                            // 重抓（rev 變）替換 hash 後，舊 hash 已無本軌引用——他庫也沒引用才刪
                            if (oldHash != null && oldHash != hash && dao.pinCountForHash(oldHash) == 0) {
                                File(downloadsDir, oldHash).delete()
                            }
                        }
                    }
                }
            } finally {
                pumping.set(false)
            }
            // 丟失喚醒防護：放旗與新 WANTED 之間的空窗——重檢一次（搶不到旗表示有別的 worker 接手）
            if (_pins.value.values.none { it == PinState.WANTED }) return
            if (!pumping.compareAndSet(false, true)) return
        }
    }

    /** 需持有 [mutex] 呼叫。 */
    private suspend fun setStateLocked(trackId: String, state: PinState) {
        root?.absolutePath?.let {
            dao.upsertPin(
                PinEntity(it, trackId, hashes[trackId], revs[trackId] ?: "",
                    System.currentTimeMillis(), state.name))
        }
        _pins.value = _pins.value + (trackId to state)
    }

    private fun pinnedFileLocked(trackId: String): File? {
        if (_pins.value[trackId] != PinState.DONE) return null
        val h = hashes[trackId] ?: return null
        val f = File(downloadsDir, h)
        return if (f.isFile) f else null
    }

    // MARK: - 下載層（內容定址）

    /** 複製並計算 SHA-256 → downloads/<hash>；同內容已有副本 = dedup 命中（直接沿用）。
     *  回傳 hash hex（來源消失/IO 失敗 = null）。走暫存檔——半途中斷不留損毀副本。 */
    private fun fetch(src: File): String? {
        if (!src.isFile) return null
        val tmp = File(downloadsDir, "tmp-${UUID.randomUUID()}")
        try {
            val md = MessageDigest.getInstance("SHA-256")
            src.inputStream().use { input ->
                tmp.outputStream().use { output ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        if (n > 0) {
                            md.update(buf, 0, n)
                            output.write(buf, 0, n)
                        }
                    }
                }
            }
            val hex = md.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
            val dst = File(downloadsDir, hex)
            if (dst.isFile) {
                tmp.delete() // dedup 命中
            } else if (!tmp.renameTo(dst)) {
                tmp.delete()
                return null
            }
            return hex
        } catch (_: Exception) {
            tmp.delete()
            return null
        }
    }

    /** v0.2 的 pins/（trackId 為檔名）→ 內容定址搬遷：算 hash 改名；之後重釘同內容直接命中。 */
    private fun migrateLegacyPins() {
        val files = legacyPinsDir.listFiles() ?: return
        for (f in files) {
            val h = sha256File(f) ?: continue
            val dst = File(downloadsDir, h)
            if (dst.isFile) f.delete() else f.renameTo(dst)
        }
        legacyPinsDir.delete()
    }

    private fun sha256File(f: File): String? = try {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                if (n > 0) md.update(buf, 0, n)
            }
        }
        md.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    } catch (_: Exception) {
        null
    }

    private fun pinStateOf(s: String): PinState =
        PinState.entries.firstOrNull { it.name == s } ?: PinState.FAILED
}
