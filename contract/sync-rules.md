# 增量掃描規則（sync-rules.md）

> 契約 v0.2（D12：唯讀重新定位）。原則：**雲端資料夾為唯一真相，app 是唯讀取用端**。
> 索引可隨時重掃重建；播放清單在雲端管理（app 只讀）；播放進度/收藏為裝置本機資料，不上雲。

## 1. 資料流向總表
| 資料 | 方向 | 真相來源 | 衝突規則 |
|---|---|---|---|
| 音訊檔 | 雲端 → 裝置（唯讀） | 雲端 | 無衝突（app 不改音訊） |
| 專輯/音軌索引 | 雲端 → 裝置（派生） | 掃描結果 | 無衝突（可隨時重掃重建） |
| `.m3u8` 播放清單 | 雲端 → 裝置（唯讀） | 雲端檔案 | 無衝突（清單編輯在雲端進行） |
| 釘選清單 | 裝置本地 | 不上雲 | 無衝突 |
| 播放進度/收藏 | 裝置本地 | 本地 DB（schema.sql `play_state` / `favorites`） | 無衝突（不跨裝置） |

## 2. 首掃/重掃
- 首掃中途斷網 → 已掃部分保留（部分索引可用），UI 顯示未完成；續掃從未處理 path 接續。
- delta `reset=true` → 全量重建（舊表先標 available=0 再套 changes，交易內完成）。
- 同一檔 rev 未變 → 跳過（斷點續掃的基礎）。

## 3. 同步引擎（SyncEngine）

引擎 = **純邏輯狀態機**：輸入 provider 的 delta 變更序列，輸出索引狀態。儲存形態（SQLite/Room/記憶體）是實作細節（schema.sql 是 App 層藍圖）；契約釘在「步驟序列 → SyncReport」的 byte 級一致（三實作：Python 參考、Kotlin、Swift）。

### 3.1 索引（Index）
- 只收音訊檔（model.md §1.1 副檔名表）與 `.m3u8`；其餘副檔名不出現在 changes 也不進索引。
- 每軌：最新掃描資料（= model.md §2.1 track 形狀）+ `rev` + `available`。
- playlist 檔 removed → playlist 自索引移除（無 unavailable 態）。

### 3.2 一輪 sync()
1. `delta(cursor)` → changes（added/removed/modified；僅引擎關注的副檔名）。
2. removed → 該軌 `available=0`（掃描資料與 rev 保留最後已知值）；removed 的 path 不在索引 → 靜默忽略（不出 error）。
3. added/modified → 進 pending 佇列（掃描前不可見於索引）。
4. 掃描 pending：`rangeRead` → scanner（model.md §1）→ 寫入索引、`available=1`；m3u8 → 重解析 raw refs。
   - 掃描時 `NotFoundError`（delta 後檔案被拔）→ **靜默丟棄該 pending**：不出 error、不進索引；該輪 changes 照實報（added 已計入）。
5. m3u8 內部只存 raw refs（position/ref/durationMs）；`ref → trackId` 解析在**每次輸出時**對索引內 `available=1` 的音訊 path 集合進行（正規化規則同 model.md §2.3）。音訊可用度變動因此自動反映到清單，無需重讀 m3u8 檔。
6. albums 每輪由索引全量重導（含 unavailable 軌；歸組鍵同 model.md §1.5）；errors = 現存（available 檔案的）BAD_CONTAINER。
7. rev 未變 → 不進 pending（斷點續掃的基礎；以 `scanned` 清單可觀測）。

### 3.3 SyncReport（每輪輸出，契約核心）
```json
{
  "changes": [ { "kind": "added|removed|modified", "path": "…", "rev": "…" } ],
  "scanned": [ "path", … ],
  "index": { "albums": […], "errors": […], "playlists": […], "tracks": [… ] }
}
```
- track = model.md §2.1 形狀 **加** `"rev"`（字串）與 `"available"`（bool）。
- `changes[].rev`：added/modified = 新 rev；removed = client 最後已知的 rev。
- 排序：changes by (path, kind)；scanned by path；index 內部排序同 model.md §2.2 第 5 條。
- 序列化規則同 model.md §2.2（canonical JSON、`errors[].message` 恆空字串）。

### 3.4 fixtures（`contract/fixtures/sync_cases/`）
- 共享音訊資產池 `sync_assets/`（生成後 commit；平台測試直接取用位元組，不依賴 ffmpeg）。
- 每案例 `script.json`：步驟序列，ops = `write`（asset 或 text + 顯式 mtime）/ `delete` / `rename` / `touch`（改 mtime）；**mtime 一律整數秒注入**，確保三實作一致。
- `delete_after_delta` op：driver 在該輪 delta 之後、掃描之前刪檔（引擎提供 afterDelta 測試縫），驗 §3.2-4 的靜默丟棄。
- 每步套用 ops → 跑一輪 sync() → 一份 SyncReport；`expected.json` = 依步驟排列的 report 陣列。
- 必覆蓋：首掃（含非音訊檔忽略）、無操作續同步（跳過重掃）、新增/改內容/改 mtime/刪除/改名、m3u8 生滅與 missing ref、掃描中拔檔。
