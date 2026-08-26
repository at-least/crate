# Mu 資料模型與掃描器規格（model.md）

> 契約 v0.1 · Phase 0。兩套核心（Kotlin / Swift）的掃描器對同輸入必須產生 **byte-identical** 的 ScanResult JSON。本文定義到那個等級。

---

## 1. 掃描器（Scanner）

**輸入**：一個虛擬函式庫根目錄（本地目錄或 provider 給的檔案清單）。fixture 以本地目錄樹模擬。

**輸出**：`ScanResult`（見 §2），序 — 檔案格式判定（副檔名）→ tag 解析 → 檔名 fallback → 專輯歸組 → m3u8 解析。

### 1.1 副檔名判定（大小寫不敏感）
| 副檔名 | format | 處理 |
|---|---|---|
| `.flac` | flac | 需以 `fLaC` magic 開頭，否則 error `BAD_CONTAINER` |
| `.mp3` | mp3 | 有 ID3v2 就解析；否則查 MPEG frame sync（`0xFF Ex`）；都不是 → error `BAD_CONTAINER` |
| `.m4a` `.mp4` | m4a | 需為合法 MP4 box 結構且找到 `moov`；否則 error `BAD_CONTAINER` |
| `.ogg` | ogg | `OggS` magic；Vorbis comment 取自第二個 header packet |
| `.opus` | opus | `OggS` magic + `OpusHead`；comment 取自 `OpusTags` packet |
| `.wav` | wav | `RIFF`+`WAVE`；不帶 tag（永遠 fallback） |
| 其他（`.txt` `.jpg` `.pdf` …） | — | **靜默忽略**，不進 tracks 也不進 errors |

### 1.2 Tag 欄位來源
統一輸出欄位 → 各格式的鍵：

| 輸出欄位 | ID3v2.3/2.4 (mp3) | Vorbis/Opus comment | MP4 ilst (m4a) |
|---|---|---|---|
| title | TIT2 | TITLE | ©nam |
| artist | TPE1 | ARTIST | ©ART |
| album_artist | TPE2 | ALBUMARTIST | aART |
| album | TALB | ALBUM | ©alb |
| track_no | TRCK（`"3"` 或 `"3/12"` → 3） | TRACKNUMBER | trkn（2 組 uint16，取第 1 個） |
| disc | TPOS | DISCNUMBER | disk |
| year | TYER(v2.3)/TDRC(v2.4) | DATE 或 YEAR（`1999-03-02` → 1999） | ©day |
| compilation | TCMP 或 TCP =1 | COMPILATION=1 | cpil=1 |

規則：
- 缺 artist → `artist = album_artist`；缺 album_artist → `album_artist = artist`；兩者皆缺 → 走 fallback（§1.4）。
- 缺 title → fallback（§1.4）。
- track_no/disc 解析失敗（非數字前綴）→ null，**不算**解析失敗。
- year 非 4 位數字開頭 → null。
- **任何 tag 解析拋例/格式壞 → `tag_ok=0`，整軌走 fallback，不產生 error**（壞 tag 是資料不是事故）。
- ID3v2.2（3 字母 frame id）不支援 → `tag_ok=0` + fallback。

### 1.3 文字解碼
- Vorbis comment：UTF-8（無 BOM）。壞 UTF-8 → 以 U+FFFD 替換（不 fail）。
- MP4：UTF-8。
- ID3v2 encoding byte：`0`=Latin-1、`1`=UTF-16+SAM BOM（LE/BE 由 BOM 決定）、`2`=UTF-16BE 無 BOM、`3`=UTF-8。
  - **v0 已知限制（刻意釘死）**：encoding 0 遇非 ASCII 位元組 → 按 Latin-1 直解（真實世界的 Big5 檔會變 mojibake 但不炸）。Phase 1 加 Big5 偵測 heuristic，屆時換版 fixtures。
  - encoding 1 的 BOM 缺失 → 從第一對位元組猜（00 非 00 → BE；否則 LE）。UTF-16 長度非偶 → 整 frame 視為缺失。
- 解碼後字串去尾端 NUL 與週邊空白（trim ` \t\r\n\0`）。**不 trim 中間**。空字串視同缺失。

### 1.4 檔名/路徑 fallback（無 tag 或 tag 缺欄位時）
路徑慣例：`<Album Artist>/<Album>/<file>`（相對庫根，`/` 分隔）。

1. `album_artist` = 檔案所在目錄的上上一層（path 第 1 段）。深度不足 2 → `"<Unknown Artist>"`。
2. `album` = 檔案所在的上一層（path 第 2 段）。深度不足 → `"<No Album>"`。
3. `title`：檔名去副檔名後，若符合 `^(\d{1,3})\s-\s(.+)$` → `track_no=組1`（去前導零）、`title=組2`；否則 `track_no=null`、`title=完整檔名去副檔名`。
4. `artist` = `album_artist`（fallback 時兩者同值）。
5. depth 判定：`A/B/file.flac` depth=2 ✓；`B/file.flac` depth=1 → album=`<No Album>`；`file.flac` depth=0 → 全部 `<Unknown Artist>`/`<No Album>`。

### 1.5 專輯歸組
- `albumId`：`"alb|" + album_artist + "|" + album`（v0 佔位；Phase 1 改 `hex(sha256(album_artist + "\u001F" + album))` 前綴 `alb:`，屆時 fixtures 換版）。
- compilation 來源：§1.2 表；或 fallback 時 `album_artist` 不分大小寫等於 `"Various Artists"`。
- 專輯 `year` = 該專輯第一個（排序後）非 null year 的軌的 year；`art_track_id` = 排序後第一個 `tag_ok=1` 的軌 id，無則 null。

