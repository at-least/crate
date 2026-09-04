# Provider 介面語意（provider.md）

> 契約 v0.5（§8 GDrive、§9 Dropbox、§10 OAuth+PKCE、§11 SFTP/SMB）。實作於 CrateCore(swift) / crate-core(kotlin)。v0 只釘**語意**；類別簽名各語言自便。

## 1. 介面

```
CloudProvider {
  id: String                      // "gdrive" | "dropbox" | "local" | "sftp" | "smb"
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

本地資料夾後端不在此表 —— 語意獨立定義於 §6。SFTP／SMB 亦不在此表 —— §11。
§6 與 §11 同屬**檔案系統型 provider**：無伺服器端變更日誌（delta = 全量 walk 比對快照）、
無原生內容指紋（rev = size:mtime）。差別只在傳輸與認證。

## 4. 驗證要求（Phase 1 進場條件）
- [x] 掃描視窗化：Range 讀取契約化（§5、model.md §1.8；`gdrive_cases/gdrive_windowed_scan` 以 moov 在尾的 m4a／大封面 FLAC／大 APIC MP3 驗證只抓需要的 chunk）；真帳號 Range 支援複驗待 OAuth 進場（Drive 官方支援 Range；不支援時 200 整檔本地裁切仍正確）
- [x] delta cursor 失效情境：GDrive 以 fake server 契約覆蓋（`gdrive_cases/gdrive_cursor_reset`）；真帳號複驗待 OAuth 進場
- [x] 配額：GDrive 請求數已釘進契約（每步 `provider.requests`，三實作 byte-identical）；真帳號 5,000 檔量測待 OAuth 進場

## 5. 掃描管線（provider × scanner）
1. `delta`（無 cursor → 全量列舉）→ path→rev 快照；引擎比對出 added/modified/removed。
2. 對 added/modified 的音訊檔與 m3u8：`open(path) -> ByteSource`（`size` + `read(offset, length)`；不存在 → null，引擎靜默丟棄）。
3. 掃描器經 `ChunkedReader`（model.md §1.8：64 KiB 對齊 chunk、每 chunk 抓一次）只讀結構需要的位元組——雲端 = `files.get?alt=media` + `Range: bytes=a-b`（206；伺服器回 200 整檔則本地裁切），每個 chunk 一個請求；典型檔案（tag 在檔頭）= 1 個請求，moov 在檔尾的 m4a / 大封面 = 2 個。
4. 結果入索引；雲端刪除 → `tracks.available=0`（已釘選檔保留，UI 提示）；m3u8 變更 → 重新解析。

併發：rangeRead 上限 8；429 時全管線退避（App 層節流，契約 fixtures 為單執行緒序列）。

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

- **檔案系統型 provider（§6 本地、§11 SFTP/SMB）**：不提供內容指紋；SHA-256 於釘選抓取時計算
  （邊讀邊算，零額外 IO）。§11 的兩個協定各自都沒有「免費附贈的內容雜湊」——SFTP 要跑遠端
  `md5sum` 才有（等於讀完整檔，不比自己算便宜且未必可用），SMB 根本沒有——所以走與本地相同的規則，
  不是雲端那條。**下一段對雲端 provider 的硬性要求不適用於它們。**
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
| 讀檔（掃描/釘選/串流） | `GET /files/{id}?alt=media` + `Range: bytes=a-b`（掃描 = 64 KiB chunk；串流/釘選續傳同一端點） |

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
- ~~掃描 = 整檔下載~~ → 已視窗化（§5、model.md §1.8，2026-08-29）。
- md5→sha256 對應表（§7）未建：下載層仍在抓取時算 SHA-256；跨庫「抓前預判」留待需要時再加。

## 9. DropboxProvider（Dropbox；fixtures `dropbox_cases/`，三實作 byte-identical）

對象：使用者 Dropbox 裡的一個資料夾（root：路徑如 `/Music`、`id:…`、或 `""` = 整個 Dropbox）。與 §8 同構：
`TokenSource` + `HttpTransport` 注入；§2.1 重試逐請求套用；`open()` 給 ByteSource（model.md §1.8 視窗化）。

### 9.1 使用的 API（全部 POST、`Authorization: Bearer <token>`）
| 用途 | 請求 |
|---|---|
| root 解析 | `api.dropboxapi.com/2/files/get_metadata` `{"path": root}` → `path_lower`/`path_display`（root=`""` 時免呼叫，prefix = `""`） |
| 首掃起點 | `/2/files/list_folder/get_latest_cursor` `{"path": root, "recursive": true, "include_deleted": false, "limit": 2000}` → `cursor` |
| 全量列舉 | `/2/files/list_folder`（同參數）→ `entries/cursor/has_more`；`has_more` → `/2/files/list_folder/continue` `{"cursor"}` |
| 增量 | `/2/files/list_folder/continue` `{"cursor"}`（迴圈至 `has_more=false`） |
| 讀檔 | `content.dropboxapi.com/2/files/download`，header `Dropbox-API-Arg: {"path": "<id>"}` + `Range: bytes=a-b`（206；200 整檔則本地裁切） |

### 9.2 節點表與 path
- 節點表 = root 底下的**檔案**（key = `path_lower`；Dropbox 路徑不分大小寫，無同 path 碰撞問題），值含 `path_display`、`id`、`size`、`content_hash`、`server_modified`。資料夾 entry 不入表。
- 引擎 path = `path_display` 去掉 root 的 `path_display` 前綴（root=`""` 時去掉開頭 `/`）。
- 增量套用：`file` → 覆寫；`deleted` → 刪該 `path_lower` **及其所有 `path_lower + "/"` 前綴的子項**（Dropbox 刪資料夾只回資料夾一筆 deleted）；`folder` → 忽略。

### 9.3 rev
- `rev = content_hash`（Dropbox 內容指紋：4MB 分塊 SHA-256 再 SHA-256，hex）；缺 → `rev` 欄位。語意同 §8.3：改名/搬移 = removed+added 且 rev 不變、`server_modified` 變內容不變 = 無變更。

### 9.4 cursor / reset
- 首輪先 `get_latest_cursor` 再全量列舉（列舉期間的變更由下輪 continue 補上）。
- `continue` 回 **409 且 error tag `reset`** → cursor 失效 → `reset=true`：節點表清空、重走首輪。

### 9.5 錯誤對應（→ §2.1）
| HTTP | 分類 |
|---|---|
| 401 | `AuthError` |
| 429、5xx、傳輸層失敗 | `TransientError` |
| 409 body 含 `not_found` | `NotFoundError`（讀檔 → 靜默丟棄；get_metadata → root 不存在，傳播） |
| 409 body 含 `reset`（continue） | cursor 失效（§9.4） |
| 其他 4xx / 409 | 直接傳播 |

fixtures 與 §8 同形（`{provider: {requests, reauths, sleeps, reset, unscanned, error}, report}`）；FakeDropbox 為 HTTP 語意層 in-memory（含 content_hash 計算與 Range）。

## 10. OAuth 2.0 + PKCE 與 token 生命週期（fixtures `oauth_cases/`，三實作 byte-identical）

app 唯讀取用使用者雲端，一律走 **Authorization Code + PKCE**（無 client secret 於行動端；桌面 loopback 亦同）。
只有「開瀏覽器讓使用者同意」屬平台（ASWebAuthenticationSession／Custom Tab），其餘（URL 組裝、challenge、
token 交換/更新、過期判定、錯誤語意）全在核心層，可測。

### 10.1 端點與參數（`OAuthConfig`）
| 欄位 | GDrive | Dropbox |
|---|---|---|
| `authorizeUrl` | `https://accounts.google.com/o/oauth2/v2/auth` | `https://www.dropbox.com/oauth2/authorize` |
| `tokenUrl` | `https://oauth2.googleapis.com/token` | `https://api.dropboxapi.com/oauth2/token` |
| `scope` | `https://www.googleapis.com/auth/drive.readonly` | `files.metadata.read files.content.read` |
| 額外授權參數 | `access_type=offline`、`prompt=consent`（確保拿到 refresh token） | `token_access_type=offline` |

