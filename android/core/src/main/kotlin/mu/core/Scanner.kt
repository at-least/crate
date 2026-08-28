package mu.core

import java.io.File

/** 掃描器（model.md §1–§2）：同輸入樹 → byte-identical canonical JSON。 */
object Scanner {

    data class Track(
        val album: String, val albumArtist: String, val albumId: String,
        val artist: String, val disc: Int, val format: String, val id: String,
        val path: String, val sizeBytes: Long, val tagOk: Boolean,
        val title: String, val trackNo: Int?, val year: Int?,
        val compilation: Boolean, val durationMs: Long?,
    )

    data class Album(
        val albumArtist: String, val artTrackId: String?, val compilation: Boolean,
        val id: String, val name: String, val trackCount: Int, val year: Int?,
    )

    data class PlaylistItem(
        val durationMs: Int?, val missing: Boolean, val position: Int,
        val ref: String, val trackId: String?,
    )

    data class Playlist(
        val id: String, val items: List<PlaylistItem>, val name: String, val path: String,
    )

    data class ScanError(val code: String, val path: String)

    data class ScanResult(
        val albums: List<Album>, val errors: List<ScanError>,
        val playlists: List<Playlist>, val tracks: List<Track>,
    )

    const val UNKNOWN_ARTIST = "<Unknown Artist>"
    const val NO_ALBUM = "<No Album>"
    private val FILENAME_PAT = Regex("^(\\d{1,3})\\s-\\s(.+)$")

    fun scan(root: File): ScanResult {
        val files = root.walkTopDown()
            .filter { it.isFile }
            .map { it.relativeTo(root).invariantSeparatorsPath }
            .toList()

        val tracks = ArrayList<Track>()
        val errors = ArrayList<ScanError>()
        val playlists = ArrayList<Playlist>()
        val audioPaths = HashSet<String>()

        for (rel in files) {
            if (rel.lowercase().endsWith(".m3u8")) continue
            if (formatFor(rel) != null) audioPaths.add(rel)
        }

        for (rel in files) {
            if (rel.lowercase().endsWith(".m3u8")) {
                playlists.add(parseM3u8(File(root, rel), rel, audioPaths))
                continue
            }
            val fmt = formatFor(rel) ?: continue
            val r = ChunkedReader(FileSource.open(File(root, rel)) ?: continue)
            val parsed = parseTags(fmt, r)
            if (parsed == null) {
                errors.add(ScanError("BAD_CONTAINER", rel))
            } else {
                val (fields, tagOk) = parsed
                tracks.add(makeTrack(rel, fmt, r.size, fields, tagOk,
                    ContainerParsers.parseDuration(fmt, r)))
            }
        }
        return ScanResult(
            albums = groupAlbums(tracks).sortedWith(
                compareBy({ it.albumArtist }, { it.name })
            ),
            errors = errors.sortedBy { it.path },
            playlists = playlists.sortedBy { it.path },
            tracks = tracks.sortedWith(compareBy { it.path }),
        )
    }

    /** 陣列 API（測試相容）。 */
    internal fun parseTags(fmt: String, data: ByteArray): Pair<TagFields, Boolean>? =
        parseTags(fmt, ChunkedReader(data))

    /** null = BAD_CONTAINER。回傳 (欄位, 是否有任何可用 tag)。 */
    internal fun parseTags(fmt: String, r: ChunkedReader): Pair<TagFields, Boolean>? {
        val tags: Map<String, String>? = when (fmt) {
            "flac" -> ContainerParsers.flacTags(r)
            "mp3" -> Id3Parser.parse(r) ?: run {
                val b = r.bytes(0, 2)
                if (b.size >= 2 && b[0].toInt() and 0xFF == 0xFF && b[1].toInt() and 0xE0 == 0xE0)
                    linkedMapOf() else null
            }
            "m4a" -> ContainerParsers.m4aTags(r)
            "ogg", "opus" -> ContainerParsers.oggTags(r)
            "wav" -> if (ContainerParsers.isWav(r)) linkedMapOf() else null
            else -> null
        }
        if (tags == null) return null
        return TagNormalize.from(tags) to tags.isNotEmpty()
    }

