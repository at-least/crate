package mu.core

/**
 * 同步引擎（sync-rules.md §3）：delta 變更 → 索引狀態。
 * 純邏輯狀態機；儲存形態是實作細節。契約輸出 SyncReport（canonical JSON）
 * 須與 Python 參考實作 byte-identical（sync_generate.py）。
 */
class SyncEngine(private val provider: LocalFolderProvider) {

    enum class Kind { ADDED, REMOVED, MODIFIED }

    data class SyncChange(val path: String, val kind: Kind, val rev: String)

    /** 索引軌：掃描資料（Scanner.Track）+ rev + available。 */
    data class IndexedTrack(val track: Scanner.Track, val rev: String, val available: Boolean)

    /** m3u8 raw（ref → trackId 在輸出時對 available 集合解析）。 */
    data class RawItem(val position: Int, val ref: String, val durationMs: Int?)
    data class RawPlaylist(val name: String, val items: List<RawItem>)

    data class SyncReport(
        val changes: List<SyncChange>,
        val scanned: List<String>,
        val tracks: Map<String, IndexedTrack>,     // path -> 索引軌
        val playlists: Map<String, RawPlaylist>,   // path -> raw
        val errors: Map<String, Scanner.ScanError>,// path -> error
    )

    private var cursor: Map<String, String>? = null
    private val tracks = LinkedHashMap<String, IndexedTrack>()
    private val playlists = LinkedHashMap<String, RawPlaylist>()
    private val errors = LinkedHashMap<String, Scanner.ScanError>()

    /** 匯出引擎狀態（App 層持久化用；儲存形態是實作細節——sync-rules §3）。 */
    fun exportState(): EngineState = EngineState(
        cursor?.let(::LinkedHashMap),
        LinkedHashMap(tracks), LinkedHashMap(playlists), LinkedHashMap(errors))

    /** 還原引擎狀態（冷啟動；restore 後 sync() 即為 delta——rev 未變不重讀）。 */
    fun restoreState(s: EngineState) {
        cursor = s.cursor?.let(::LinkedHashMap)
        tracks.clear(); tracks.putAll(s.tracks)
        playlists.clear(); playlists.putAll(s.playlists)
        errors.clear(); errors.putAll(s.errors)
    }

    /** 一輪同步。afterDelta：測試縫（delta 後、掃描前；模擬掃描中拔檔）。 */
    fun sync(afterDelta: (() -> Unit)? = null): SyncReport {
        val snap = provider.snapshot()
        val prev = cursor ?: emptyMap()
        val changes = ArrayList<SyncChange>()
        for (path in (snap.keys + prev.keys).toSortedSet()) {
            when {
                path !in prev -> changes.add(SyncChange(path, Kind.ADDED, snap.getValue(path)))
                path !in snap -> changes.add(SyncChange(path, Kind.REMOVED, prev.getValue(path)))
                snap.getValue(path) != prev.getValue(path) ->
                    changes.add(SyncChange(path, Kind.MODIFIED, snap.getValue(path)))
            }
        }
        val relevant = changes.filter {
            formatFor(it.path) != null || it.path.lowercase().endsWith(".m3u8")
        }

        val pending = ArrayList<SyncChange>()
        for (c in relevant) {
            if (c.kind == Kind.REMOVED) {
                tracks[c.path]?.let { tracks[c.path] = it.copy(available = false) }
                playlists.remove(c.path)
                errors.remove(c.path)
            } else {
                pending.add(c)
            }
        }
        afterDelta?.invoke()
        val scanned = ArrayList<String>()
        for (c in pending) {
            val data = provider.readBytes(c.path) ?: continue // §3.2-4 靜默丟棄
            scanned.add(c.path)
            if (c.path.lowercase().endsWith(".m3u8")) {
                playlists[c.path] = parseM3u8Raw(data.toString(Charsets.UTF_8), c.path)
                continue
            }
            val fmt = formatFor(c.path)!!
            val parsed = Scanner.parseTags(fmt, data)
            if (parsed == null) {
                tracks.remove(c.path)
                errors[c.path] = Scanner.ScanError("BAD_CONTAINER", c.path)
                continue
            }
            errors.remove(c.path)
            val (fields, tagOk) = parsed
            tracks[c.path] = IndexedTrack(
                Scanner.makeTrack(c.path, fmt, data.size.toLong(), fields, tagOk,
                    ContainerParsers.parseDuration(fmt, data)),
                rev = c.rev, available = true,
            )
        }
        cursor = snap
        return SyncReport(relevant, scanned, LinkedHashMap(tracks),
            LinkedHashMap(playlists), LinkedHashMap(errors))
    }

