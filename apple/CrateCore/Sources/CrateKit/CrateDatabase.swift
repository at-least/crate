import Foundation
import SQLite3
import CrateCore

/// 音樂庫索引 DB（contract/schema.sql v0.3 的 raw-sqlite3 化；≈ Android 的 Room CrateDatabase）。
/// 單庫語意：replaceLibrary 全量置換（換資料夾 = 換庫）；
/// trackId 不落庫（ref 輸出時解析——sync-rules §3.2-5）；albums 派生不落庫（§3.2-6）。
/// 與 schema.sql / Room 版的刻意差異（見 schema.sql pins 表註）：
/// - 不建任何 FK（Room 版僅 playlist_items 有 CASCADE，這裡改為顯式 DELETE playlist_items）
/// - pins 不參照 tracks（記錄層 root-scoped、換庫休眠——見 PinManager；replaceLibrary 不動 pins）
/// 所有方法同步且執行緒安全（內部序列 queue）；呼叫端自行決定在哪個執行緒跑。
public final class CrateDatabase {

    public struct PinRow {
        public let trackId: String
        public let pinnedAt: Int64
        public let state: String
        public let contentHash: String?
        public let rev: String

        public init(trackId: String, pinnedAt: Int64, state: String,
                    contentHash: String?, rev: String) {
            self.trackId = trackId; self.pinnedAt = pinnedAt; self.state = state
            self.contentHash = contentHash; self.rev = rev
        }
    }

    /// schema.sql 的 PRAGMA user_version（v0.4 = 3）。
    private static let schemaVersion = 3

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "crate.db")

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, handle != nil else {
            throw NSError(domain: "CrateDatabase", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(url.path)"])
        }
        db = handle
        // 讀失敗即丟（init throws）——靜默當 0 會跳過破壞性重建，舊表形狀留著炸 runtime
        var version = 0
        try query("PRAGMA user_version") { s in version = int(s, 0) ?? 0 }
        if version != 0 && version != Self.schemaVersion {
            // 開發期破壞性重建（未發布）：索引可重掃、pins 由 PinManager 重抓，
            // play_state/favorites 尚未接線——無不可失資料
            for t in ["tracks", "albums", "playlists", "playlist_items", "scan_errors",
                      "cursor", "pins", "play_state", "favorites", "sync_state"] {
                exec("DROP TABLE IF EXISTS \(t)")
            }
        }
        exec(Self.schema)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - 引擎狀態

    /// sync_state 的 'root'（目前庫根路徑；無 → nil）。
public     func root() -> String? {
        kvGet("root")
    }

    /// iOS 挑選資料夾的 security-scoped bookmark（無/已清 → nil）。
public     func bookmark() -> Data? {
        kvGet("root_bookmark").flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
    }

    /// 還原引擎狀態（空 DB → nil；= Android loadEngineState）。
public     func loadEngineState() -> EngineState? {
        queue.sync {
            var cursor: [String: String] = [:]
            try? query("SELECT path, rev FROM cursor") { s in
                cursor[text(s, 0)] = text(s, 1)
            }
            var tracks: [String: SyncEngine.IndexedTrack] = [:]
            try? query("SELECT * FROM tracks") { s in tracks[text(s, 1)] = self.rowToIndexedTrack(s) }
            guard !(cursor.isEmpty && tracks.isEmpty) else { return nil }
            var itemsByPath: [String: [(Int, String, Int?)]] = [:]
            try? query("SELECT playlist_id, position, ref, duration_ms FROM playlist_items") { s in
                itemsByPath[text(s, 0), default: []].append((int(s, 1) ?? 0, text(s, 2), int(s, 3)))
            }
            var playlists: [String: SyncEngine.RawPlaylist] = [:]
            try? query("SELECT id, name FROM playlists") { s in
                let items = (itemsByPath[text(s, 0)] ?? [])
                    .sorted { $0.0 < $1.0 }
                    .map { SyncEngine.RawItem(position: $0.0, ref: $0.1, durationMs: $0.2) }
                playlists[text(s, 0)] = SyncEngine.RawPlaylist(name: text(s, 1), items: items)
            }
            var errors: [String: CrateCore.Scanner.ScanError] = [:]
            try? query("SELECT path, code FROM scan_errors") { s in
                errors[text(s, 0)] = CrateCore.Scanner.ScanError(code: text(s, 1), path: text(s, 0))
            }
            return EngineState(cursor: cursor, tracks: tracks, playlists: playlists, errors: errors)
        }
    }

    /// 全量置換（每輪 sync 後或換庫時；交易內完成；= Android replaceLibrary）。
    /// bookmark：新庫帶入 nil 會沿用既有值（同庫重掃不換書籤）。
public     func replaceLibrary(root: String, bookmark: Data?, state: EngineState) {
        queue.sync {
            try? exec("BEGIN IMMEDIATE")
            exec("DELETE FROM tracks")
            exec("DELETE FROM playlist_items")
            exec("DELETE FROM playlists")
            exec("DELETE FROM scan_errors")
            exec("DELETE FROM cursor")
            for it in state.tracks.values {
                run("INSERT OR REPLACE INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .text(it.track.id), .text(it.track.path), .text(it.track.title),
                    .text(it.track.artist), .text(it.track.album), .text(it.track.albumArtist),
                    .text(it.track.albumId), .int(Int64(it.track.disc)), .intOpt(it.track.trackNo),
                    .intOpt(it.track.year), .bool(it.track.compilation),
                    .intOpt(it.track.durationMs),
                    .intOpt(it.track.replayGainTrackMb), .intOpt(it.track.replayGainAlbumMb),
                    .text(it.track.format),
                    .int(Int64(it.track.sizeBytes)), .null, .text(it.rev),
                    .bool(it.track.tagOk), .bool(it.available),
                ])
            }
            for (path, pl) in state.playlists {
                run("INSERT OR REPLACE INTO playlists VALUES (?,?,?)", [
                    .text(path), .text(path), .text(pl.name),
                ])
                for it in pl.items {
                    run("INSERT OR REPLACE INTO playlist_items VALUES (?,?,?,?)", [
                        .text(path), .int(Int64(it.position)), .text(it.ref),
                        .intOpt(it.durationMs),
                    ])
                }
            }
            for (path, e) in state.errors {
                run("INSERT OR REPLACE INTO scan_errors VALUES (?,?)", [.text(path), .text(e.code)])
            }
            for (path, rev) in state.cursor ?? [:] {
                run("INSERT OR REPLACE INTO cursor VALUES (?,?)", [.text(path), .text(rev)])
            }
            kvSet("root", root)
            kvSet("root_bookmark", bookmark.map { $0.base64EncodedString() } ?? "")
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                exec("ROLLBACK") // 提交失敗（如磁碟滿）不留半開交易
            }
        }
    }

    // MARK: - 釘選（schema pins 表 v0.3；狀態機見 PinManager）

    /// 指定庫根的釘選 rows（App 只載當前 root——顯示單庫視角）。
