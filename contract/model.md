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

### 1.7 時長（durationMs；v1）
container 合法即解析，與 tag 內容無關。一律整數除法（floor）；解析失敗/值 ≤ 0 → null（不產生 error）。

- **flac**：第一個 metadata block 需為 STREAMINFO（type 0，len 34）。
  sampleRate = `(b[10]<<12)|(b[11]<<4)|(b[12]>>4)`；totalSamples = `((b[13]&0xF)<<32) | u64be(b[14..18])`。
  `durationMs = totalSamples*1000 // sampleRate`；sampleRate 或 totalSamples == 0 → null。
- **mp3**：跳過 ID3v2（10 + syncsafe size，若以 "ID3" 開頭），之後逐 byte 向後找**第一個合法 frame sync**：
  `0xFF Ex`、version ≠ 1（保留）、layer ≠ 0、bitrate index ∉ {0,15}、samplerate index ≠ 3。
  bitrate 表（kbps，僅 Layer III；其他 layer v1 不支援 → null）：MPEG1: 32,40,48,56,64,80,96,112,128,160,192,224,256,320；MPEG2/2.5: 8,16,24,32,40,48,56,64,80,96,112,128,144,160。
  `durationMs = (sizeBytes − frameOffset) * 8 // bitrateKbps`；找不到 frame → null。
- **m4a**：`moov/mvhd`。version 0：timescale = u32@+12、duration = u32@+16；version 1：timescale = u32@+20、duration = u64@+24（均相對 mvhd body 起算，body 為 version/flags 之後）。
  `durationMs = duration*1000 // timescale`；無 mvhd 或 timescale == 0 → null。
- **ogg**：id header `\x01vorbis`（**前 64KB 視窗**內搜尋）→ sampleRate = u32le@+12；**檔尾 64KB 視窗**內最後一個 `OggS` magic → granule = u64le@+6（Ogg 頁最大 65307B，最後一頁的 header 必在視窗內）。
  `durationMs = granule*1000 // sampleRate`。
- **opus**：`OpusHead`（前 64KB 視窗）→ preskip = u16le@+10；檔尾 64KB 視窗內最後一個 `OggS` → granule = u64le@+6（48kHz 時脈）。
  `durationMs = (granule − preskip)*1000 // 48000`；≤ 0 → null。
- **wav**：RIFF chunk 巡訪（id 4B + size u32le，pad 偶數）：`fmt ` 的 byteRate = u32le@fmtbody+8、`data` 的 size。
  `durationMs = dataSize*1000 // byteRate`；byteRate == 0 → null。

### 1.8 讀取視窗化（v1.1；雲端 provider 進場）
掃描器**不讀整檔**：輸入是 `ByteSource { size, read(offset, length) }`，經 `ChunkedReader` 存取——
**64 KiB 對齊 chunk、每 chunk 最多抓一次（快取）、`bytes(offset, length)` 依序抓取涵蓋範圍的 chunk 並裁切到 size**。
三實作用同一套 chunk 算法與同一套 parser 存取序列，因此每個檔案**觸碰的 chunk 集合一致**——雲端 provider 的 Range 請求數即成為契約可觀測值（`gdrive_cases/` 每步 `provider.requests`）。

parser 只讀結構需要的位元組、跳過大 payload（存取序列即規格）：
- **ID3v2**：讀 10B header；extended header 讀 4B；每 frame 讀 10B header，只有 §1.2 關注的 frame 才讀 payload（APIC 等直接以 size 跳過）。
- **FLAC**：讀 4B magic；每 metadata block 讀 4B header，只有 VORBIS_COMMENT（type 4）讀 payload（PICTURE 跳過）；時長讀前 42B。
- **MP4**：box 巡訪只讀 8B header（size==1 再讀 8B 64-bit size），`moov/udta/meta/ilst` 進入，其餘（含 mdat）跳過；ilst 內只讀 `data` box payload（meta 的 4B version/flags 跳過）。size < header 或超出範圍 → 停止巡訪。
- **MP3 時長**：ID3 之後的 frame sync 搜尋視窗 = `[off, min(off+65536, size−3))`（多讀 2B 供 header 判讀）。
- **Ogg**：tag 與 `OpusHead`/`\x01vorbis` 在前 64KB 視窗；最後 `OggS` 在檔尾 64KB 視窗（§1.7）。
- **WAV**：RIFF chunk 巡訪只讀 8B chunk header；`fmt ` 需 `i+20 ≤ size` 才讀 byteRate；`data` 以 size 跳過。
- **m3u8**：整檔（小檔）。
- 同鍵重複（ilst 同 atom 多次、vorbis 同 key 多次、ID3 同 frame 多次）：**第一個非空值勝**；vorbis comment 無 `=` 或 key 為空 → 忽略。

本地資料夾以檔案為 ByteSource（讀法相同，只是 IO 便宜）；`sizeBytes` 一律取自 ByteSource.size（雲端 = metadata `size`）。

### 1.9 ReplayGain（v1.2；Phase 4）
輸出欄位 `replayGainTrackMb` / `replayGainAlbumMb`：**millibel 整數**（`-6.54 dB` → `-654`），無值 → null。不影響 `tagOk`。