    /**
     * raw 清單 → 已解析音軌（App 層用；解析規則與 toCanonical 的 items 完全一致：
     * 相對 ref 對 playlist 所在目錄 join、normPath、只對 available 集合解析）。
     * 回傳 (playlistPath, 每項 trackId 或 null)。
     */
    fun resolvedItems(r: SyncReport): Map<String, List<String?>> {
        val audioOk = r.tracks.filterValues { it.available }.keys
        return r.playlists.mapValues { (p, pl) ->
            val base = p.substringBeforeLast('/', "")
            pl.items.map { raw ->
                var ref = raw.ref.replace('\\', '/')
                while (ref.startsWith("./")) ref = ref.substring(2)
                if (ref.startsWith("/")) null
                else {
                    val joined = if (base.isEmpty()) ref else "$base/$ref"
                    Scanner.normPath(joined)?.takeIf { it in audioOk }
                }
            }
        }
    }

    /** SyncReport → canonical map（sync-rules §3.3）。 */
    fun toCanonical(r: SyncReport): Map<String, Any?> {
        val audioOk = r.tracks.filterValues { it.available }.keys
        val tracksOut = r.tracks.keys.sorted().map { p ->
            val it = r.tracks.getValue(p)
            CanonicalJson.trackCanonical(it.track) + linkedMapOf<String, Any?>(
                "available" to it.available, "rev" to it.rev)
        }
        val playlistsOut = r.playlists.keys.sorted().map { p ->
            val pl = r.playlists.getValue(p)
            val base = p.substringBeforeLast('/', "")
            val items = pl.items.map { raw ->
                var ref = raw.ref.replace('\\', '/')
                while (ref.startsWith("./")) ref = ref.substring(2)
                var trackId: String? = null
                if (!ref.startsWith("/")) {
                    val joined = if (base.isEmpty()) ref else "$base/$ref"
                    Scanner.normPath(joined)?.let { res ->
                        if (res in audioOk) trackId = res
                    }
                }
                linkedMapOf<String, Any?>(
                    "durationMs" to raw.durationMs,
                    "missing" to (trackId == null),
                    "position" to raw.position,
                    "ref" to raw.ref,
                    "trackId" to trackId,
                )
            }
            linkedMapOf<String, Any?>(
                "id" to p, "items" to items, "name" to pl.name, "path" to p)
        }
        val albums = Scanner.groupAlbums(r.tracks.keys.sorted().map { r.tracks.getValue(it).track })
            .sortedWith(compareBy({ it.albumArtist }, { it.name }))
            .map { it.toCanonicalMap() }
        val errorsOut = r.errors.keys.sorted().map { CanonicalJson.errorCanonical(r.errors.getValue(it)) }
        val changesOut = r.changes
            .sortedWith(compareBy<SyncChange>({ it.path }, { it.kind.name }))
            .map { c ->
                linkedMapOf<String, Any?>(
                    "kind" to c.kind.jsonName, "path" to c.path, "rev" to c.rev)
            }
        return linkedMapOf(
            "changes" to changesOut,
            "scanned" to r.scanned.sorted(),
            "index" to linkedMapOf<String, Any?>(
                "albums" to albums, "errors" to errorsOut,
                "playlists" to playlistsOut, "tracks" to tracksOut),
        )
    }

    /** m3u8 raw 解析（model.md §2.3；不解析 trackId）。 */
    internal fun parseM3u8Raw(text0: String, rel: String): RawPlaylist {
        val text = text0.dropWhile { it == '\uFEFF' }
        val items = ArrayList<RawItem>()
        var pendingDur: Int? = null
        for (line0 in text.replace("\r\n", "\n").split('\n')) {
            val line = line0.trim()
            if (line.isEmpty()) continue
            if (line.startsWith("#")) {
                if (line.startsWith("#EXTINF:")) {
                    pendingDur = Scanner.extinfToMs(
                        line.substring("#EXTINF:".length).substringBefore(','))
                }
                continue
            }
            var ref = line.replace('\\', '/')
            while (ref.startsWith("./")) ref = ref.substring(2)
            items.add(RawItem(items.size, ref, pendingDur))
            pendingDur = null
        }
        val name = rel.substringAfterLast('/')
        return RawPlaylist(name.substring(0, name.length - 5), items)
    }

    private val Kind.jsonName: String
        get() = when (this) {
            Kind.ADDED -> "added"
            Kind.REMOVED -> "removed"
            Kind.MODIFIED -> "modified"
        }
}

private fun Scanner.Album.toCanonicalMap(): Map<String, Any?> = linkedMapOf(
    "albumArtist" to albumArtist,
    "artTrackId" to artTrackId,
    "compilation" to compilation,
    "id" to id,
    "name" to name,
    "trackCount" to trackCount,
    "year" to year,
)

/** 引擎持久化狀態：cursor（provider 快照）+ 三張索引表。 */
data class EngineState(
    val cursor: Map<String, String>?,               // null = 尚未同步過
    val tracks: Map<String, SyncEngine.IndexedTrack>,
    val playlists: Map<String, SyncEngine.RawPlaylist>,
    val errors: Map<String, Scanner.ScanError>,
)
