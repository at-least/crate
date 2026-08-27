# Mu — 個人雲端音樂庫播放器 · 專案計畫書

> 版本 1.1 · 2026-08-27（D12 唯讀重新定位）
> 一人 + AI agent 開發。本文件是唯一事實來源（single source of truth）。

---

## 1. 一句話定位

**Mu** 是一個把 Dropbox / Google Drive 當成音樂庫後端的跨平台原生音樂播放器：
不用自架伺服器，掃描雲端資料夾建立索引，串流播放、離線釘選。
**唯讀定位（D12）**：雲端資料夾是唯一真相，app 只讀不寫——播放清單是庫裡的 `.m3u8` 檔（在雲端管理），播放進度/收藏存裝置本機 DB。

平台：**iOS + macOS（Swift 原生）／ Android（Kotlin 原生）**。

## 2. 目標與非目標

### 目標
- 音樂檔集中存一份在雲端硬碟，所有裝置存取同一庫
- 原生播放品質：AVFoundation（Apple）、Media3/ExoPlayer（Android）
- 完整離線支援：釘選專輯/清單，斷網可播
- 播放清單 = 雲端資料夾裡的 `.m3u8` 檔（唯讀；清單同步免實作）
- 播放進度/收藏：裝置本機 DB（schema.sql `play_state` / `favorites`）
- 一人可維護：合約測試防止兩套核心行為飄移

### 非目標（明確不做）
- ❌ 不做音樂串流服務／線上搜歌
- ❌ 不做 Windows / Linux 桌面版（已評估後放棄，見決策紀錄 D6）
- ❌ 不自架伺服器（Navidrome/Subsonic 模式已評估後否決，見 D2）
- ❌ 不做即時協作／多使用者
- ❌ 不用跨平台 UI 框架（見 D5、D7）
- ❌ app 內不上傳/不編輯任何雲端檔案（唯讀，見 D12）
- ❌ 不做跨裝置狀態同步（進度/收藏各裝置獨立，見 D12）

## 3. 決策紀錄（本對話已定案，附理由）

| # | 決策 | 理由 | 捨棄的替代方案 |
|---|---|---|---|
| D1 | 專案名 **Mu** | App Store/Play 無同名音樂播放器；商標風險低（弱商標）；品牌故事好（Mu=無） | — |
| D2 | 同步後端 = **Dropbox / Google Drive** | 免架伺服器、空間便宜；生態有先例（Astiga、CloudPlayer） | Navidrome 自架（要多架伺服器）；Syncthing（狀態同步要自做） |
| D3 | **Provider 抽象層** | list/delta/stream/put 一套介面，未來可加 OneDrive/WebDAV/本地資料夾 | 綁死單一雲端 API |
| D4 | 播放清單 = 雲端資料夾裡的 **.m3u8 檔** | 清單同步完全免實作，雲端硬碟原生的能力 | 自製清單同步協定 |
| D5 | iOS/macOS = **Swift 原生**，Android = **Kotlin 原生** | 播放引擎底層本來就是原生的；UI 手感天花板；零框架生死風險 | 全原生 5 平台（人力不許可）；KMP/Compose（Windows 肥大）；Flutter（見 D7） |
| D6 | **放棄 Windows** | Flutter 在 Windows 缺 SMTC 整合 + gapless 是實驗旗標 + MSVC 工具鏈負擔；砍掉最弱環節 | Flutter+win32 補洞（spike 成本賭注）；WinUI3（多養一套棧） |
| D7 | 全專案**零跨平台框架依賴** | 消除「框架倒掉」風險；播放品質每平台都是系統級天花板 | — |
| D8 | 開發順序 = contract → **Android 先** → Apple 後 | Agent 開發機是 Linux：Android 可端到端自動驗證（build/test/emulator），閉環不經過人；Apple 端 agent 寫碼、使用者在 Mac 驗收 | Apple 先（驗證瓶頸在使用者） |
| D9 | 域名：註冊 **mu.music**（查證未註冊），備選 muplayer.app | RDAP 查證 2026-08-27 | app.mu（ccTLD 貴）；mu.app/mu.fm（已註冊） |
| D10 | Phase 1 順序改為：**LocalFolderProvider → FakeProvider → Android 殼 → GDrive 最後**（2026-08-27 決定，暫緩實作） | 本地 provider 對應 provider.md 全部方法（delta=mtime/size、rev=size+mtime），零帳號零網路即可開發測試整條同步管線；且「本地資料夾」本來就是規劃中的正式功能（桌機情境），非拋棄式測試碼 | 一開始就做 GDrive（被 OAuth 設定卡住開發節奏） |
| D11 | GDrive OAuth **申請延後到實際要上 production 前才做**（2026-08-27 決定） | D10 後 GDrive 不阻塞任何開發；開發期申請無收益——Testing 模式 refresh token 7 天就過期，太早申請反而要反覆重授權。操作文件已備妥（docs/gdrive-setup.md），屆時照做約 10 分鐘 | 現在就並行申請（無收益，7 天 token 過期擾人） |
| D12 | **唯讀重新定位**（2026-08-27）：app 對雲端一律唯讀；契約移除 putText/ConflictError/LWW 衝突語意與 mu-state.json；進度/收藏改裝置本機 DB；雲端採「同一雲端同一庫」（兩平台各實作 provider 讀同一份資料夾） | 需求本質是「把雲端資料夾當音樂庫讀取」——單向資料流下衝突語義維護成本大於價值；清單編輯留在雲端原生工具即可 | m3u8 雙向編輯 + mu-state.json 跨裝置同步（原 Phase 3 方案） |

