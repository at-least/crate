# 同步衝突規則（sync-rules.md）

> 契約 v0.1。原則：**單人多裝置**，衝突窗口小，規則求簡可預測，寧可丟編輯不鎖死使用者。

## 1. 資料流向總表
| 資料 | 方向 | 真相來源 | 衝突規則 |
|---|---|---|---|
| 音訊檔 | 雲端 → 裝置（唯讀） | 雲端 | 無衝突（app 不改音訊） |
| 專輯/音軌索引 | 雲端 → 裝置（派生） | 掃描結果 | 無衝突（可隨時重掃重建） |
| `.m3u8` 播放清單 | 雙向 | 雲端檔案 | 整檔 LWW（§2） |
| `mu-state.json`（收藏/進度） | 雙向 | 雲端檔案 | 欄位級 LWW（§3） |
| 釘選清單 | 裝置本地 | 不上雲 | 無衝突 |

## 2. m3u8 整檔 LWW
1. 編輯清單 → 寫本地 + 記 `pending`（含 `baseRev`）。
2. 上傳 `putText(path, content, parentRev=baseRev)`：
   - 成功 → pending 清除。
   - `ConflictError` → **拉遠端、遠端蓋本地、丟本地編輯**，但保留被丟編輯為 `<name>.rej.m3u8`（本地 only，不上傳，UI 可見）。
3. 下載時：遠端 rev ≠ 本地 rev 且無 pending → 直接覆蓋本地。
> 已知限制（PLAN §9）：同時雙裝置編輯會丟一邊；單人使用可接受，rej 檔兜底。

## 3. mu-state.json 欄位級 LWW
- 結構見 model.md §3。合併單位：
  - `favorites`：集合聯刪難 → **以元素為單位**：元素帶 `updatedAt`（v1.1 起；v1 陣列無時間 → 整欄 LWW）。
  - `progress[trackId]`：每軌一筆，比 `updatedAt`，新者勝。
  - 頂層 `updatedAt` 僅除錯用，不參與合併。
- 本地播放進度每 5s / 暫停 / 換軌時落本地 DB；上傳 debounce 30s（觸發：背景、app 進背景、手動同步）。
- 下載合併後回寫雲端（合併結果即新真相）。

## 4. 裝置識別
`deviceId` = 首次啟動生成 UUIDv4，存鑰匙串。只用於除錯與未來多裝置 UI。

## 5. 首掃/重掃
- 首掃中途斷網 → 已掃部分保留（部分索引可用），UI 顯示未完成；續掃從未處理 path 接續。
- delta `reset=true` → 全量重建（舊表先標 available=0 再套 changes，交易內完成）。
- 同一檔 rev 未變 → 跳過（斷點續掃的基礎）。

## 6. 測試要求（Phase 3 進場條件，寫進兩平台單元測試）
- [ ] m3u8 衝突：A pending + 雲端已變 → 覆蓋 + rej 檔生成
- [ ] state 合併：雙邊各改不同軌進度 → 兩軌都保留；同軌 → 新者勝
- [ ] favorites v1 整欄 LWW；v1.1 元素級（升級路徑：無 updatedAt → 視為 0）

## 7. 同步引擎（SyncEngine；Phase 1 契約）

引擎 = **純邏輯狀態機**：輸入 provider 的 delta 變更序列，輸出索引狀態。儲存形態（SQLite/Room/記憶體）是實作細節（schema.sql 是 App 層藍圖）；契約釘在「步驟序列 → SyncReport」的 byte 級一致（三實作：Python 參考、Kotlin、Swift）。

### 7.1 索引（Index）
- 只收音訊檔（model.md §1.1 副檔名表）與 `.m3u8`；其餘副檔名不出現在 changes 也不進索引。
- 每軌：最新掃描資料（= model.md §2.1 track 形狀）+ `rev` + `available`。
- playlist 檔 removed → playlist 自索引移除（無 unavailable 態）。

### 7.2 一輪 sync()
1. `delta(cursor)` → changes（added/removed/modified；僅引擎關注的副檔名）。
2. removed → 該軌 `available=0`（掃描資料與 rev 保留最後已知值）；removed 的 path 不在索引 → 靜默忽略（不出 error）。
3. added/modified → 進 pending 佇列（掃描前不可見於索引）。
4. 掃描 pending：`rangeRead` → scanner（model.md §1）→ 寫入索引、`available=1`；m3u8 → 重解析 raw refs。
   - 掃描時 `NotFoundError`（delta 後檔案被拔）→ **靜默丟棄該 pending**：不出 error、不進索引；該輪 changes 照實報（added 已計入）。
5. m3u8 內部只存 raw refs（position/ref/durationMs）；`ref → trackId` 解析在**每次輸出時**對索引內 `available=1` 的音訊 path 集合進行（正規化規則同 model.md §2.3）。音訊可用度變動因此自動反映到清單，無需重讀 m3u8 檔。
6. albums 每輪由索引全量重導（含 unavailable 軌；歸組鍵同 model.md §1.5）；errors = 現存（available 檔案的）BAD_CONTAINER。
7. rev 未變 → 不進 pending（斷點續掃的基礎；以 `scanned` 清單可觀測）。

### 7.3 SyncReport（每輪輸出，契約核心）
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

### 7.4 fixtures（`contract/fixtures/sync_cases/`）
- 共享音訊資產池 `sync_assets/`（生成後 commit；平台測試直接取用位元組，不依賴 ffmpeg）。
- 每案例 `script.json`：步驟序列，ops = `write`（asset 或 text + 顯式 mtime）/ `delete` / `rename` / `touch`（改 mtime）；**mtime 一律整數秒注入**，確保三實作一致。
- `delete_after_delta` op：driver 在該輪 delta 之後、掃描之前刪檔（引擎提供 afterDelta 測試縫），驗 §7.2-4 的靜默丟棄。
- 每步套用 ops → 跑一輪 sync() → 一份 SyncReport；`expected.json` = 依步驟排列的 report 陣列。
- 必覆蓋：首掃（含非音訊檔忽略）、無操作續同步（跳過重掃）、新增/改內容/改 mtime/刪除/改名、m3u8 生滅與 missing ref、掃描中拔檔。
