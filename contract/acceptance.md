# 驗收清單（acceptance.md）

> 每條可機器查 or 需人（耳朵/真機）。Phase 定義見 PLAN.md §7。

## Phase 0（契約）— ✅ 2026-08-27 完成
> A4 註記：Linux Swift 6.1 與 macOS（Swift 6.2.4, arm64）皆已驗證通過（2026-08-27）。Mac 端需 Package.swift 宣告 platforms（macOS 13 / iOS 16），否則 `read(upToCount:)` 等會被 SwiftPM 舊預設 deploy target 擋下（Linux 無 availability 檢查，故當時只綠在 Linux）。
- [A1] `contract/` 五文件 + schema.sql 齊全（機器：檔案存在）
- [A2] fixtures ≥ 20 案例，每案例 `lib/` + `expected.json`（機器：產生器跑完 0 diff）
- [A3] Android：`./gradlew :core:test` 全綠（機器：本 Linux 機）
- [A4] Apple：`swift test`（MuCore）全綠（機器：**Mac**，使用者跑）
- [A5] 兩平台輸出與 `expected.json` byte-identical（A3/A4 內含）

## Phase 1（Android MVP）
- [B0] 同步引擎契約（sync-rules §3；sync_cases 6 案例）Python/Kotlin/Swift 三方 byte-identical — ✅ 2026-08-27（機器；CI 三 job）
- [B1] core 契約測試仍全綠（CI）
- [B2] emulator：掃描 500 張專輯模擬資料 < 5 分鐘（機器）
- [B3] 真機：選本地音樂資料夾 → 首掃 → 專輯網格出現（人；GDrive 接通後複驗同項）
- [B4] 真機：點歌播放 → 鎖屏控制 → 藍牙耳機暫停/續播（人耳）
- [B5] 真機：釘選專輯 → 飛航模式 → 播放正常（人）
- [B6] 真機：專輯連播接縫無爆音（人耳）
- [B7] m3u8 清單出現且可播（人 + 機器：清單契約測試）

### Phase 1 補充：GDrive provider（子步驟 4；OAuth 依 D11 延後）
- [B8] GDrive provider 契約（provider.md §8；`gdrive_cases/` 7 案例：首掃/分頁/變更/reset/重試/續掃/同名碰撞）Python/Kotlin/Swift 三方 byte-identical — ✅ 2026-08-29（機器；CI 三 job）
- [B8b] 掃描視窗化（model.md §1.8）：scanner 經 ChunkedReader 只抓需要的 chunk；`gdrive_windowed_scan` 三檔（moov 在尾 m4a／大封面 FLAC／大 APIC MP3）各 2 個 Range 請求，三方 byte-identical；26 scanner + 6 sync cases 輸出不變 — ✅ 2026-08-29（機器）
- [B8c] OAuth + PKCE 核心（provider.md §10；`oauth_cases/` 三方 byte-identical + 兩平台 RefreshingTokenSource 行為測試） — ✅ 2026-08-29（機器）
- [B9] 真帳號：填入 client ID → 登入 → 索引與本地資料夾一致；Range 支援與 5,000 檔請求數量測（人 + 機器；待 OAuth 進場）

## Phase 2（Apple MVP）
- [C1] `swift test` 契約測試全綠（Mac）— ✅ 2026-08-28（機器；Swift 6.2.4 / macOS 15）
- [C1b] （補充項）iOS app 模擬器 UI 測試：掃描→瀏覽→點播→佇列推進、專輯釘選→離線標記→重啟 DB 還原 — ✅ 2026-08-28（機器；`xcodebuild test`，B3/B5 的 iOS 等效覆蓋）
- [C2] Cmd+R → 同一個 Drive 帳號 → 索引與 Android 一致（人，對照兩機專輯數；GDrive 依 D11 延後——本地資料夾情境已覆蓋，Drive 接通後複驗）
- [C3] 鎖屏/Control Center 控制、AirPlay 可用（人；實作已就位：MPNowPlayingInfoCenter/MPRemoteCommandCenter/AVRoutePickerView/UIBackgroundModes=audio）
- [C4] B4–B6 同清單在 iPhone 複驗（人耳）

## Phase 3（擴充，選配；D12 後原「同步閉環」相位取消）
- [D1] Dropbox provider 讀同一庫：契約測試綠（provider.md §9；`dropbox_cases/` 三方 byte-identical）— ✅ 2026-08-29 核心層（機器）；掃描同一資料夾索引與 GDrive 一致（人）— 依 D11 隨 OAuth 申請延後
- [D2] macOS app（選單列常駐）播放同一庫（人，Mac）— 2026-08-28 實作上線（MuMac：選單列 popover、瀏覽/播放/釘選；MU_ROOT 冒煙已驗掃描落庫與 root 持久化）；真機點開選單列確認屬人驗

## 通用品質門檻（每 Phase 結束跑）
- core 模組測試覆蓋率 ≥ 90%（機器：jacoco / swift-coverage）— ✅ 2026-08-28 Phase 2：MuCore 98.51% 行覆蓋（llvm-cov export；CoverageGapTest 補齊契約 fixtures 未走到的分支）
- 無未解釋的契約 diff（機器：CI）

## Phase 4（打磨）
- [E1] ReplayGain：契約 model.md §1.9（`replaygain_tags` 案例三方 byte-identical）+ 兩平台播放器依模式套音量（off/track/album）— ✅ 2026-08-29 機器（契約 + 建置 + iOS UI 測試）；真機聽感（衰減是否正確、切模式即時生效）屬人
- [E2] CarPlay（人；需 entitlement）
- [E3a] Widget 契約（model.md §1.11 `nowplaying_cases/` 三方 byte-identical）+ Android Glance widget（顯示字串 JVM 測試） — ✅ 2026-08-29 機器；主畫面實際加入與顯示屬人
- [E3b] iOS/macOS WidgetKit widget — 待 App Group 能力確認（付費開發者帳號）
- [E4] EQ / 正增益放大：契約 model.md §1.10（`eq_cases/` 三方 byte-identical）+ 兩平台 DSP 接線（Apple MTAudioProcessingTap／Android Media3 AudioProcessor）與性質測試 — ✅ 2026-08-29 機器（契約 + DSP 性質 + Android buffer 層 + iOS 播放 UI 測試）；聽感（各 preset 是否合理、正增益是否過度削峰）屬人
