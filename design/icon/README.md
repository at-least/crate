# Crate — App Icon

定案：**墨黑底、骨白雙連音符**。構圖照 Apple Music，配色換成 Crate 自己的兩色。
全部手寫 SVG，沒有 `<text>`／`<filter>`／`<mask>`，可直接餵 Xcode 與 Android Studio 的 Vector Asset。

## 幾何

| | |
|---|---|
| 符頭 | 橢圓 94 × 74，傾角 12°，一低一高差 64，兩顆間距 46 |
| 符桿 | 寬 42 |
| 連桿 | 厚 62，往右上斜 62 |
| 字標外框 | 419 × 491（對角 645），長邊佔 1024 畫布的 62% |
| 路徑 | 單一 `<path>`、五個子路徑 nonzero 聯集 |

三處接合都是**切線**，不是疊出來的 —— 這是輪廓乾淨的關鍵：

1. 符桿右緣切在符頭最右點（橢圓在該處的切線正好垂直，兩段輪廓曲率連續、沒有台階）。
2. 符桿頂端切在**連桿上緣在該桿位置的 y**。連桿是斜的，若用連桿最高點當基準，左邊那根會往上戳出 62。
3. 連桿兩端齊符桿外緣：左端齊左桿左緣、右端齊右桿右緣。

沒有描邊也沒有端點 —— 全部是填色，所以整個記號只有一條外輪廓。

## 色票

| 用途 | 值 |
|---|---|
| 底 | 墨黑 `#16151B` |
| 字標 | 骨白 `#F4EFE6` |
| 深色外觀底 | `#0C0B10`（字標 `#EAE3D6`） |

墨黑不是純黑、骨白不是純白，兩邊都帶一點暖。

## 檔案

| 檔案 | 用途 |
|---|---|
| `apple/AppIcon.svg` | 1024 主圖。**不做圓角**（iOS/macOS 自己套遮罩），滿版不透明 |
| `apple/AppIcon-dark.svg` / `-tinted.svg` | 深色與著色外觀。著色版是純灰階（系統只讀亮度） |
| `apple/png/*-1024.png` | 上面三張的 PNG，**已移除 alpha 通道** |
| `apple/icon-composer-background.svg` | Icon Composer 背景層（單一平塗色，滿版） |
| `apple/icon-composer-mark.svg` | Icon Composer 字標層（去背） |
| `android/ic_launcher_background.svg` | Adaptive icon 背景層，滿版 108 |
| `android/ic_launcher_foreground.svg` | 前景層。字標高 47dp、對角 62dp，落在 66dp 安全圓內 |
| `android/ic_launcher_monochrome.svg` | 單色層，供 Android 13+ themed icon |
| `android/ic_launcher.xml` | `mipmap-anydpi-v26/` 的 adaptive-icon 描述檔 |
| `android/colors.xml` | 兩個色，併進 `values/colors.xml` |
| `mark.json` | 所有幾何參數與路徑資料（要改比例就改這裡再重生） |
| `archive/` | 走過的七輪探索，沒有刪 |

## 接上去（尚未做）

**Apple（擇一）**
- 建議：Icon Composer（Xcode 26+）吃分層，用 `icon-composer-background.svg` + `icon-composer-mark.svg` 兩層，
  深色／著色／透明外觀由系統推導，不必維護三張會各自漂移的美術稿。
- 舊路徑：`Assets.xcassets/AppIcon.appiconset` Single Size 放 `apple/png/AppIcon-1024.png`，
  Appearances 開 Dark / Tinted 各放對應 PNG，再接進 `project.pbxproj` 的 Resources phase。

**Android**
- Android Studio → New → Vector Asset 逐一匯入三個 SVG 到 `res/drawable/`。
- `ic_launcher.xml` 放進 `res/mipmap-anydpi-v26/`（`ic_launcher_round.xml` 內容相同）。
- 刪掉舊的 `mipmap-*dpi` PNG。
- `colors.xml` 的兩個色併進 `values/colors.xml`。

## 重生與改比例

`mark.json` 存了所有參數。改 `rx/ry`（符頭）、`stem`（桿寬）、`beam`（連桿厚）之後重生，
三個平台的檔案是同一組座標換算出來的 —— 改比例要三邊一起重出，不要單獨手改某一個檔。

**注意 alpha**：`qlmanage` 和 Chrome 輸出的 PNG 都帶 alpha 通道，App Store Connect 會以 ITMS-90717 退件。
重新輸出後一定要跑一次去 alpha，並用 `sips -g hasAlpha` 確認。
