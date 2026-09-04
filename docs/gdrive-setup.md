# Google Drive OAuth 設定（依 D11 暫緩：實際要上 production 前才申請）

> 2026-08-27 依 Google 官方文件查證後撰寫。在 Google Cloud Console 操作，約 10 分鐘。

## 步驟

1. **建專案**：[console.cloud.google.com](https://console.cloud.google.com/) → 新專案 `Crate`
2. **啟用 API**：APIs & Services → Library → **Google Drive API** → Enable
3. **OAuth 同意畫面**（Google Auth Platform）：
   - User type：**External**
   - App name：`Crate`；email 填自己
   - Scopes 手動加入：
     - `https://www.googleapis.com/auth/drive.readonly` — 掃整個音樂庫（restricted）。D12 唯讀定位後僅此一個 scope 即足夠
   - Test users：加自己的 Gmail
4. **建 3 個 OAuth client**（Credentials → Create Credentials → OAuth client ID）：
   | 類型 | 值 | 用途 |
   |---|---|---|
   | Android | package `at.least.crate.android`；SHA-1 之後補（`keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey`） | Android app |
   | iOS | bundle `at.least.crate.ios` | iOS / macOS |
   | Desktop app | — | Linux 開發機的整合測試（loopback + PKCE） |
5. **回報**：三個 Client ID 給 agent。Desktop secret 放 `.env`（已 gitignore），不進 repo。

## Redirect URI（對齊 provider.md §10）
| 用途 | redirect_uri |
|---|---|
| iOS / macOS | `at.least.crate.ios:/oauth2redirect`（iOS client 的反轉 client ID 亦可，屆時擇一釘死） |
| Android | `at.least.crate.android:/oauth2redirect` |
| Desktop（開發機整合測試） | `http://127.0.0.1:<port>/callback` |

流程本身（PKCE challenge、授權 URL、token 交換/更新、過期判定、錯誤語意）已在核心層完成並有契約測試
（`contract/fixtures/oauth_cases/`），拿到 Client ID 後只需填入設定 + 接上平台的「開瀏覽器」與鑰匙串儲存。

## 已查證的地雷

- **Testing 模式 refresh token 7 天過期**（官方明文）：開發期可接受；
  日常使用前把 publishing status 切 **Production（不驗證）**→ token 穩定，
  代價：同意畫面「未驗證」警告 + 100 用户上限（自用無感）。
- `drive.readonly`/`drive` 是 **restricted** scope（`drive.file` 才是 non-sensitive）：
  Crate 掃使用者自傳檔案 → readonly 必要；公開發佈才需正式驗證流程。

## 為什麼只要 readonly

`drive.file` 只看得到「app 建立/開啟過」的檔案。音樂檔是使用者自己上傳的，
所以讀取必須 `drive.readonly`。D12 唯讀定位後 app 不寫任何雲端檔案，
不需要 `drive.file`；未來若恢復寫入需求（如 app 內編輯 m3u8）再擴 scope
（重新同意一次即可）。
