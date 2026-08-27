-- Mu · contract/schema.sql
-- 唯一事實來源。Android (Room) 與 Apple (GRDB/raw sqlite3) 都從這份檔案出發。
-- 版本：v0.1（Phase 0）。schema migration 一律加新檔 schema/NNN_*.sql，不改這份歷史。
-- 所有時間戳 = Unix epoch 毫秒（INTEGER）。所有 TEXT = UTF-8。

PRAGMA user_version = 1;

-- ============ 音軌 ============
-- id: provider 的檔案唯一鍵（fixture provider 以 path 為 id；見 fixtures/README.md）
CREATE TABLE tracks (
  id           TEXT PRIMARY KEY,
  path         TEXT NOT NULL UNIQUE,   -- 相對於庫根，一律 '/' 分隔，不含開頭 '/'
  title        TEXT NOT NULL,
  artist       TEXT NOT NULL,          -- track artist；無則 = album_artist
  album_artist TEXT NOT NULL,
  album_id     TEXT NOT NULL REFERENCES albums(id),
  disc         INTEGER NOT NULL DEFAULT 1,
  track_no     INTEGER,                -- 可 null
  year         INTEGER,                -- 可 null
  duration_ms  INTEGER,                -- v0 = null（Phase 1 補 per-format duration）
  format       TEXT NOT NULL,          -- flac|mp3|m4a|ogg|opus|wav（小寫）
  size_bytes   INTEGER NOT NULL,
  bitrate_kbps INTEGER,                -- v0 = null
  modified_at  INTEGER NOT NULL,       -- 雲端 mtime（provider 給）
  scanned_at   INTEGER NOT NULL,       -- 本地 tag 解析時間
  tag_ok       INTEGER NOT NULL DEFAULT 0,  -- 0 = 解析失敗/無 tag（走檔名 fallback）
  available    INTEGER NOT NULL DEFAULT 1   -- 0 = 雲端已刪（本地索引保留）
);
CREATE INDEX idx_tracks_album ON tracks(album_id, disc, track_no, path);
CREATE INDEX idx_tracks_artist ON tracks(artist);

CREATE TABLE albums (
  id           TEXT PRIMARY KEY,       -- 見 model.md：albumId 演算法（v0 為組合字串，Phase 1 改 SHA-256）
  name         TEXT NOT NULL,
  album_artist TEXT NOT NULL,
  year         INTEGER,
  compilation  INTEGER NOT NULL DEFAULT 0,
  art_track_id TEXT                    -- 封面軌（第一張 tagOk 的軌）
);

-- ============ 播放清單（.m3u8 檔的鏡像） ============
CREATE TABLE playlists (
  id         TEXT PRIMARY KEY,         -- = path
  path       TEXT NOT NULL UNIQUE,     -- 相對庫根，'/' 分隔
  name       TEXT NOT NULL,            -- 檔名去副檔名
  rev        TEXT,                     -- provider 的 file rev（衝突偵測用；fixture provider = size+mtime）
  synced_at  INTEGER NOT NULL
);

CREATE TABLE playlist_items (
  playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  position    INTEGER NOT NULL,        -- 0-based，檔案內順序
  ref         TEXT NOT NULL,           -- m3u8 原始行（解析後正規化：'/'、去 ./）
  track_id    TEXT REFERENCES tracks(id),  -- null = 引用的檔不在庫中（missing）
  PRIMARY KEY (playlist_id, position)
);

-- ============ 離線釘選 ============
CREATE TABLE pins (
  track_id  TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
  pinned_at INTEGER NOT NULL,
  state     TEXT NOT NULL DEFAULT 'wanted'  -- wanted|downloading|done|failed
);

-- ============ 播放狀態（裝置本機；D12 後不上雲） ============
CREATE TABLE play_state (
  id           INTEGER PRIMARY KEY CHECK (id = 1),  -- 單列
  track_id     TEXT,
  position_ms  INTEGER NOT NULL DEFAULT 0,
  updated_at   INTEGER NOT NULL
);

CREATE TABLE favorites (
  track_id   TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
  favorited_at INTEGER NOT NULL
);

-- ============ 同步游標與雜項 KV ============
CREATE TABLE sync_state (
  key   TEXT PRIMARY KEY,              -- 如 'cursor:gdrive:<rootId>'
  value TEXT NOT NULL
);
