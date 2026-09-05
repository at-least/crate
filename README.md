# Crate

個人雲端音樂庫播放器（Dropbox / Google Drive 當後端，**唯讀**——見 PLAN D12）。iOS + macOS（Swift）、Android（Kotlin）。

Crate 是三個倉庫。這裡是中樞：它放兩套核心共同實作的規格與黃金測試檔，兩端的行為因此不會各走各的。

| 倉庫 | 內容 |
| --- | --- |
| [`crate`](https://github.com/at-least/crate) | 中樞——契約規格、黃金 fixtures、計畫書、圖示原稿 |
| [`crate-apple`](https://github.com/at-least/crate-apple) | iOS + macOS app——SwiftUI，CrateCore / CrateKit 共用引擎 |
| [`crate-android`](https://github.com/at-least/crate-android) | Android app——Kotlin core（純 JVM）+ Compose、Media3、Room |

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
    cases/         27 個掃描器案例
    sync_cases/    6 個同步引擎案例（+ sync_assets/ 共享音訊資產）
    err_cases/     錯誤語意案例（重試政策）
design/icon/ 圖示原稿（SVG 主圖 + 兩平台匯出）
docs/        雲端 provider 的申請設定筆記
```

## 兩端怎麼吃到契約

`crate-apple` 與 `crate-android` 各自把本倉庫掛成 submodule，放在自己根目錄的 `crate/`，
測試便以 `crate/contract/fixtures/…` 找到黃金檔。三個倉庫並排 clone 在同一層時，
就算 submodule 沒 init，測試往上層走一樣找得到 `crate/contract/`。

## 跑測試

| 端 | 指令 | 狀態 |
|---|---|---|
| 掃描器（重掃比對） | `python3 contract/fixtures/generate.py --check`（無 ffmpeg，CI 用） | ✅ 27 案例 |
| 掃描器（參考實作重產） | `python3 contract/fixtures/generate.py`（需 ffmpeg；破壞性，先刪 `cases/`） | 產物已 commit，平時不跑 |
| 同步引擎（參考實作重放） | `python3 contract/fixtures/sync_generate.py --check`（無 ffmpeg，CI 用） | ✅ 6 案例 |
| 錯誤語意（重試重放） | `python3 contract/fixtures/err_generate.py --check`（無 ffmpeg，CI 用） | ✅ 7 條目 |
| Android core | `crate-android` 倉庫：`./gradlew :core:test` | ✅ 全綠 |
| Apple CrateCore | `crate-apple` 倉庫：`cd CrateCore && swift test` | ✅ macOS（Swift 6.2.4, arm64）+ Linux Swift 6.1 雙驗通過（2026-08-27） |

## 鐵律

1. 改掃描/同步行為 = 先改本倉庫的 `contract/`（spec + fixtures），推上來之後在兩端
   `git submodule update --remote crate` 把指標推進、連同實作一起 commit，兩邊測試都要綠。
   （submodule 是釘死的：兩端跑測試吃的是自己釘的那個 commit，不是你本機 hub 的未推內容。）
2. fixtures 的 `expected.json` 由 `generate.py` 產出，不手改。
3. `errors[].message` 是實作自由文字，契約比對時恆為空字串。