`redirectUri`：行動端用自訂 scheme（`at.least.crate.ios:/oauth2redirect`、`at.least.crate.android:/oauth2redirect`），
桌面/開發機用 loopback（`http://127.0.0.1:<port>/callback`）。

### 10.2 PKCE
- `codeVerifier`：43–128 字元、字元集 `A-Za-z0-9-._~`（平台以密碼學亂數產生；契約不釘產生器，只釘轉換）。
- `codeChallenge = base64url(SHA-256(verifier))`，**去尾端 `=`**，`+`→`-`、`/`→`_`；`code_challenge_method=S256`。
- 授權 URL 查詢參數順序**固定**（契約可比對）：
  `client_id, code_challenge, code_challenge_method, redirect_uri, response_type=code, scope, state` + 該後端的額外參數（依上表順序附在最後）。
  百分比編碼：未保留字元 `A-Za-z0-9-._~` 原樣，其餘一律 `%XX`（大寫十六進位；空白為 `%20`，不是 `+`）。

### 10.3 回呼與 token
- 回呼 URL 解析：取 `code`／`state`／`error`；`state` 與送出值不符 → `state_mismatch`（視為授權失敗，不重試）。
- 交換：`POST tokenUrl`，`application/x-www-form-urlencoded`，欄位序固定
  `client_id, code, code_verifier, grant_type=authorization_code, redirect_uri`。
