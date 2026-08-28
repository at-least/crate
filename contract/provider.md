# Provider 介面語意（provider.md）

> 契約 v0.1。實作於 MuCore(swift) / mu-core(kotlin)。v0 只釘**語意**；類別簽名各語言自便。

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
| list | `files.list`（q: parent + trashed=false） | `list_folder` |
| delta | `changes.listPageToken` 起的 Changes API | `list_folder/longpoll` + cursor |
| range | `files.get?alt=media` + `Range:` header | `files/get_temporary_link` 的 CDN URL + Range |
| stream | 同 range（seek 靠 Range） | temporary link（4h 有效） |
| rev | `files.get` 的 `id`+`version` | `rev` 欄位 |

本地資料夾後端不在此表 —— 語意獨立定義於 §6。

## 4. 驗證要求（Phase 1 進場條件）
- [ ] 兩後端的 range request 實測（m4a 尾部 tag 依賴 Range 支援；不支援 → m4a 全檔下載，記入已知限制）
- [ ] delta cursor 失效情境實測（人工改 cursor 觸發 reset）
- [ ] 配額：首掃 5,000 檔的請求數量測（Drive changes/list 每頁 1000；Dropbox list_folder 每頁 2000）

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