| 欄位 | ID3v2.3/2.4 | Vorbis/FLAC/Opus comment | MP4 ilst |
|---|---|---|---|
| track | `TXXX` 且 description（不分大小寫）= `replaygain_track_gain` | `REPLAYGAIN_TRACK_GAIN` | `----` 自由格式 atom，`name`（不分大小寫）= `replaygain_track_gain`（`mean` 不檢查） |
| album | 同上 `replaygain_album_gain` | `REPLAYGAIN_ALBUM_GAIN` | 同上 `replaygain_album_gain` |

- `TXXX` 結構：encoding byte + description + 終止符 + value（+ 可選終止符）。終止符依編碼：Latin-1/UTF-8 = 1 個 NUL；UTF-16（enc 1/2）= 對齊的 `00 00`。description 與 value 各依 §1.3 解碼。同 description 多個 frame → 第一個非空值勝（與其他 frame 規則相同）。
- `----` 結構：子 atom `mean`（4B version/flags + 文字）、`name`（4B + 文字）、`data`（8B + UTF-8 文字）；缺 `name` 或 `data` → 忽略。
- 值解析（`parseGainMb`，無浮點）：trim；可選 `+`/`-`；整數位數字（≥1 位）；可選 `.` + 小數位；其後（如 ` dB`）忽略。`mb = sign × (int×100 + 前兩位小數右補 0)`；第三位以後**截斷**（`-6.545` → `-654`）。無整數位數字 → null（如 `n/a`、`.5`）。
- Opus 的 `R128_*_GAIN`（Q7.8、-23 LUFS 基準）v1 **不支援**（→ null）；Opus 檔若帶 `REPLAYGAIN_*` 照上表解析。

### 1.10 播放增益與等化器（EQ；v1.3，Phase 4）
播放期 DSP 設定。**契約只釘整數設定與合成規則**（可三方 byte-identical）；濾波器係數與取樣處理是浮點，
各平台以自家 DSP 單元測試（頻率響應/穩定性）驗證，不入 byte 比對。

`EqSettings`（存**裝置本機設定**——Apple `UserDefaults`、Android `SharedPreferences`，鍵 `eq`；與 §1.9 的播放模式同處。canonical JSON）：
```json
{ "bands": [0,0,0,0,0,0,0,0,0,0], "enabled": false, "preamp": 0, "preset": "flat" }
```
- `bands`：**10 段**增益（millibel），中心頻率固定 `31/62/125/250/500/1000/2000/4000/8000/16000` Hz，每段 `Q = 1.41`（約一個八度）。
- 每段與 `preamp` 一律 clamp 到 **±1200 mb**（±12 dB）。`preset` 僅為標籤（bands 才是真相）；解析時多餘鍵忽略、缺鍵取預設、`bands` 不足補 0／超過截斷／非整數視為 0。
- presets（mb，依序對應上列頻率）：

| preset | 31 | 62 | 125 | 250 | 500 | 1k | 2k | 4k | 8k | 16k |
|---|---|---|---|---|---|---|---|---|---|---|
| flat | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| rock | 500 | 400 | 200 | 0 | -100 | -100 | 200 | 400 | 500 | 500 |
| pop | -100 | 100 | 300 | 400 | 300 | 100 | 0 | -100 | -100 | -100 |
| jazz | 300 | 200 | 100 | 200 | -100 | -100 | 0 | 100 | 200 | 300 |
| classical | 400 | 300 | 200 | 100 | -100 | -100 | 0 | 200 | 300 | 400 |
| bass | 700 | 600 | 400 | 200 | 0 | 0 | 0 | 0 | 0 | 0 |
| treble | 0 | 0 | 0 | 0 | 0 | 100 | 300 | 500 | 600 | 700 |
| vocal | -200 | -100 | 0 | 200 | 400 | 400 | 300 | 100 | 0 | -100 |
| loudness | 600 | 500 | 200 | 0 | -200 | -200 | 0 | 200 | 500 | 600 |

**播放總增益**（§1.9 ReplayGain + preamp，整數 mb）：
`playbackGainMb = clamp(rgMb(mode, trackMb, albumMb) ?? 0, ±6000) + (enabled ? preamp : 0)`，再 clamp 到 **[-6000, +1200]**。
線性值 = `10^(mb/2000)`；**v1.3 起允許 > 1（正增益放大）**——增益改在 DSP 層套用（不再受播放器音量 0…1 上限），
輸出樣本硬性 clamp 到 ±1.0（過度正增益會削峰，屬使用者選擇）。EQ 停用且總增益 = 0 → DSP 直通（零成本）。

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
  "replayGainAlbumMb": null,
  "replayGainTrackMb": -654,
  "sizeBytes": 1234,
  "tagOk": true,
  "title": "Song",
  "trackNo": 1,
  "year": 1999
}
```
- `disc` 無值 → 1（不是 null）。`trackNo`/`year`/`durationMs`/`replayGain*Mb` 無值 → null。
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

## 3. 版面慣例（給兩套實作的共同要求）
- 所有對外路徑：庫根相對、`/` 分隔、無前導 `/`。
- 掃描為**純函式**：同輸入樹 → 同輸出。不觸網、不觸時鐘（`scanned_at` 等時間欄位由 caller 注入，不在 ScanResult 裡）。
- 二進位讀檔一律顯式 little/big endian，禁用平台預設。