### 1.6 錯誤
`errors` 陣列的元素：`{ "code": "...", "message": "...", "path": "..." }`。v0 code 只有 `BAD_CONTAINER`（§1.1）。message 由實作自訂（**不參與 byte-compare**，見 §2.2 豁免）。

## 2. ScanResult JSON（契約核心）

### 2.1 結構
```json
{
  "albums": [ ... ],
  "errors": [ ... ],
  "playlists": [ ... ],
  "tracks": [ ... ]
}
```

Track 物件（欄位**全到**，值可 null；鍵值如 ↓）：
```json
{
  "album": "Album Name",
  "albumArtist": "Artist",
  "albumId": "alb|Artist|Album Name",
  "artist": "Artist",
  "disc": 1,
  "durationMs": null,
  "format": "flac",
  "id": "Artist/Album Name/01 - Song.flac",
  "path": "Artist/Album Name/01 - Song.flac",
  "sizeBytes": 1234,
  "tagOk": true,
  "title": "Song",
  "trackNo": 1,
  "year": 1999
}
```
- `disc` 無值 → 1（不是 null）。`trackNo`/`year`/`durationMs` 無值 → null。
- `id` = path（v0，fixture provider 慣例）。

Album 物件：`{ "albumArtist", "artTrackId", "compilation" (bool), "id", "name", "trackCount" (int), "year" }`

Playlist 物件：`{ "id", "name", "path", "items": [ { "durationMs", "missing" (bool), "position" (int), "ref", "trackId" } ] }`

### 2.2 Byte-compare 規則（兩平台測試都這樣比）
1. 物件鍵 **lexicographic by Unicode codepoint** 排序（`sort_keys=True` 語意）。
2. 縮排 2 空格；行尾 `\n`（LF）；檔尾有恰一個 `\n`。
3. 整數不帶小數點；null/true/false 小寫。
4. 字串轉義：`"`→`\"`、`\`→`\\`、`\b\f\n\r\t` 用短轉義、其他 < 0x20 → `\u00xx`（小寫 hex）；非 ASCII **不轉義**（直接 UTF-8）。
5. 陣列順序：tracks by path（codepoint 序）；albums by (albumArtist, name)；playlists by path；items by position；errors by path。
6. `errors[].message` 是實作自由文字：比對時**先正規化為空字串**再比（其餘欄位照比）。

### 2.3 m3u8 解析規格
- 副檔名 `.m3u8`（大小寫不敏感）→ playlist。其他清單副檔名 v0 忽略。
- 讀為 UTF-8；去 BOM（`\uFEFF`）。**Latin-1 副檔名（.m3u）v0 不支援、忽略。**
- 逐行（同時接受 LF / CRLF）；trim 空白；空行跳過。
- `#EXTM3U` 首行 → 忽略。其他 `#` 開頭：`#EXTINF:<dur>,<title>` → 記住 dur/title 供**下一個**路徑行用（dur 非數字或空 → null；title 不使用，只記 ref）；其餘 `#` 行一律忽略（含註解）。
- 路徑行（非 `#` 開頭）→ item：
  - `ref` = 原始行，做正規化：`\` → `/`、去前綴 `./`。**不**解析 `..`（保留原樣於 ref）。
  - 解析 trackId：`normalize(dirname(playlist.path) + "/" + ref)`，其中 normalize 處理 `.` 段與 `..` 段摺疊、`\`→`/`；結果若以 `../` 開頭（跑出庫外）或 ref 是絕對路徑（`/` 開頭）→ 只在**絕對路徑**情形用 ref 全域比對 path 尾碼？——**v0 簡化：絕對路徑與出界 ref 一律 `missing=true, trackId=null`**（絕對路徑不比對）。
  - 相對 ref：與 tracks 的 path 精確匹配（正規化後）→ `trackId`；無匹配 → `missing=true, trackId=null`。找不到時**不**報 error（清單引用本來就可能指庫外）。
- durationMs：`EXTINF` 秒數轉毫秒，**無浮點確定性演算**：整數部 ×1000 + 小數部左補/右截到 3 位（`213.5`→213500、`5`→5000、`5.4005`→5400、`.5`→500）；負數照算；空/非數字 → null。
- 空檔（或只有 `#EXTM3U`）→ items = `[]`，仍是合法 playlist。
- 重複條目：保留（清單是有序可重複列表）。
- name = 檔名去副檔名。

## 3. 狀態檔 mu-state.json（Phase 3 實作，格式先釘）
```json
{ "version": 1, "updatedAt": 1699999999999, "deviceId": "ab12…",
  "favorites": ["trackId…"],
  "progress": { "trackId…": { "positionMs": 123456, "updatedAt": 1699999999999 } } }
```
規則見 sync-rules.md §3。

## 4. 版面慣例（給兩套實作的共同要求）
- 所有對外路徑：庫根相對、`/` 分隔、無前導 `/`。
- 掃描為**純函式**：同輸入樹 → 同輸出。不觸網、不觸時鐘（`scanned_at` 等時間欄位由 caller 注入，不在 ScanResult 裡）。
- 二進位讀檔一律顯式 little/big endian，禁用平台預設。