## 4. 架構

```
mu/
├─ contract/                  ← 兩套核心的共同規格（機器可讀，防飄移的脊椎）
│  ├─ schema.sql              SQLite schema（兩邊照搬）
│  ├─ model.md                資料模型與語意（專輯/音軌/清單/釘選/狀態）
│  ├─ provider.md             Provider 介面語意（list/delta/stream/put 錯誤行為）
│  ├─ sync-rules.md           增量掃描規則、cursor 語意（唯讀）
│  ├─ acceptance.md           MVP 驗收清單（機器可查部分）
│  └─ fixtures/               黃金測試檔（髒檔樣本 + 期望輸出 JSON）
│
├─ android/                   ← Kotlin
│  ├─ core/                   純 JVM 模組：provider/delta/掃描/m3u8/DB（跑 contract 測試）
│  └─ app/                    Compose UI + Media3 播放 + Service
│
└─ apple/                     ← Swift
   ├─ MuCore/                 Swift package：provider/delta/掃描/m3u8/DB（跑 contract 測試）
   ├─ MuiOS/                  iOS app（SwiftUI + AVFoundation）
   └─ MuMac/                  macOS app（與 iOS 共用 MuCore）
```

### 分層原則
- **contract/**：無任何平台代碼。fixtures 用「同輸入 → 同 JSON 輸出」斷言，兩邊 CI 都跑。
- **核心層**（MuCore / android-core）：純邏輯，不 import 任何 UI/播放框架，單元測試覆蓋 ≥90%。
- **App 層**：薄。UI + 播放器接線 + 系統整合（通知/後播/CarPlay…）。業務邏輯一律下沉到核心。

## 5. 資料模型（草案，contract/ 定稿）

```sql
-- schema.sql 核心表（節錄）
CREATE TABLE tracks (
  id TEXT PRIMARY KEY,          -- provider file id（雲端檔案唯一鍵）
  path TEXT NOT NULL,           -- 雲端路徑 Artist/Album/NN - Title.flac
  title TEXT NOT NULL,
  artist TEXT NOT NULL,         -- track artist
  album_artist TEXT NOT NULL,
  album_id TEXT NOT NULL,
  disc INTEGER NOT NULL DEFAULT 1,
  track_no INTEGER,
  year INTEGER,
  duration_ms INTEGER,
  format TEXT,                  -- flac/mp3/m4a/ogg/opus/wav
  size_bytes INTEGER,
  bitrate_kbps INTEGER,
  modified_at INTEGER,          -- 雲端 mtime（同步判斷用）
  scanned_at INTEGER,           -- 本地 tag 解析時間
  tag_ok INTEGER NOT NULL DEFAULT 0  -- 解析失敗=0，退回檔名推斷
);
CREATE TABLE albums ( id TEXT PRIMARY KEY, name TEXT, artist TEXT, year INTEGER, art_track_id TEXT );
CREATE TABLE playlists ( id TEXT PRIMARY KEY, path TEXT UNIQUE, name TEXT, rev TEXT, synced_at INTEGER );
CREATE TABLE playlist_items ( playlist_id TEXT, position INTEGER, track_id TEXT, PRIMARY KEY(playlist_id, position) );
CREATE TABLE pins ( track_id TEXT PRIMARY KEY, pinned_at INTEGER );   -- 離線釘選
CREATE TABLE sync_state ( key TEXT PRIMARY KEY, value TEXT );         -- delta cursor 等
```

### Provider 介面（語意摘要，provider.md 定稿）
```
interface CloudProvider {
  auth()                        // OAuth；token 存系統鑰匙串（Keychain / Keystore）
  list(path, cursor?) -> entries + newCursor
  delta(cursor) -> changes      // Drive: changes API；Dropbox: list_folder(longpoll)
  rangeRead(id, offset, len)    // HTTP Range 抓檔案片段（tag 掃描用）
  openStream(id) -> URL         // Drive: alt=media；Dropbox: get_temporary_link（CDN）
  download(id, localPath)       // 釘選用
}
```
錯誤語意必須統一：401→重新授權、429→退避重試、5xx→標記 provider 不可用。**這些行為寫進 fixtures 測試。**

### 掃描策略
- 首次全掃：list 遞迴 → 對每個音訊檔 `rangeRead` 抓 tag（MP3/FLAC/Ogg tag 在檔頭 ≤64KB；**M4A 在檔尾**，尾部 range）。併發 8，進度回報。
- tag 解析失敗 → 檔名 fallback（`NN - Title.ext`），`tag_ok=0`。
- 之後全靠 delta cursor，增量、便宜。
- 專輯歸組鍵：`album_artist + album name`（ Various Artists 合輯靠 album_artist 判別）。

### 同步規則（sync-rules.md 定稿；D12 後唯讀）
| 資料 | 主從 | 說明 |
|---|---|---|
| 音訊檔 | 雲端唯讀（單向下載） | 雲端刪除 → 本地索引標記 unavailable（已釘選檔案保留但提示） |
| .m3u8 清單 | 雲端唯讀 | 清單在雲端管理（雲端 app/網頁編輯），app 讀取並解析 |
| 播放狀態/收藏 | 裝置本機 | 本地 DB，不上雲 |

## 6. 各平台方案

### Apple（MuCore + 2 apps）
| 項目 | 選擇 |
|---|---|
| 語言/UI | Swift 6、SwiftUI |
| 播放 | AVFoundation（AVQueuePlayer；gapless 用 AVPlayer 接力 + `preferredForwardBufferDuration`，必要時 AVMIDI…不，必要時評估 AVAudioEngine 精控） |
| DB | SQLite（GRDB 或 raw sqlite3——MuCore 內決定，跑同份 schema.sql） |
| 背景/遠端控制 | MPNowPlayingInfoCenter + MPRemoteCommandCenter（免費的 SMTC 等級整合） |
| 網路 | URLSession（range request 原生支援） |
| OAuth | ASWebAuthenticationSession（系統體驗，無嵌入式 browser 問題） |
| 秘密 | iOS Keychain / macOS Keychain |
| iOS/macOS 共用 | 一個 Swift package `MuCore`，兩個薄 app target |
| 測試 | `swift test` 跑 contract fixtures（**在 Mac 上就是你第一天跑的東西**） |

### Android（core + app）
| 項目 | 選擇 |
|---|---|
| 語言/UI | Kotlin 2.x、Jetpack Compose、Material 3 |
| 播放 | Media3 ExoPlayer + MediaSessionService（gapless 播放清單內建、通知/耳機/車用一步到位） |
| DB | Room（匯入同份 schema.sql） |
| 網路 | OkHttp / Ktor client |
| OAuth | Custom Tab + PKCE（google-api + dropbox-core 或直連 REST） |
| 測試 | `./gradlew :core:test` 純 JVM 跑 contract fixtures（agent 在 Linux 全程可驗） |

## 7. 里程碑與驗收

### Phase 0 — contract/（agent，Linux 上完成）
產出：schema.sql、provider.md、sync-rules.md、fixtures/（≥20 個案例：無 tag FLAC、Big5 ID3v2.3、多封面 MP3、M4A 尾部 tag、空 m3u8、絕對/相對路徑 m3u8、CRLF、BOM…每案例附期望 JSON）。
**驗收**：`fixtures/README.md` 定義的「同輸入同輸出」測試規格完成，兩邊 CI 腳本就位。

### Phase 1 — Android MVP（agent 在 Linux 開發；使用者在實機耳朵驗收）
> 2026-08-27 修訂（D10）：開發順序 = LocalFolderProvider → FakeProvider → Android 殼 → GDrive。**狀態：已記錄，暫緩開工。**

子步骤（後項依賴前項）：
1. **LocalFolderProvider**：實作 contract/provider.md 介面（delta = mtime/size 快照比對、rev = size+mtime、rangeRead = RandomAccessFile、putText = 寫檔）。同步引擎：首掃 → DB → 增量（增/刪/改/改名）。機器測試含髒情境：掃描中拔檔、外部改 m3u8、目錄改名。
   > 2026-08-27 進度：契約面完成（provider.md §6 + sync-rules.md §3 + 6 個 sync_cases/fixtures）；兩平台引擎（Kotlin `SyncEngine`/`LocalFolderProvider`、Swift 同名）與 Python 參考三方 byte-identical，含掃描中拔檔情境。同日完成 model.md §1.7 時長解析（flac/mp3/m4a/ogg/opus/wav，fixtures 換版）。尚未完成：listDir/錯誤語意（隨子步驟 2 FakeProvider 契約補齊；putText 已於 D12 移除）、SQLite/Room 持久化（App 層接線時做）。
2. **FakeProvider**（in-memory、可腳本化錯誤）：測 provider.md §2 錯誤語意（401 重授權、429/5xx 指數退避）。
   > 2026-08-27 ✅：provider.md §2.1 釘死重試政策（退避 1/2/4/8/16s、5 次重試上限、auth 立即重試一次、NotFound 不重試）+ FakeFiles putText 衝突語意；`err_cases/` fixtures 三方 byte-identical（Kotlin `RetryPolicy`/`FakeFiles`、Swift 同名）。引擎管線接線（sync 套重試）**改隨 GDrive 子步驟做**——LocalFolderProvider 無 transient/auth 錯誤來源，先接是死碼。**同日 D12：putText/ConflictError 自契約移除，err_cases 縮編為 7 條 retry 條目。**
3. **Android 殼**（Compose + Media3 + Room）：瀏覽專輯/藝人、播放（串流/本地）、釘選、媒體通知/耳機控制、`.m3u8`。資料來源先接 LocalFolderProvider。
   > 2026-08-27 進度：垂直切片上線——`:app` 模組（Compose BOM / Material3）、`PlaybackService`（Media3 MediaSession：通知/鎖屏/耳機/音源焦點）、資料夾選擇 → SyncEngine 掃描 → 專輯網格 → 專輯音軌 → 點播（含 durationMs 顯示）。CI 加 `:app:assembleDebug` job。同日補：m3u8 playlist UI 與播放（core `resolvedItems()` 兩平台對等，解析規則=toCanonical items）、增量重掃按鈕（delta，rev 未變不重讀）、記住上次資料夾（SharedPreferences，重開自動重掃）。尚未完成：Room 持久化（目前索引在記憶體）、釘選離線。
   > 2026-08-28 進度：**Room 持久化上線**——schema.sql v0.2 重塑（cursor/scan_errors 落庫、playlist raw 化、補 album/rev/compilation 欄位）；`:app` 加 KSP+Room（`MuApp` DB 單例、`db/MuDatabase`：Entity×6 + `loadEngineState()`/`replaceLibrary()`）；core 兩平台 `SyncEngine.exportState()/restoreState()`（+`EngineState` 測試：還原後 sync 為純 delta）。冷啟動：DB 還原 → 即時 UI → delta 同步 → 落庫；換資料夾 = 換引擎 + DB 全量置換（順手修掉 換根重用舊引擎 bug）；root 改存 DB（移除 SharedPreferences）；syncMutex 防連點/冷啟動競態。**同日：釘選離線（專輯級）上線**——`PinManager`（schema pins 狀態機 wanted→downloading→done/failed，循序佇列、應用層級 scope、行程中斷自動續傳、換庫清釘）；`PinEntity` 落 DB；專輯檢視釘選列（進度/取消）；播放 resolver 釘選副本優先；available=0 但 pinned-done 的軌仍顯示（標「離線」）可播——B5 的本地 provider 語意=來源資料夾移除後可播。已知取捨：playlist 解析仍走契約 available 集合（sync-rules §3.2-5），unavailable-pinned 軌不現身清單 UI——清單級釘選留給雲端相位。子步驟 3 至此全數完成。
4. **GDriveProvider**（最後；需要 docs/gdrive-setup.md 的 3 個 Client ID——依 D11，申請延後到實際要上 production 前才做）：插進現有管線，UI 加帳號連結頁；同步管線接上 `RetryPolicy`（transient 退避 / auth 重授）。

範圍（不變）：專輯/藝人瀏覽、Media3 播放（串流 + 下載快取）、釘選離線、媒體通知/耳機控制、`.m3u8` 讀取。
**驗收（機器可查）**：core 契約測試全綠；emulator 上掃描 500 張專輯模擬資料 < 5 分鐘。
**驗收（人耳，需你的 Android 機）**：
1. 選本地音樂資料夾 → 首掃 → 專輯網格出現（GDrive 接通後複驗：登入 Drive 同樣成立）
2. 點歌播放 → 鎖屏有控制 → 藍牙耳機暫停/續播
3. 釘選一張專輯 → 飛航模式 → 正常播放
4. 連續播放接縫無爆音

### Phase 2 — Apple MVP（agent 寫碼；你在 Mac 上跑）
範圍：MuCore package（provider/delta/掃描/m3u8/DB + 契約測試）→ iOS app（瀏覽/播放/釘選/遠端控制）。
> 2026-08-28 進度：**本地資料夾垂直切片上線**——MuCore 補 App 層 API 面（`resolvedItems`/`groupAlbums` 轉 public、六個資料型別補 public init——Kotlin data class 天生 public，Swift 隱式 memberwise init 是 internal）、Package.swift 補 `products`（Xcode 得以連結本地套件）。`apple/MuiOS`：raw sqlite3 `MuDatabase`（schema.sql v0.2 鏡像；FK 全不建——playlist_items cascade 改顯式 DELETE、pins 照 Room 慣例不參照 tracks）、`PinManager`（pins 狀態機：循序佇列、DOWNLOADING 殘留自動續傳、換庫清釘/同庫保留、root 路徑統一 `resolvingSymlinksInPath` 否則冷啟動誤判換庫）、`PlayerManager`（AVQueuePlayer + MPNowPlayingInfoCenter/MPRemoteCommandCenter + 來電中斷 + 拔耳機暫停 + AVRoutePickerView AirPlay 入口）、SwiftUI `ContentView`（專輯網格/清單列/釘選列/離線標記/迷你播放列——播放列掛 NavigationStack 外，掛 root 會被推入頁蓋住）、資料夾挑選 + security-scoped bookmark 記住庫根。`MuiOSUITests`（XCUITest，MU_ROOT 環境注入 fixture 庫）：掃描→瀏覽→點播→佇列推進、專輯釘選→離線標記→重啟 DB 還原，全綠（B3/B5 的 iOS 機器版）。CI 加 `ios-app` job（generic iOS Simulator build）。已知取捨：DB/PinManager 放 App 層比照 Android `:app`（Room 亦在 app 層；MuMac 進場時再提升共享 target）；pins state 存小寫（schema.sql 原文；Room 版存大寫 enum name——兩邊 DB 不互通無影響）；playlist 的 unavailable-pinned 軌不現身清單 UI（同 Android 取捨）。**尚未完成**：GDrive provider（D11 延後）→ C2 的「同一個 Drive」複驗待其進場；C3/C4（鎖屏/Control Center/AirPlay/耳機）需真機人耳驗收；macOS app 屬 Phase 3。
**驗收（你的 Mac + iPhone）**：
1. `swift test` 契約測試全綠（與 Android 同輸出）— ✅ 機器已驗（Mac, Swift 6.2.4）
2. Cmd+R 跑起來 → 登入同一個 Drive → 索引與 Android 一致（GDrive 依 D11 延後；本地資料夾情境已於模擬器 UI 測試覆蓋）
3. Control Center / 鎖屏控制、AirPlay 可用
4. 耳機驗收同 Android 清單

### Phase 3 — 擴充（選配）
Dropbox provider（讀同一庫）、macOS app（選單列常駐）。
> 原「同步閉環」相位（m3u8 雙向編輯、mu-state.json 跨裝置同步）隨 D12 取消——app 對雲端唯讀，清單編輯在雲端原生工具進行。
**驗收**：見 acceptance.md Phase 3。

### Phase 4 — 打磨
CarPlay（Media3 原生支援 + CarPlay framework）、桌面 Widget、Last.fm scrobble（選配）、ReplayGain、等化器。
此時才考慮 TestFlight / Play 內部測試軌道。

## 8. 驗證策略（誰驗什麼）

| 驗證 | 誰 | 工具 |
|---|---|---|
| 契約行為（掃描/delta/m3u8/重試） | agent，自動 | 兩邊 core 套件測試跑同批 fixtures |
| Android build/邏輯/UI 基本流程 | agent，自動 | gradle test + emulator（Linux 機） |
| Apple build | 你 | Xcode Cmd+R（agent 的 Linux 機無法編 Apple 端——環境事實，D8 排序依據） |
| 播放品質（gapless/藍牙/來電恢復/背景壽命） | 你，耳朵+日常使用 | 每階段末的「聽測」清單（見各 Phase） |

原則：**能自動化的絕不靠人；必須靠人的（耳朵），排程式清單一次驗完。**

## 9. 風險與對策

| 風險 | 等級 | 對策 |
|---|---|---|
| 雲端 API 配額（首掃幾萬個 range request） | 中 | 併發節流 + 進度可恢復（斷點續掃）+ tag 只抓必要 bytes；Drive/Dropbox 皆有配額文件，寫進 provider.md |
| M4A 尾部 tag 在無 Range 支援的端點上拿不到 | 低 | provider 驗證階段先測 Range 支援；不支援 → 整檔下載僅限 m4a |
| AVFoundation gapless 不達標 | 低 | Apple 播放接力是成熟模式；真不行走 AVAudioEngine sample 級（Phase 4 再議） |
| 一人專案爛尾 | 中 | 里程碑制，每 Phase 有可裝可玩的產出；MVP 之後任何時刻停住都是可用產品 |
| 名字商標 | 低 | 上架前 TIPO/USPTO 第 9/42 類檢索；個人專案階段不阻擋 |

## 10. Mac 開工指南（第一天）

1. **環境**：macOS 26+、Xcode（App Store 最新版，裝完開過一次）、Command Line Tools（`xcode-select --install`）。可选 Homebrew、 Ruby（不需）。
2. **拿程式碼**：`git clone <repo>`（或先只拿 `contract/` 與 `apple/`）。
3. **第一步跑契約測試**：
   ```bash
   cd apple/MuCore
   swift test
   ```
   預期：contract fixtures 全綠。**這行指令是 Apple 端的里程碑 1。**
4. **跑 app**：`open apple/MuiOS/MuiOS.xcodeproj` → 選 iPhone 模擬器 → Cmd+R。
5. **你不需要寫碼**：開 issue / 貼錯誤訊息 / 描述聽感給 agent。你的時間花在耳朵和真機。

## 11. 命名與上架

- 商店名：**Mu – Music Player**（副標解 ASO，兩字名單獨搜不到）
- Bundle ID（建議）：`music.mu.ios` / `music.mu.mac` / `music.mu.android`（package name）
- 域名：儘早註冊 `mu.music`（查證時未註冊）；備選 `muplayer.app`
- 上架前：TIPO/USPTO 商標檢索（第 9/42 類「Mu」）
- Apple 開發者帳號 $99/年（TestFlight 需要）；Play $25 一次性

## 12. 立即的下一步

1. agent（Linux 機）：建 repo 骨架 + 寫 `contract/` 全部內容 + Android core 契約測試骨架
2. 你（Mac）：照 §10 跑通環境（GDrive OAuth 申請依 D11 延後，現階段不用做）
3. 會合點：contract/ 完成 → 開 Phase 1

---

*本文件由 agent 依 2026-08 對話決策整理；修改決策請直接編輯 §3 決策紀錄並附理由。*