public     func allPins(root: String) -> [PinRow] {
        queue.sync {
            var rows: [PinRow] = []
            try? query("SELECT track_id, pinned_at, state, content_hash, rev FROM pins WHERE root = ?",
                       [.text(root)]) { s in
                rows.append(PinRow(trackId: text(s, 0), pinnedAt: Int64(int(s, 1) ?? 0),
                                   state: text(s, 2), contentHash: textOpt(s, 3), rev: text(s, 4)))
            }
            return rows
        }
    }

public     func upsertPin(root: String, trackId: String, contentHash: String?, rev: String, state: String) {
        queue.sync {
            run("INSERT OR REPLACE INTO pins VALUES (?,?,?,?,?,?)", [
                .text(root), .text(trackId), .textOpt(contentHash), .text(rev),
                .int(Self.nowMs()), .text(state),
            ])
        }
    }

public     func deletePins(root: String, trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        queue.sync {
            let ph = trackIds.map { _ in "?" }.joined(separator: ",")
            run("DELETE FROM pins WHERE root = ? AND track_id IN (\(ph))",
                [.text(root)] + trackIds.map(Val.text))
        }
    }

    /// 引用同 content_hash 的釘選數（跨庫）——unpin 時的刪檔依據（0 = 可刪）。
public     func pinCount(contentHash: String) -> Int {
        queue.sync {
            var n = 0
            try? query("SELECT COUNT(*) FROM pins WHERE content_hash = ?", [.text(contentHash)]) { s in
                n = int(s, 0) ?? 0
            }
            return n
        }
    }

