# Mu

個人雲端音樂庫播放器（Dropbox / Google Drive 當後端，**唯讀**——見 PLAN D12）。iOS + macOS（Swift）、Android（Kotlin）。
計畫書見 [PLAN.md](PLAN.md)。

## 倉庫結構

```
contract/    兩套核心的共同規格（唯一事實來源）
  schema.sql       SQLite schema
  model.md         資料模型 + 掃描器 + canonical JSON 規格
  provider.md      雲端 provider 介面語意（§6 本地資料夾）
  sync-rules.md    增量掃描規則（§3 同步引擎；唯讀）
  acceptance.md    各 Phase 驗收清單
  fixtures/        黃金測試案例（含 Python 參考實作 generate.py / sync_generate.py）
    cases/         26 個掃描器案例
    sync_cases/    6 個同步引擎案例（+ sync_assets/ 共享音訊資產）
    err_cases/     錯誤語意案例（重試政策）
android/     Kotlin core（純 JVM，跑契約測試）+ Compose app（Media3 播放 + Room 索引持久化）
apple/       MuCore Swift package（跑契約測試）+ 之後的 iOS/macOS app
```

## 跑測試

| 端 | 指令 | 狀態 |
|---|---|---|
| 契約（參考實作重產） | `python3 contract/fixtures/generate.py`（需 ffmpeg） | ✅ 26 案例 |
| 同步引擎（參考實作重放） | `python3 contract/fixtures/sync_generate.py --check`（無 ffmpeg，CI 用） | ✅ 6 案例 |
| 錯誤語意（重試重放） | `python3 contract/fixtures/err_generate.py --check`（無 ffmpeg，CI 用） | ✅ 7 條目 |
| Android core | `cd android && ./gradlew :core:test` | ✅ 全綠 |
| Apple MuCore | `cd apple/MuCore && swift test` | ✅ macOS（Swift 6.2.4, arm64）+ Linux Swift 6.1 雙驗通過（2026-08-27） |

## 鐵律

1. 改掃描/同步行為 = 先改 `contract/`（spec + fixtures），再改兩邊實作，兩邊測試都要綠。
2. fixtures 的 `expected.json` 由 `generate.py` 產出，不手改。
3. `errors[].message` 是實作自由文字，契約比對時恆為空字串。
