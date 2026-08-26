# 驗收清單（acceptance.md）

> 每條可機器查 or 需人（耳朵/真機）。Phase 定義見 PLAN.md §7。

## Phase 0（契約）— ✅ 2026-08-27 完成
> A4 註記：Swift 測試已在 Linux Swift 6.1 驗證通過；Mac 上 `swift test` 重跑一次即完成二次確認（兩邊 Foundation 實作不同）。
- [A1] `contract/` 五文件 + schema.sql 齊全（機器：檔案存在）
- [A2] fixtures ≥ 20 案例，每案例 `lib/` + `expected.json`（機器：產生器跑完 0 diff）
- [A3] Android：`./gradlew :core:test` 全綠（機器：本 Linux 機）
- [A4] Apple：`swift test`（MuCore）全綠（機器：**Mac**，使用者跑）
- [A5] 兩平台輸出與 `expected.json` byte-identical（A3/A4 內含）

## Phase 1（Android MVP）
- [B1] core 契約測試仍全綠（CI）
- [B2] emulator：掃描 500 張專輯模擬資料 < 5 分鐘（機器）
- [B3] 真機：Drive OAuth → 首掃 → 專輯網格出現（人）
- [B4] 真機：點歌播放 → 鎖屏控制 → 藍牙耳機暫停/續播（人耳）
- [B5] 真機：釘選專輯 → 飛航模式 → 播放正常（人）
- [B6] 真機：專輯連播接縫無爆音（人耳）
- [B7] m3u8 清單出現且可播（人 + 機器：清單契約測試）

## Phase 2（Apple MVP）
- [C1] `swift test` 契約測試全綠（Mac）
- [C2] Cmd+R → 同一個 Drive 帳號 → 索引與 Android 一致（人，對照兩機專輯數）
- [C3] 鎖屏/Control Center 控制、AirPlay 可用（人）
- [C4] B4–B6 同清單在 iPhone 複驗（人耳）

## Phase 3（同步閉環）
- [D1] m3u8 衝突測試組（sync-rules §6）綠（機器）
- [D2] A 裝置建清單 → B 裝置 ≤60s 出現（人，雙機）
- [D3] A 播到一半 → B 接續同位置 ≤30s（人，雙機）

## 通用品質門檻（每 Phase 結束跑）
- core 模組測試覆蓋率 ≥ 90%（機器：jacoco / swift-coverage）
- 無未解釋的契約 diff（機器：CI）
