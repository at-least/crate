# Provider 介面語意（provider.md）

> 契約 v0.2（§8 GDrive 進場）。實作於 MuCore(swift) / mu-core(kotlin)。v0 只釘**語意**；類別簽名各語言自便。

## 1. 介面

```
CloudProvider {
  id: String                      // "gdrive" | "dropbox"
  authenticate()                  // OAuth; token 存系統鑰匙串; 失敗拋 AuthError
  revoke()

  resolveRoot(folderUrlOrId) -> RootInfo
  // RootInfo { rootId, rootPath }

  listDir(rootId, path, pageToken?) -> { entries: [Entry], nextPageToken? }
  // Entry { id, path, isDir, sizeBytes, rev, modifiedAt(ms) }

  delta(rootId, storedCursor?) -> { changes: [Change], newCursor, reset: Bool }
  // Change { entry: Entry? , removed: Bool }   // entry=null + removed=true = 刪除
  // cursor 失效 → 回 reset=true + 全量 changes；client 重建索引後存新 cursor

  rangeRead(entryId, offset, length) -> bytes      // 掃 tag 用
  openStreamUrl(entryId) -> URL                    // 有限時效的直連 URL
  download(entryId, localPath)                     // 釘選下載（可斷點續傳）
  readText(entryId) -> String                      // m3u8（小檔）
}
```

## 2. 錯誤語意（所有方法統一）
| 情境 | 例外 | client 義務 |
|---|---|---|
| token 過期/401 | `AuthError` | 重新 `authenticate()`，重試**一次** |
| 429 / 5xx / 網路 | `TransientError` | 指數退避重試（1s/2s/4s… 上限 60s，最多 5 次） |
| 檔案不存在/404 | `NotFoundError` | 不重試；delta 會補狀態 |

### 2.1 重試政策（可測釘死；fixtures `err_cases/`，三實作 byte-identical）
- `TransientError`：延遲 `1000·2^n` ms（n=0..4 → **1/2/4/8/16s**）。最多 **5 次重試**（含首次共 6 次嘗試）後傳播錯誤。60s 上限在此預算內不觸發（保留給未來調參）。
- `AuthError`：呼叫 `authenticate()` 後**立即**重試一次（無退避）；第二次 `AuthError` → 傳播。重授權與退避**分開計數**（互不佔額度）。
- `NotFoundError`：不重試，立即傳播。
- FakeProvider（in-memory，`err_cases` 驅動）：
  - 呼叫腳本：每次操作從佇列取一個結果（`transient`/`auth`/`notfound`/`ok`），空佇列 = ok。
  - 時脈與 sleep 注入：fixture 記錄實際 sleep 序列與 reauth 次數。

## 3. 各後端落點
| 能力 | Google Drive | Dropbox |
|---|---|---|
| list | `files.list`（全 Drive、q: trashed=false、每頁 1000；path 由 parents 鏈推導——見 §8） | `list_folder` |
| delta | `changes.getStartPageToken` 起的 Changes API | `list_folder/longpoll` + cursor |
| range | `files.get?alt=media` + `Range:` header | `files/get_temporary_link` 的 CDN URL + Range |
| stream | 同 range（seek 靠 Range） | temporary link（4h 有效） |
| rev | `md5Checksum`（內容指紋即 rev；改名不重掃——見 §8.3） | `rev` 欄位 |

本地資料夾後端不在此表 —— 語意獨立定義於 §6。

## 4. 驗證要求（Phase 1 進場條件）
- [ ] 兩後端的 range request 實測（m4a 尾部 tag 依賴 Range 支援；不支援 → m4a 全檔下載，記入已知限制）——**掃描視窗化尚未進場**（§8.5），目前掃描為整檔下載，Range 只在播放/串流用
- [x] delta cursor 失效情境：GDrive 以 fake server 契約覆蓋（`gdrive_cases/gdrive_cursor_reset`）；真帳號複驗待 OAuth 進場
- [x] 配額：GDrive 請求數已釘進契約（每步 `provider.requests`，三實作 byte-identical）；真帳號 5,000 檔量測待 OAuth 進場

