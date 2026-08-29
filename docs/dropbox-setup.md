# Dropbox OAuth 設定（與 D11 同步延後：實際要上 production 前才申請）

> 對應 provider.md §9（provider 語意）與 §10（OAuth + PKCE）。在 Dropbox App Console 操作，約 5 分鐘。

## 步驟

1. **建 app**：[dropbox.com/developers/apps](https://www.dropbox.com/developers/apps) → Create app
   - API：**Scoped access**
   - 存取範圍：**Full Dropbox**（音樂庫多半不在 app 專屬資料夾內；若你願意把庫放進 `Apps/Mu/`，可改 App folder）
   - 名稱：`Mu`（全域唯一，被占用就加後綴）
2. **Permissions 分頁**勾選（唯讀，對應 D12）：
   - `files.metadata.read`
   - `files.content.read`
   → **Submit**（改權限後既有 token 需重新授權）
3. **Settings 分頁**：
   - 記下 **App key**（= `client_id`；PKCE 流程不需要 App secret）
   - **Redirect URIs** 加入：
     | 用途 | URI |
     |---|---|
     | iOS / macOS | `music.mu.ios:/oauth2redirect` |
     | Android | `music.mu.android:/oauth2redirect` |
     | Desktop（開發機） | `http://127.0.0.1:<port>/callback` |
4. **回報**：App key 給 agent。

## 已查證的地雷

- **短期 token 預設 4 小時**：授權時必須帶 `token_access_type=offline` 才會拿到 refresh token
  （已寫進 `OAuth.Config.dropbox`）。
- **改 scope 要重新授權**：Permissions 改動不會套用到既有 token。
- **content_hash**：list metadata 免費附帶，Mu 以它當 rev（provider.md §9.3），不需額外請求。