- 更新：欄位序固定 `client_id, grant_type=refresh_token, refresh_token`。
- 回應解析 → `TokenState { accessToken, refreshToken, expiresAtMs, scope }`：
  `expiresAtMs = nowMs + expires_in×1000`（`expires_in` 缺 → 視為 0，即立刻過期）；
  **回應沒有 `refresh_token` → 沿用既有的**（Google 的 refresh 回應不重發）。
- 過期判定：`needsRefresh(nowMs) = nowMs + skewMs ≥ expiresAtMs`，`skewMs` 預設 **60000**（提前一分鐘換）。
- token 端點錯誤：body 的 `error` = `invalid_grant`／`invalid_client`／`unauthorized_client` → `AuthError`
  （**需使用者重新授權**，不重試）；HTTP 429/5xx/傳輸失敗 → `TransientError`（套 §2.1 退避）；其餘 4xx → 傳播。
- 儲存：token 存平台鑰匙串（iOS/macOS Keychain、Android EncryptedSharedPreferences）；
  **不進 DB、不進 repo**（client secret 於桌面 loopback 情境走 `.env`，已 gitignore）。

## 11. RemoteFsProvider（SFTP / SMB；fixtures `remotefs_cases/`，三實作 byte-identical）

對象：自架主機或 NAS 上的一個資料夾。與 §6 同族（見 §3 註），與 §8/§9 的差別只在傳輸與認證：
沒有 OAuth、沒有伺服器端 cursor、沒有原生內容指紋。核心層只依賴一個 `FsTransport`（協定操作）
與一個 `CredentialSource`（憑證）；契約測試以 in-memory `FakeRemoteFs` 驅動，正式環境接各平台的 SFTP/SMB 客戶端。

```
FsTransport {
  connect()                            // 建 session；憑證被拒 → AuthError；網路/協商失敗 → TransientError
  disconnect()
  listDir(path) -> [FsEntry]           // 單層；不存在 → NotFoundError
  read(path, offset, length) -> bytes  // 短讀 = 已到檔尾；不存在 → NotFoundError
}
FsEntry { name, isDir, isSymlink, sizeBytes, mtimeMs }
CredentialSource { credential(); invalidate() }   // invalidate = 標記需重取（重問使用者或重讀鑰匙串）
```

### 11.1 與 §6 的對照（相同者不重述）
| 方法 | 語意 |
|---|---|
| `id` / `rev` / `modifiedAt` | **同 §6**（`id` = 相對 root 路徑；`rev = "{sizeBytes}:{mtimeMs}"`；mtime 毫秒） |
| `delta` / cursor | **同 §6**：無變更日誌 → 每輪全量 walk 與 cursor 內嵌的上次快照比對；cursor 為快照的 opaque 序列化 |
| `listDir` | 單層列目錄；`nextPageToken` 恆 null（兩協定都無分頁） |
| `rangeRead` | `read(path, offset, length)`；掃描經 ChunkedReader 每 chunk 一次呼叫（同 §5，64 KiB 對齊） |
| `download` | 自 offset 0 順序 read 至短讀（可斷點續傳：從已寫入長度接續） |
| `readText` | 整檔 read |
| `openStreamUrl` | **不支援**（兩協定都無時效 URL）；同 §6 交給 App 層決定（釘選後播本地檔，或以本機轉接串流） |
| `authenticate` / `revoke` | `connect()` ／ `disconnect()` + 清除鑰匙串憑證（§11.5） |

### 11.2 walk 與 snapshot（釘死；`remotefs_cases/` 三實作 byte-identical）
- 自 root **深度優先前序**遞迴，每個目錄一次 `listDir`。
- 每層 entries 依 `name` 的 **UTF-8 位元組序**排序（等價於 code point 序；刻意不用各語言的預設字串比較——
  Kotlin 的 UTF-16 code unit 序與 code point 序在 BMP 外不一致）。此順序唯一可觀察處是 `listDir` 呼叫序列，fixtures 有記錄。
