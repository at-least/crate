# Mu — App Icon

全部手寫 SVG，沒有用到 `<text>`（跨平台字體不一致）、`<filter>`、`<mask>`，
所以能直接餵給 Xcode 的 Asset Catalog 與 Android Studio 的 Vector Asset 匯入。

## 概念

主案 **「μ 音符」**：希臘字母 μ 的下伸筆畫直接當成符桿，末端接一顆傾斜 18° 的符頭，
就是一個符幹朝下的四分音符。字母（Mu）和音樂是同一筆，不用再疊音符或雲朵。

字標為單線（stroke 100 / 1024 ≈ 1/10，高於 1/12 的小尺寸下限），圓端點圓接合，
字身落在畫布中央 ~50%，任何平台的遮罩都裁不到。29pt 下仍可辨識（見 preview.png）。

## 色票

| 用途 | 值 |
|---|---|
| 底色漸層（左上→右下） | `#8B5CF6` → `#5B4BE0` → `#221A5E` |
| 深色變體漸層 | `#3C2F7A` → `#241E52` → `#0E0B22` |
| 字標（淺） | `#FFFFFF` |
| 字標（深色變體） | `#EDEAFF` |

## 檔案

| 檔案 | 用途 |
|---|---|
| `mu-icon.svg` | 1024 主圖。**不做圓角**（iOS/macOS 自己套遮罩），底色滿版不透明 |
| `mu-icon-dark.svg` | iOS 18 / macOS 深色外觀變體 |
| `mu-icon-tinted.svg` | iOS 18 著色（tinted）變體；系統只讀亮度，故為純灰階 |
| `mu-mark.svg` | 去背純字標，`currentColor` 可繼承外層顏色（README／文件／載入畫面用） |
| `export/*-1024.png` | 上面三張的 1024×1024 PNG，Xcode 單尺寸 App Icon 直接放 |
| `android/ic_launcher_background.svg` | Adaptive icon 背景層，滿版 108 |
| `android/ic_launcher_foreground.svg` | 前景層，字標高 45dp、對角 62dp，在 66dp 安全圓內 |
| `android/ic_launcher_monochrome.svg` | 單色層，供 Android 13+ themed icon |
| `android/ic_launcher.xml` | `mipmap-anydpi-v26/` 用的 adaptive-icon 描述檔 |
| `alt-b-vinyl.svg` / `alt-c-disc.svg` | 沒選上的另外兩個方向，保留備查 |
| `preview.png` | 三個方向在 120/64/40/29pt、淺色與深色下的對照表 |

## 接上去的步驟（尚未做）

Apple（擇一）：
- 建議走 Icon Composer（Xcode 26+）：它吃分層 SVG，用 `mu-mark.svg` 當字標層、
  `#8B5CF6 → #5B4BE0 → #221A5E` 當背景層，深色／著色／透明外觀由它自己推導。
- 舊路徑：`Assets.xcassets/AppIcon.appiconset` Single Size 放 `export/mu-icon-1024.png`，
  Appearances 開 Dark / Tinted 各放對應 PNG。

`export/` 的三張 PNG 已移除 alpha 通道（App Store Connect 不收帶 alpha 的 1024 圖，ITMS-90717）。
若之後重新輸出，記得用 `sips -g hasAlpha` 檢查——`qlmanage` 與 Chrome 出來的都帶 alpha。

Android：Android Studio → New → Vector Asset 逐一匯入三個 SVG 到 `res/drawable/`，
再把 `ic_launcher.xml` 放進 `res/mipmap-anydpi-v26/`（`ic_launcher_round.xml` 內容相同），
並刪掉舊的 `mipmap-*dpi` PNG。

## 重畫時的規矩

1. 字標路徑只有三段，三個平台的檔案都是同一組座標換算過來的 —— 改字形要三邊一起改。
2. 匯入 VectorDrawable 前不要加 `<filter>` / `<mask>` / `<text>`，會被吃掉。
3. 小尺寸驗證：`qlmanage -t -s 1024 -o . x.svg`，再縮到 29px 看，不要只看源檔。
