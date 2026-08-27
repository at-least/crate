# Google Drive OAuth 設定（Phase 1 前置）

> 2026-08-27 依 Google 官方文件查證後撰寫。在 Google Cloud Console 操作，約 10 分鐘。

## 步驟

1. **建專案**：[console.cloud.google.com](https://console.cloud.google.com/) → 新專案 `Mu`
2. **啟用 API**：APIs & Services → Library → **Google Drive API** → Enable
3. **OAuth 同意畫面**（Google Auth Platform）：
   - User type：**External**
   - App name：`Mu`；email 填自己
   - Scopes 手動加入：
     - `https://www.googleapis.com/auth/drive.readonly` — 掃整個音樂庫（restricted）
     - `https://www.googleapis.com/auth/drive.file` — 寫 app 自建檔案（m3u8、mu-state.json）
     - （不申請 `drive` full：等需要編輯使用者自建 m3u8 再擴）
   - Test users：加自己的 Gmail
4. **建 3 個 OAuth client**（Credentials → Create Credentials → OAuth client ID）：
   | 類型 | 值 | 用途 |
   |---|---|---|
   | Android | package `music.mu.android`；SHA-1 之後補（`keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey`） | Android app |
   | iOS | bundle `music.mu.ios` | iOS / macOS |
   | Desktop app | — | Linux 開發機的整合測試（loopback + PKCE） |
5. **回報**：三個 Client ID 給 agent。Desktop secret 放 `.env`（已 gitignore），不進 repo。

## 已查證的地雷

- **Testing 模式 refresh token 7 天過期**（官方明文）：開發期可接受；
  日常使用前把 publishing status 切 **Production（不驗證）**→ token 穩定，
  代價：同意畫面「未驗證」警告 + 100 用户上限（自用無感）。
- `drive.readonly`/`drive` 是 **restricted** scope（`drive.file` 才是 non-sensitive）：
  Mu 掃使用者自傳檔案 → readonly 必要；公開發佈才需正式驗證流程。

## 為什麼是 readonly + file 而不是 full drive

`drive.file` 只看得到「app 建立/開啟過」的檔案。音樂檔是使用者自己上傳的，
所以讀取必須 `drive.readonly`。寫入面：Mu 自己建的 m3u8 / mu-state.json
由 `drive.file` 涵蓋。唯一罩門：**編輯使用者在別處建立的 m3u8** 需要_full_
`drive`——Phase 3 若要支援再擴 scope（重新同意一次即可）。
