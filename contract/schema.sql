-- Mu · contract/schema.sql
-- 唯一事實來源。Android (Room) 與 Apple (GRDB/raw sqlite3) 都從這份檔案出發。
-- 版本：v0.4（ReplayGain：tracks.rg_track_mb/rg_album_mb，model.md §1.9）。v0.3 = D13 pins root-scoped/content_hash。
-- schema migration 一律加新檔 schema/NNN_*.sql，不改這份歷史。
-- 所有時間戳 = Unix epoch 毫秒（INTEGER）。所有 TEXT = UTF-8。

PRAGMA user_version = 3;

-- ============ 音軌 ============
-- id: provider 的檔案唯一鍵（fixture provider 以 path 為 id；見 fixtures/README.md）
CREATE TABLE tracks (
  id           TEXT PRIMARY KEY,
  path         TEXT NOT NULL UNIQUE,   -- 相對於庫根，一律 '/' 分隔，不含開頭 '/'
  title        TEXT NOT NULL,
  artist       TEXT NOT NULL,          -- track artist；無則 = album_artist
  album        TEXT NOT NULL,          -- 專輯名（model.md §2.1 track 形狀；歸組鍵之一）
  album_artist TEXT NOT NULL,
  album_id     TEXT NOT NULL REFERENCES albums(id),
  disc         INTEGER NOT NULL DEFAULT 1,
  track_no     INTEGER,                -- 可 null
  year         INTEGER,                -- 可 null
  compilation  INTEGER NOT NULL DEFAULT 0,
  duration_ms  INTEGER,                -- null = 解析失敗/不適用（model.md §1.7）
  rg_track_mb  INTEGER,                -- ReplayGain track gain，millibel（model.md §1.9）；null = 無 tag
  rg_album_mb  INTEGER,                -- ReplayGain album gain，millibel
  format       TEXT NOT NULL,          -- flac|mp3/m4a|ogg|opus|wav（小寫）
  size_bytes   INTEGER NOT NULL,
  bitrate_kbps INTEGER,                -- v0 = null
  rev          TEXT NOT NULL,          -- 引擎持久化的快照 rev（LocalFolderProvider = "{size}:{mtimeMs}"）
  tag_ok       INTEGER NOT NULL DEFAULT 0,  -- 0 = 解析失敗/無 tag（走檔名 fallback）
  available    INTEGER NOT NULL DEFAULT 1   -- 0 = 雲端已刪（本地索引保留）
);
-- 註：modified_at / scanned_at 為 App 層掃描管線時間戳（model.md §4：核心 ScanResult 不含時間），
-- 引擎持久化不落庫；App 要觀測時自行加欄。album_id 不設 FK——albums 是每輪重導的派生快取（sync-rules §3.2-6）。
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
-- 註：albums 為可選的派生快取（每輪由 tracks 全量重導）；不持久化亦正確。

-- ============ 播放清單（.m3u8 檔的鏡像；raw refs） ============
CREATE TABLE playlists (
  id         TEXT PRIMARY KEY,         -- = path
  path       TEXT NOT NULL UNIQUE,     -- 相對庫根，'/' 分隔
  name       TEXT NOT NULL             -- 檔名去副檔名
);

CREATE TABLE playlist_items (
  playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  position    INTEGER NOT NULL,        -- 0-based，檔案內順序
  ref         TEXT NOT NULL,           -- m3u8 原始行（正規化後：'/'、去 ./）
  duration_ms INTEGER,                -- EXTINF 毫秒；無/畸形 = null
  PRIMARY KEY (playlist_id, position)
);
-- 註：ref → trackId 在每次輸出時對 available 集合解析（sync-rules §3.2-5），不落庫。

-- ============ 掃描錯誤（隨索引持久化） ============
CREATE TABLE scan_errors (
  path TEXT PRIMARY KEY,
  code TEXT NOT NULL                  -- v0 僅 BAD_CONTAINER（model.md §1.6）
);

-- ============ Provider 快照 cursor（引擎持久化；delta 比對基準） ============
CREATE TABLE cursor (
  path TEXT PRIMARY KEY,              -- 全部檔案（含非音訊；過濾是引擎的事）
  rev  TEXT NOT NULL
);

-- ============ 離線釘選（v0.3 / D13：記錄層 root-scoped、下載層內容定址） ============
-- 兩層分離：
-- - 下載層（檔案系統）：downloads/<sha256>——bytes 相同 = 同一份副本，跨庫共用、只抓一次；
--   換庫休眠不清、切回即重連（rev 重驗）；unpin 以 content_hash 引用計數決定是否刪檔。
-- - 記錄層（本表）：釘選意圖屬於庫，按 (root, track_id) 歸屬；App 只載入當前 root 的 rows（顯示單庫視角）。
-- 註：刻意不帶 REFERENCES tracks(id)——釘選要在重掃/全量置換（replaceLibrary 清 tracks）後存活。
CREATE TABLE pins (
  root         TEXT NOT NULL,           -- 庫根路徑（單一 active 庫；他庫 rows = 休眠）
  track_id     TEXT NOT NULL,
  content_hash TEXT,                    -- 下載副本 SHA-256 hex；wanted/downloading = null
  rev          TEXT NOT NULL,           -- 釘選時的軌 rev（sync 後重驗：rev 變 → 重抓）
  pinned_at    INTEGER NOT NULL,
  state        TEXT NOT NULL DEFAULT 'wanted',  -- wanted|downloading|done|failed
  PRIMARY KEY (root, track_id)
);
CREATE INDEX idx_pins_hash ON pins(content_hash);

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
  key   TEXT PRIMARY KEY,              -- 如 'root'（目前庫根）；雲端時代再加 'cursor:gdrive:<rootId>'。播放設定（RG 模式/EQ）走平台 prefs，不入此表（model.md §1.10）
  value TEXT NOT NULL
);
