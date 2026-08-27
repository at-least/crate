package music.mu.android.db

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Transaction
import mu.core.EngineState
import mu.core.Scanner
import mu.core.SyncEngine

/**
 * 音樂庫索引 DB（contract/schema.sql v0.2 的 Room 化）。
 * 單庫語意：replaceLibrary 全量置換（換資料夾 = 換庫）；
 * trackId 不落庫（ref 輸出時解析——sync-rules §3.2-5）；albums 派生不落庫（§3.2-6）。
 */

@Entity(tableName = "tracks")
data class TrackEntity(
    @PrimaryKey val id: String,          // = path（model.md §2.1 慣例）
    val path: String,
    val title: String,
    val artist: String,
    val album: String,
    val albumArtist: String,
    val albumId: String,
    val disc: Int,
    val trackNo: Int?,
    val year: Int?,
    val compilation: Boolean,
    val durationMs: Long?,
    val format: String,
    val sizeBytes: Long,
    val bitrateKbps: Int?,               // v0 恆 null（schema 保留欄位）
    val rev: String,
    val tagOk: Boolean,
    val available: Boolean,
) {
    constructor(it: SyncEngine.IndexedTrack) : this(
        id = it.track.id, path = it.track.path,
        title = it.track.title, artist = it.track.artist,
        album = it.track.album, albumArtist = it.track.albumArtist,
        albumId = it.track.albumId, disc = it.track.disc,
        trackNo = it.track.trackNo, year = it.track.year,
        compilation = it.track.compilation, durationMs = it.track.durationMs,
        format = it.track.format, sizeBytes = it.track.sizeBytes,
        bitrateKbps = null, rev = it.rev, tagOk = it.track.tagOk,
        available = it.available,
    )

    fun toIndexedTrack() = SyncEngine.IndexedTrack(
        Scanner.Track(
            album = album,
            albumArtist = albumArtist, albumId = albumId, artist = artist,
            disc = disc, format = format, id = id, path = path,
            sizeBytes = sizeBytes, tagOk = tagOk, title = title,
            trackNo = trackNo, year = year, compilation = compilation,
            durationMs = durationMs,
        ),
        rev = rev, available = available,
    )
}

@Entity(tableName = "playlists")
data class PlaylistEntity(
    @PrimaryKey val path: String,
    val name: String,
)

@Entity(
    tableName = "playlist_items",
    primaryKeys = ["playlistPath", "position"],
    foreignKeys = [ForeignKey(
        entity = PlaylistEntity::class, parentColumns = ["path"],
        childColumns = ["playlistPath"], onDelete = ForeignKey.CASCADE,
    )],
)
data class PlaylistItemEntity(
    val playlistPath: String,
    val position: Int,
    val ref: String,
    val durationMs: Int?,
)

@Entity(tableName = "scan_errors")
data class ScanErrorEntity(
    @PrimaryKey val path: String,
    val code: String,
)

@Entity(tableName = "cursor")
data class CursorEntity(
    @PrimaryKey val path: String,
    val rev: String,
)

@Entity(tableName = "sync_state")
data class SyncStateEntity(
    @PrimaryKey val key: String,
    val value: String,
)

/** schema.sql pins 表：wanted|downloading|done|failed（PinManager 狀態機）。 */
@Entity(tableName = "pins")
data class PinEntity(
    @PrimaryKey val trackId: String,
    val pinnedAt: Long,
    val state: String,
)

@Dao
interface LibraryDao {

    @Query("SELECT value FROM sync_state WHERE key = 'root'")
    suspend fun root(): String?

    @Query("SELECT * FROM tracks")
    suspend fun allTracks(): List<TrackEntity>

    @Query("SELECT * FROM playlists")
    suspend fun allPlaylists(): List<PlaylistEntity>

    @Query("SELECT * FROM playlist_items")
    suspend fun allPlaylistItems(): List<PlaylistItemEntity>

    @Query("SELECT * FROM scan_errors")
    suspend fun allErrors(): List<ScanErrorEntity>

    @Query("SELECT * FROM cursor")
    suspend fun allCursor(): List<CursorEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertTracks(xs: List<TrackEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertPlaylists(xs: List<PlaylistEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertPlaylistItems(xs: List<PlaylistItemEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertErrors(xs: List<ScanErrorEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertCursor(xs: List<CursorEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertSyncState(x: SyncStateEntity)

    @Query("DELETE FROM tracks")
    suspend fun clearTracks()

    @Query("DELETE FROM playlists")   // playlist_items 靠 CASCADE
    suspend fun clearPlaylists()

    @Query("DELETE FROM scan_errors")
    suspend fun clearErrors()

    @Query("DELETE FROM cursor")
    suspend fun clearCursor()

    @Query("SELECT * FROM pins")
    suspend fun allPins(): List<PinEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertPin(x: PinEntity)

    @Query("DELETE FROM pins WHERE trackId IN (:ids)")
    suspend fun deletePins(ids: List<String>)

    @Query("DELETE FROM pins")
    suspend fun clearPins()

    /** 還原引擎狀態（空 DB → null）。 */
    @Transaction
    suspend fun loadEngineState(): EngineState? {
        val cursor = allCursor().associate { it.path to it.rev }
        val tracks = allTracks().associate { it.path to it.toIndexedTrack() }
        if (cursor.isEmpty() && tracks.isEmpty()) return null
        val items = allPlaylistItems().groupBy { it.playlistPath }
        val playlists = allPlaylists().associate { p ->
            p.path to SyncEngine.RawPlaylist(
                p.name,
                (items[p.path] ?: emptyList())
                    .sortedBy { it.position }
                    .map { SyncEngine.RawItem(it.position, it.ref, it.durationMs) },
            )
        }
        val errors = allErrors().associate { it.path to Scanner.ScanError(it.code, it.path) }
        return EngineState(cursor, tracks, playlists, errors)
    }

    /** 全量置換（每輪 sync 後或換庫時；交易內完成）。 */
    @Transaction
    suspend fun replaceLibrary(root: String, state: EngineState) {
        clearTracks(); clearPlaylists(); clearErrors(); clearCursor()
        insertTracks(state.tracks.values.map { TrackEntity(it) })
        insertPlaylists(state.playlists.map { (p, pl) -> PlaylistEntity(p, pl.name) })
        insertPlaylistItems(state.playlists.flatMap { (p, pl) ->
            pl.items.map { PlaylistItemEntity(p, it.position, it.ref, it.durationMs) }
        })
        insertErrors(state.errors.map { (p, e) -> ScanErrorEntity(p, e.code) })
        insertCursor(state.cursor.orEmpty().map { (p, r) -> CursorEntity(p, r) })
        upsertSyncState(SyncStateEntity("root", root))
    }
}

@Database(
    entities = [
        TrackEntity::class, PlaylistEntity::class, PlaylistItemEntity::class,
        ScanErrorEntity::class, CursorEntity::class, SyncStateEntity::class,
        PinEntity::class,
    ],
    version = 2, // v2 = +pins 表（開發期 fallback 破壞性重建）
    exportSchema = false,
)
abstract class MuDatabase : RoomDatabase() {
    abstract fun libraryDao(): LibraryDao

    companion object {
        fun build(context: Context): MuDatabase =
            Room.databaseBuilder(context, MuDatabase::class.java, "mu.db")
                .fallbackToDestructiveMigration() // 開發期 schema 變動即重建（未發布）
                .build()
    }
}