## 5. 掃描管線（provider × scanner）
1. `delta`（無 cursor → `listDir` 遞迴建全量）
2. 對新增/變更（rev 或 modifiedAt 變了）的音訊檔：`rangeRead` 頭 64KB；`.m4a` 另外讀尾 64KB
3. 餵 scanner（model.md §1 邏輯），結果入 DB
4. 雲端刪除 → `tracks.available=0`（已釘選檔保留，UI 提示）
5. m3u8 變更 → 重新解析

併發：rangeRead 上限 8；429 時全管線退避。

## 6. LocalFolderProvider（本地資料夾；D10 起為正式 provider）

對象：桌機情境的本地音樂資料夾，兼開發期零網路全管線。實作同一套 §1 介面。

| 方法 | 語意 |
|---|---|
| `id` | 檔案相對路徑（`/` 分隔，同 model.md §2.1 `id=path` 慣例）；目錄僅出現在 listDir entries（`isDir=true`），不參與音訊索引 |
| `rev` | `"{sizeBytes}:{mtimeMs}"`（十進位、無填充） |
| `modifiedAt` | mtime（毫秒） |
| `listDir` | 單層列目錄；entries 依 path 排序；`nextPageToken` 恆 null |
| `delta` | 本地無變更日誌 → 每輪遞迴全量 walk，與 cursor 內嵌的上次快照比對：新 path → added、消失 → removed、rev 變 → modified。cursor 為快照的 opaque 序列化（client 不解析、不比較內容） |
| `rangeRead` | 直讀檔案 offset/length（RandomAccessFile / FileHandle） |
| `openStreamUrl` | 不支援（本地無時效 URL）；App 層直接開本地檔 |
| `download` | 複製到目標路徑 |
| `readText` | 直讀 |
| `authenticate` / `revoke` | no-op |

錯誤語意：本地只有 `NotFoundError`（讀取時檔案已消失）適用；無 401/429 類。

v0 已知限制（釘死）：
- **改名 = removed(舊) + added(新)**（本地無穩定 file id；tag 會重掃）。
- mtime 變但內容未變 → 仍算 modified（rev 含 mtime 的直接後果；保守重掃可接受）。

## 7. 內容指紋與離線重用（D13；schema v0.3）

離線下載層為**內容定址**：副本檔名 = 檔案內容的 SHA-256 hex（`downloads/<sha256>`）。
bytes 相同 = 同一份副本——跨庫共用、只抓一次。釘選記錄（pins 表）按 (root, trackId) 歸屬：
換庫休眠不清、切回即重連（rev 重驗，rev 變 → 重抓）；unpin 以 content_hash 引用計數決定是否刪檔。

- **LocalFolderProvider**：不提供內容指紋；SHA-256 於釘選抓取時計算（邊讀邊算，零額外 IO）。
- **雲端 provider（進場時的硬性要求）**：entries 必須帶原生 checksum——GDrive = `md5Checksum`、
  Dropbox = `content_hash`（皆 list metadata 免費欄位，一 byte 都不用下載）。用途：掃描期即知
  兩軌是否同內容（離線重用預判、重抓決策）；與下載層 SHA-256 的鍵對應在下載時建立
  （md5→sha256 映射的落地形狀，雲端子步驟定案）。

邊界（刻意）：內容定址保證「**同一個檔案**」的重用，不做「同一首歌」的跨版本 mapping——
不同轉檔（FLAC/MP3）視為不同內容，各自下載；跨版本比對需音訊指紋（AcoustID），不在此範圍。

## 8. GDriveProvider（Google Drive；fixtures `gdrive_cases/`，三實作 byte-identical）

對象：使用者 Drive 裡的一個資料夾（root）。OAuth client ID 依 D11 延後——provider 只依賴一個
`TokenSource`（`token()` 取目前 access token、`refresh()` 重授權後給新 token）與一個 `HttpTransport`
（送請求、回 status+body）；契約測試以 in-memory fake Drive（HTTP 語意層）驅動，正式環境接 URLSession / HttpURLConnection。