public     func clearAllPins() {
        queue.sync { exec("DELETE FROM pins") }
    }

    // MARK: - SQLite 輔助

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func kvGet(_ key: String) -> String? {
        var out: String?
        queue.sync {
            try? query("SELECT value FROM sync_state WHERE key = ?", [.text(key)]) { s in
                out = text(s, 0)
            }
        }
        return out
    }

    private func kvSet(_ key: String, _ value: String) {
        run("INSERT OR REPLACE INTO sync_state VALUES (?,?)", [.text(key), .text(value)])
    }

    private func rowToIndexedTrack(_ s: OpaquePointer) -> SyncEngine.IndexedTrack {
        // 欄位序 = INSERT 的 tracks VALUES 序
        let t = Track(
            album: text(s, 4), albumArtist: text(s, 5), albumId: text(s, 6),
            artist: text(s, 3), disc: Int(int(s, 7) ?? 1), format: text(s, 14),
            id: text(s, 0), path: text(s, 1), sizeBytes: Int(int(s, 15) ?? 0),
            tagOk: bool(s, 18), title: text(s, 2), trackNo: int(s, 8),
            year: int(s, 9), compilation: bool(s, 10), durationMs: int(s, 11),
            replayGainTrackMb: int(s, 12), replayGainAlbumMb: int(s, 13))
        return SyncEngine.IndexedTrack(track: t, rev: text(s, 17), available: bool(s, 19))
    }

    private enum Val {
        case text(String), textOpt(String?), int(Int64), intOpt(Int?), bool(Bool), null
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, _ vals: [Val]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in vals.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .textOpt(let s):
                if let s { sqlite3_bind_text(stmt, idx, s, -1, Self.transient) }
                else { sqlite3_bind_null(stmt, idx) }
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .intOpt(let n):
                if let n { sqlite3_bind_int64(stmt, idx, Int64(n)) } else { sqlite3_bind_null(stmt, idx) }
            case .bool(let b): sqlite3_bind_int64(stmt, idx, b ? Int64(1) : Int64(0))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        sqlite3_step(stmt)
    }

    private func query(_ sql: String, _ vals: [Val] = [], _ row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "CrateDatabase", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "prepare failed: \(sql)"])
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in vals.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .textOpt(let s):
                if let s { sqlite3_bind_text(stmt, idx, s, -1, Self.transient) }
                else { sqlite3_bind_null(stmt, idx) }
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .intOpt(let n):
                if let n { sqlite3_bind_int64(stmt, idx, Int64(n)) } else { sqlite3_bind_null(stmt, idx) }
            case .bool(let b): sqlite3_bind_int64(stmt, idx, b ? Int64(1) : Int64(0))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private func textOpt(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : text(s, i)
    }

    private func int(_ s: OpaquePointer, _ i: Int32) -> Int? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i))
    }

    private func bool(_ s: OpaquePointer, _ i: Int32) -> Bool {
        sqlite3_column_int64(s, i) != 0
    }

    /// SQLITE_TRANSIENT（bind 立即複製）。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// contract/schema.sql v0.4 的鏡像（FK 移除理由見類型註解；albums/play_state/favorites 保留未用）。
    private static let schema = """
        PRAGMA user_version = 3;
        CREATE TABLE IF NOT EXISTS tracks (
          id           TEXT PRIMARY KEY,
          path         TEXT NOT NULL UNIQUE,
          title        TEXT NOT NULL,
          artist       TEXT NOT NULL,
          album        TEXT NOT NULL,
          album_artist TEXT NOT NULL,
          album_id     TEXT NOT NULL,
          disc         INTEGER NOT NULL DEFAULT 1,
          track_no     INTEGER,
          year         INTEGER,
          compilation  INTEGER NOT NULL DEFAULT 0,
          duration_ms  INTEGER,
          rg_track_mb  INTEGER,
          rg_album_mb  INTEGER,
          format       TEXT NOT NULL,
          size_bytes   INTEGER NOT NULL,
          bitrate_kbps INTEGER,
          rev          TEXT NOT NULL,
          tag_ok       INTEGER NOT NULL DEFAULT 0,
          available    INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album_id, disc, track_no, path);
        CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);
        CREATE TABLE IF NOT EXISTS albums (
          id           TEXT PRIMARY KEY,
          name         TEXT NOT NULL,
          album_artist TEXT NOT NULL,
          year         INTEGER,
          compilation  INTEGER NOT NULL DEFAULT 0,
          art_track_id TEXT
        );
        CREATE TABLE IF NOT EXISTS playlists (
          id         TEXT PRIMARY KEY,
          path       TEXT NOT NULL UNIQUE,
          name       TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS playlist_items (
          playlist_id TEXT NOT NULL,
          position    INTEGER NOT NULL,
          ref         TEXT NOT NULL,
          duration_ms INTEGER,
          PRIMARY KEY (playlist_id, position)
        );
        CREATE TABLE IF NOT EXISTS scan_errors (
          path TEXT PRIMARY KEY,
          code TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cursor (
          path TEXT PRIMARY KEY,
          rev  TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pins (
          root         TEXT NOT NULL,
          track_id     TEXT NOT NULL,
          content_hash TEXT,
          rev          TEXT NOT NULL,
          pinned_at    INTEGER NOT NULL,
          state        TEXT NOT NULL DEFAULT 'wanted',
          PRIMARY KEY (root, track_id)
        );
        CREATE INDEX IF NOT EXISTS idx_pins_hash ON pins(content_hash);
        CREATE TABLE IF NOT EXISTS play_state (
          id           INTEGER PRIMARY KEY CHECK (id = 1),
          track_id     TEXT,
          position_ms  INTEGER NOT NULL DEFAULT 0,
          updated_at   INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS favorites (
          track_id     TEXT PRIMARY KEY,
          favorited_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_state (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """
}