- **symlink（SFTP）／reparse point（SMB）一律忽略**：不跟隨、不入庫。理由是迴圈與跨檔案系統邊界，v0 不處理。
- **遞迴深度上限 64**（root 為 0）；超過的子樹整棵忽略，不拋錯。
- 名稱含 `/`，或為 `.` / `..` / 空字串 → 忽略該項（防惡意或壞掉的伺服器）。
- walk 中途某個目錄 `NotFoundError`（掃描期間被刪）→ 該子樹視為空，**不中斷整輪**；其他錯誤照 §11.4 處理。

刻意與 §6 一致而非「最佳化」的一點：**不跳過隱藏檔或 NAS 的中繼目錄**（`.git`、`@eaDir`、`#recycle`…）。
同一個資料夾不論用哪個 provider 讀，索引都該一樣；省 round-trip 的最佳化留待有實測需求再談。

### 11.3 rev 與變更（同 §6，複述是因為與 §8/§9 相反）
- 改名／搬移 = **removed(舊 path) + added(新 path)**，且 rev 不變（遠端檔案系統無穩定 file id）。
- mtime 變、內容未變 → 仍算 modified（rev 含 mtime 的直接後果；保守重掃）。
- 無伺服器端 cursor → **`reset` 恆為 false**（沒有會失效的東西）。

### 11.4 錯誤對應（→ §2.1 RetryPolicy，每個 `FsTransport` 操作各自套用）
| 情境 | 分類 |
|---|---|
| 憑證被拒（SFTP 認證階段失敗；SMB `STATUS_LOGON_FAILURE` / `STATUS_ACCESS_DENIED`） | `AuthError` → `CredentialSource.invalidate()` 後**重連一次**立即重試；再失敗 → 傳播 |
| 連線中斷、逾時、DNS 失敗、連線被拒、SMB `STATUS_*_DISCONNECTED` | `TransientError` → 1/2/4/8/16s（§2.1）；**每次重試前先重連 session** |
| 檔案／目錄不存在（SFTP `SSH_FX_NO_SUCH_FILE`；SMB `STATUS_OBJECT_NAME_NOT_FOUND` / `STATUS_OBJECT_PATH_NOT_FOUND`） | `NotFoundError`（讀檔 → 引擎靜默丟棄） |
| 其他協定錯誤 | 直接傳播（不重試） |

連線生命週期：**一輪 sync 共用同一個 session**。重連不另計預算——它是 `TransientError` 退避的一部分
（`AuthError` 那次重連則走重授權額度，與退避分開計數，同 §2.1）。

### 11.5 憑證與主機驗證
- 憑證存平台鑰匙串（iOS/macOS Keychain、Android EncryptedSharedPreferences），key = `<id>://<user>@<host>:<port>`；
  **不進 DB、不進 repo**（同 §10.3）。DB 只存非機密的連線描述：host、port、user、share、root path。
- **SFTP 主機金鑰 TOFU**：首次連線記下指紋（SHA-256，base64 無填充），存 `sync_state['hostkey:<host>:<port>']`。
  之後不符 → `AuthError`（**不是** `TransientError`——這要使用者確認，不該自動重試吞掉）。

### 11.6 SFTP 專屬
- SSH-2 + SFTP subsystem，protocol version 3 起。
- 路徑**大小寫敏感**；節點表 key 即引擎 path。
- 憑證形式：密碼，或私鑰（OpenSSH 格式，可帶 passphrase）。
- root 表示法：`sftp://user@host:port/絕對路徑`（省略 port = 22）。

### 11.7 SMB 專屬
- **SMB 2.1 起**；SMB1 不支援（協定本身已不安全，且各家預設關閉）。
- root 表示法：`smb://user@host/share/子路徑`（share 與其下路徑分離；省略 port = 445）。
- 路徑**不分大小寫**：節點表 key = path 的小寫（同 §9.2 Dropbox `path_lower` 慣例），
  值保留伺服器回報的原始大小寫作為引擎 path。
- 同一目錄下僅大小寫不同的兩個名稱（伺服器理論上不允許，跨平台 share 仍可能出現）→
  **UTF-8 位元組序最小者勝**，其餘忽略（同 §8.2 碰撞規則的精神）。
- 憑證：user / password，可選 domain；guest = 空密碼。

### 11.8 fixtures 形狀
與 §8/§9 同形：每步 `{provider: {error, reauths, connects, listDirs, reads, sleeps, unscanned}, report}`。
`FakeRemoteFs` 是協定語意層的 in-memory 樹（含 symlink 旗標、大小寫模式、腳本化故障佇列
`auth`/`disconnect`/`notfound`/`ok`），三實作各自複製同一份語意，Python 版為參考實作。

真伺服器（真的 sshd／samba）不是契約測試的一部分——列在 acceptance.md 當人工驗收。