    internal fun makeTrack(
        rel: String, fmt: String, size: Long,
        fields: TagFields?, tagOkRaw: Boolean,
        durationMs: Long? = null,
    ): Track {
        val segs = rel.split('/')
        val fname = segs.last()
        val stem = if (fname.contains('.')) fname.substringBeforeLast('.') else fname
        var fbTitle = stem
        var fbTrackNo: Int? = null
        FILENAME_PAT.find(stem)?.let { m ->
            fbTrackNo = m.groupValues[1].dropWhile { it == '0' }.ifEmpty { "0" }.toInt()
            fbTitle = m.groupValues[2]
        }
        val fbAlbumArtist = if (segs.size >= 3) segs[0] else UNKNOWN_ARTIST
        val fbAlbum = if (segs.size >= 2) segs[segs.size - 2] else NO_ALBUM
        val f = fields ?: TagNormalize.from(emptyMap())

        val artist = f.artist ?: f.albumArtist ?: fbAlbumArtist
        val albumArtist = f.albumArtist ?: f.artist ?: fbAlbumArtist
        val album = f.album ?: fbAlbum
        val title = f.title ?: fbTitle
        val trackNo = f.trackNo ?: fbTrackNo
        val ok = tagOkRaw && (f.title != null || f.artist != null ||
            f.album != null || f.albumArtist != null)
        val compilation = f.compilation || albumArtist.lowercase() == "various artists"

        return Track(
            album = album, albumArtist = albumArtist,
            albumId = "alb|$albumArtist|$album",
            artist = artist, disc = f.disc ?: 1, format = fmt, id = rel, path = rel,
            sizeBytes = size, tagOk = ok, title = title, trackNo = trackNo,
            year = f.year, compilation = compilation, durationMs = durationMs,
        )
    }

    fun groupAlbums(tracks: List<Track>): List<Album> =
        tracks.groupBy { it.albumId }.map { (_, ts) ->
            val sorted = ts.sortedWith(compareBy { it.path })
            Album(
                albumArtist = sorted[0].albumArtist,
                artTrackId = sorted.firstOrNull { it.tagOk }?.id,
                compilation = sorted.any { it.compilation },
                id = sorted[0].albumId, name = sorted[0].album,
                trackCount = sorted.size,
                year = sorted.firstOrNull { it.year != null }?.year,
            )
        }

    private fun parseM3u8(file: File, rel: String, audioPaths: Set<String>): Playlist {
        val text = file.readBytes().toString(Charsets.UTF_8).dropWhile { it == '\uFEFF' }
        val base = rel.substringBeforeLast('/', "")
        var pendingDur: Int? = null
        val items = ArrayList<PlaylistItem>()
        for (line0 in text.replace("\r\n", "\n").split('\n')) {
            val line = line0.trim()
            if (line.isEmpty()) continue
            if (line.startsWith("#")) {
                if (line.startsWith("#EXTINF:")) {
                    pendingDur = extinfToMs(line.substring("#EXTINF:".length)
                        .substringBefore(','))
                }
                continue
            }
            var ref = line.replace('\\', '/')
            while (ref.startsWith("./")) ref = ref.substring(2)
            var trackId: String? = null
            if (!ref.startsWith("/")) {
                val joined = if (base.isEmpty()) ref else "$base/$ref"
                val resolved = normPath(joined)
                if (resolved != null && resolved in audioPaths) trackId = resolved
            }
            items.add(PlaylistItem(pendingDur, trackId == null, items.size, ref, trackId))
            pendingDur = null
        }
        val name = rel.substringAfterLast('/')
        return Playlist(rel, items, name.substring(0, name.length - 5), rel)
    }

    /** 無浮點 EXTINF 秒→毫秒（model.md §2.3）。非法 → null。 */
    fun extinfToMs(s: String): Int? {
        val t = s.trim()
        if (t.isEmpty()) return null
        val neg = t.startsWith("-")
        val body = if (neg) t.substring(1) else t
        val ip = body.substringBefore('.', body)
        val fp = if (body.contains('.')) body.substringAfter('.') else ""
        if (ip.isNotEmpty() && !ip.all { it.isDigit() }) return null
        if (fp.isNotEmpty() && !fp.all { it.isDigit() }) return null
        val ipV = if (ip.isEmpty()) 0L else ip.toLong()
        val fpV = (fp + "000").take(3).ifEmpty { "000" }.toLong()
        val v = ipV * 1000 + fpV
        return (if (neg) -v else v).let { if (it > Int.MAX_VALUE || it < Int.MIN_VALUE) null else it.toInt() }
    }

    /** 摺疊 `.`/`..`；出界（前綴 ..）→ null。 */
    fun normPath(p: String): String? {
        val out = ArrayList<String>()
        for (seg in p.split('/')) {
            when (seg) {
                "", "." -> {}
                ".." -> if (out.isEmpty()) return null else out.removeAt(out.size - 1)
                else -> out.add(seg)
            }
        }
        return out.joinToString("/")
    }
}
