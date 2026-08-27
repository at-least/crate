import Foundation
import SQLite3
import MuCore

/// 音樂庫索引 DB（contract/schema.sql v0.2 的 raw-sqlite3 化；≈ Android 的 Room MuDatabase）。
/// 單庫語意：replaceLibrary 全量置換（換資料夾 = 換庫）；
/// trackId 不落庫（ref 輸出時解析——sync-rules §3.2-5）；albums 派生不落庫（§3.2-6）。
/// 與 schema.sql / Room 版的刻意差異（見 schema.sql pins 表註）：
/// - 不建任何 FK（Room 版僅 playlist_items 有 CASCADE，這裡改為顯式 DELETE playlist_items）
/// - pins 不參照 tracks（釘選要在 replaceLibrary 清 tracks 後存活；換庫才清——PinManager.setRoot）
/// 所有方法同步且執行緒安全（內部序列 queue）；呼叫端自行決定在哪個執行緒跑。
final class MuDatabase {

    struct PinRow {
        let trackId: String
        let pinnedAt: Int64
        let state: String
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "mu.db")

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, handle != nil else {
            throw NSError(domain: "MuDatabase", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(url.path)"])
        }
        db = handle
        try exec(Self.schema)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - 引擎狀態

    /// sync_state 的 'root'（目前庫根路徑；無 → nil）。
    func root() -> String? {
        kvGet("root")
    }

    /// iOS 挑選資料夾的 security-scoped bookmark（無/已清 → nil）。
    func bookmark() -> Data? {
        kvGet("root_bookmark").flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
    }

    /// 還原引擎狀態（空 DB → nil；= Android loadEngineState）。
    func loadEngineState() -> EngineState? {
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
            var errors: [String: MuCore.Scanner.ScanError] = [:]
            try? query("SELECT path, code FROM scan_errors") { s in
                errors[text(s, 0)] = MuCore.Scanner.ScanError(code: text(s, 1), path: text(s, 0))
            }
            return EngineState(cursor: cursor, tracks: tracks, playlists: playlists, errors: errors)
        }
    }

    /// 全量置換（每輪 sync 後或換庫時；交易內完成；= Android replaceLibrary）。
    /// bookmark：新庫帶入 nil 會沿用既有值（同庫重掃不換書籤）。
    func replaceLibrary(root: String, bookmark: Data?, state: EngineState) {
        queue.sync {
            try? exec("BEGIN IMMEDIATE")
            exec("DELETE FROM tracks")
            exec("DELETE FROM playlist_items")
            exec("DELETE FROM playlists")
            exec("DELETE FROM scan_errors")
            exec("DELETE FROM cursor")
            for it in state.tracks.values {
                run("INSERT OR REPLACE INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .text(it.track.id), .text(it.track.path), .text(it.track.title),
                    .text(it.track.artist), .text(it.track.album), .text(it.track.albumArtist),
                    .text(it.track.albumId), .int(Int64(it.track.disc)), .intOpt(it.track.trackNo),
                    .intOpt(it.track.year), .bool(it.track.compilation),
                    .intOpt(it.track.durationMs), .text(it.track.format),
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

    // MARK: - 釘選（schema pins 表；狀態機見 PinManager）

    func allPins() -> [PinRow] {
        queue.sync {
            var rows: [PinRow] = []
            try? query("SELECT track_id, pinned_at, state FROM pins") { s in
                rows.append(PinRow(trackId: text(s, 0), pinnedAt: int(s, 1).map(Int64.init) ?? 0, state: text(s, 2)))
            }
            return rows
        }
    }

    func upsertPin(trackId: String, state: String) {
        queue.sync {
            run("INSERT OR REPLACE INTO pins VALUES (?,?,?)", [
                .text(trackId), .int(Self.nowMs()), .text(state),
            ])
        }
    }

    func deletePins(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            for id in ids {
                run("DELETE FROM pins WHERE track_id = ?", [.text(id)])
            }
        }
    }

    func clearPins() {
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
            artist: text(s, 3), disc: Int(int(s, 7) ?? 1), format: text(s, 12),
            id: text(s, 0), path: text(s, 1), sizeBytes: Int(int(s, 13) ?? 0),
            tagOk: bool(s, 16), title: text(s, 2), trackNo: int(s, 8),
            year: int(s, 9), compilation: bool(s, 10), durationMs: int(s, 11))
        return SyncEngine.IndexedTrack(track: t, rev: text(s, 15), available: bool(s, 17))
    }

    private enum Val {
        case text(String), int(Int64), intOpt(Int?), bool(Bool), null
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
            throw NSError(domain: "MuDatabase", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "prepare failed: \(sql)"])
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in vals.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
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

    private func int(_ s: OpaquePointer, _ i: Int32) -> Int? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i))
    }

    private func bool(_ s: OpaquePointer, _ i: Int32) -> Bool {
        sqlite3_column_int64(s, i) != 0
    }

    /// SQLITE_TRANSIENT（bind 立即複製）。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// contract/schema.sql v0.2 的鏡像（FK 移除理由見類型註解；albums/play_state/favorites 保留未用）。
    private static let schema = """
        PRAGMA user_version = 1;
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
          track_id  TEXT PRIMARY KEY,
          pinned_at INTEGER NOT NULL,
          state     TEXT NOT NULL DEFAULT 'wanted'
        );
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
