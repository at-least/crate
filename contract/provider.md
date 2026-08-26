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
  readText(entryId) -> String                      // m3u8 / mu-state.json（小檔）
  putText(path, content, parentRev?) -> Entry      // 寫回；parentRev 衝突 → ConflictError
}
```

## 2. 錯誤語意（所有方法統一）
| 情境 | 例外 | client 義務 |
|---|---|---|
| token 過期/401 | `AuthError` | 重新 `authenticate()`，重試**一次** |
| 429 / 5xx / 網路 | `TransientError` | 指數退避重試（1s/2s/4s… 上限 60s，最多 5 次） |
| 檔案不存在/404 | `NotFoundError` | 不重試；delta 會補狀態 |
| rev 衝突（putText） | `ConflictError` | 走 sync-rules.md §2 衝突規則 |

## 3. 各後端落點
| 能力 | Google Drive | Dropbox |
|---|---|---|
| list | `files.list`（q: parent + trashed=false） | `list_folder` |
| delta | `changes.listPageToken` 起的 Changes API | `list_folder/longpoll` + cursor |
| range | `files.get?alt=media` + `Range:` header | `files/get_temporary_link` 的 CDN URL + Range |
| stream | 同 range（seek 靠 Range） | temporary link（4h 有效） |
| rev | `files.get` 的 `id`+`version` | `rev` 欄位 |
| put | `files.update`（含衝突偵測） | `files/upload` mode=update + parent_rev |

## 4. 驗證要求（Phase 1 進場條件）
- [ ] 兩後端的 range request 實測（m4a 尾部 tag 依賴 Range 支援；不支援 → m4a 全檔下載，記入已知限制）
- [ ] delta cursor 失效情境實測（人工改 cursor 觸發 reset）
- [ ] 配額：首掃 5,000 檔的請求數量測（Drive changes/list 每頁 1000；Dropbox list_folder 每頁 2000）

## 5. 掃描管線（provider × scanner）
1. `delta`（無 cursor → `listDir` 遞迴建全量）
2. 對新增/變更（rev 或 modifiedAt 變了）的音訊檔：`rangeRead` 頭 64KB；`.m4a` 另外讀尾 64KB
3. 餵 scanner（model.md §1 邏輯），結果入 DB
4. 雲端刪除 → `tracks.available=0`（已釘選檔保留，UI 提示）
5. m3u8/mu-state.json 變更 → 重新解析/合併

併發：rangeRead 上限 8；429 時全管線退避。