### 8.1 使用的 API（全部 GET、`Authorization: Bearer <token>`；base `https://www.googleapis.com/drive/v3`）
| 用途 | 請求 |
|---|---|
| 首掃起點 | `GET /changes/startPageToken` → `startPageToken` |
| 全量列舉 | `GET /files?q=trashed%3Dfalse&pageSize=1000&fields=nextPageToken,files(id,name,mimeType,parents,size,md5Checksum,modifiedTime)[&pageToken=…]`（整個 Drive 一次列完，**不是**逐資料夾遞迴——5,000 檔 = 5 個請求） |
| 增量 | `GET /changes?pageToken=…&pageSize=1000&includeRemoved=true&fields=nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,parents,trashed,size,md5Checksum,modifiedTime))` |
| 讀檔（掃描/釘選/串流） | `GET /files/{id}?alt=media`（串流/釘選續傳可加 `Range: bytes=a-b`） |

### 8.2 節點表與 path 推導
provider 持有 **全 Drive 的 id→node 表**（`{id,name,mimeType,parent,trashed,size,md5,modifiedAt}`；多 parent 取 `parents[0]`），
每輪由 changes 增量維護，並以此對引擎輸出 `snapshot()`（path→rev）：
- 只有**非資料夾、非 `application/vnd.google-apps.*`**（Docs/捷徑等無 bytes 者一律排除）的節點成為檔案 entry。
- path = 從節點沿 parent 鏈上溯到 root 的名稱串（不含 root）。鏈上任一節點缺席／`trashed`／名稱含 `/`／鏈無法抵達 root（含環）→ 該節點**不在庫內**。
- 同 path 碰撞（Drive 允許同名）：**id 字典序最小者勝**，其餘忽略（確定性）。
- 資料夾搬進 root 底下 → 整棵子樹自動進庫（節點表是全 Drive 的，不需重列）。

### 8.3 rev 與變更
- `rev = md5Checksum`；缺 md5（理論上只有 Google 文件類，已排除）→ `"{size}:{modifiedAtMs}"`。
- 因此：**改名/搬移 = removed(舊 path) + added(新 path)，rev 不變**（引擎照契約重掃；D13 下載層以 hash 認同一份不重抓）；`modifiedTime` 變但 md5 不變 → 無變更（與本地 provider 相反，雲端可以精確判斷）。
- 增量套用：`removed=true` 或 `file.trashed=true` → 節點刪除；其他 → 節點覆寫。

### 8.4 cursor / reset
- provider 自己的 cursor = `startPageToken`/`newStartPageToken`（連同節點表一起匯出為 opaque 字串，App 層存 `sync_state['cursor:gdrive:<rootId>']`）；引擎的 path→rev cursor 照舊（schema `cursor` 表）。
- 首輪：**先取 startPageToken、再全量列舉**（列舉期間的變更由下輪 changes 補上，不漏）。
- `changes.list` 對舊 token 回 **400/404** → cursor 失效 → `reset=true`：節點表清空、重新走首輪流程（引擎端 rev 未變的檔案照樣不重掃）。

### 8.5 錯誤對應（→ §2.1 RetryPolicy，每個 HTTP 請求各自套用）
| HTTP | 分類 |
|---|---|
| 401 | `AuthError` → `TokenSource.refresh()` 一次後立即重試；再 401 → 傳播 |
| 403（body 含 `rateLimitExceeded`/`userRateLimitExceeded`）、429、5xx、傳輸層失敗 | `TransientError` → 1/2/4/8/16s |
| 404 | `NotFoundError`（讀檔 → 引擎靜默丟棄；changes.list → 視為 cursor 失效） |
| 其他 4xx | 直接傳播（不重試） |

引擎面的續掃語意（sync-rules §3.2-8）：`snapshot()` 失敗 → 整輪 `sync()` 拋錯、索引與 cursor 不動；
單檔 `readBytes` 重試耗盡 → 該檔與**本輪剩餘 pending 全部標 `unscanned`**，其 cursor 項保留上一輪值（或不寫入），
下輪 delta 自然再次列為 added/modified 接續掃描。

已知限制（釘死，後續子步驟處理）：
- **掃描 = 整檔下載**：model.md §1 的 scanner 是整檔語意（ogg 取檔內最後一頁 granule、mp3 時長用 sizeBytes、wav data chunk），
  §5 的「頭 64KB + m4a 尾 64KB」視窗化要先改 model.md 定義視窗語意（含大封面圖把 tag 擠出 64KB 的情境）再進場。
- md5→sha256 對應表（§7）未建：下載層仍在抓取時算 SHA-256；跨庫「抓前預判」留待需要時再加。
