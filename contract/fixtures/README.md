# Fixtures 使用說明（兩平台測試都依此接線）

## 目錄結構
```
cases/<name>/
  lib/            虛擬音樂庫（本地目錄樹；path = 相對 lib/ 的 '/' 路徑）
  expected.json   掃描器的 byte-canonical 期望輸出（model.md §2）
```
27 案例（2026-08 由 generate.py 產出；**產物已 commit，重跑需 ffmpeg**；`replaygain_tags` 為合成檔，`generate.py --case replaygain_tags` 不需 ffmpeg）。

## 測試接線（Kotlin / Swift 相同）
1. 列舉 `cases/` 下每個目錄
2. 呼叫自家 `Scanner.scan(libRoot)`
3. 輸出 canonical JSON（model.md §2.2 規則）
4. 與 `expected.json` 做 **byte 比對**
5. 比對前把 `errors[].message` 正規化為 `""`（實作自由文字，豁免）

## id 慣例
fixture provider 的 `Entry.id == Entry.path`（見 model.md §1.4），所以
`tracks[].id == tracks[].path`、`playlists[].id == path`。真實 provider
（gdrive/dropbox）的 id 是各家檔案 id——掃描器不吃 id，只吃 path。

## 讀取視窗化（model.md §1.8）
掃描器不讀整檔：`ChunkedReader`（64 KiB 對齊 chunk、每 chunk 抓一次）+ parser 只讀 header、跳過大 payload。
`sync_assets/` 的合成大檔（`flac_bigpic`／`mp3_bigapic`／`m4a_tail_big`，`sync_generate.py --synth` 產生，無 ffmpeg）
供 `gdrive_cases/gdrive_windowed_scan` 驗證 Range 請求數三方一致。

## 已釘死的實作細節（fixtures 即規格）
- Ogg/Opus 註解：在前 64KB **bytewise 掃** magic（`OpusTags` 或 `\x03vorbis`），從 magic 後解析 vorbis-comment 結構
- M4A：box walk（size==1 → 64-bit；size==0 → 到檔尾）；`meta` box 有 4B version/flags；`trkn/disk` 的 data payload 取 offset 4 的 BE uint16；值 0 → 視為無
- ID3：只取每 frame 第一個 NUL 結尾字串；同一欄位多 frame → 第一個非空值勝
- EXTINF 毫秒：無浮點十進位演算（model.md §2.3）
- Big5 髒檔（mp3_id3v23_big5_dirty）：v0 刻意釘 Latin-1 mojibake；Phase 1 改 Big5 heuristic 時**該案例 expected 會換版**，改法：加新案例 big5_heuristic 並把此案例標 superseded

## 案例清單
| 案例 | 驗證點 |
|---|---|
| flac_full_tags / flac_no_tags | Vorbis comment 全欄位；無 tag fallback |
| mp3_id3v23_utf16 / mp3_id3v24_utf8 | ID3 v2.3 UTF-16(BOM)、v2.4 UTF-8 |
| mp3_id3v23_big5_dirty | encoding-0 非 ASCII → Latin-1 mojibake（刻意） |
| mp3_no_tags / mp3_multiple_covers | frame sync 偵測；APIC 忽略不炸 |
| mp3_bad_container / flac_bad_container | BAD_CONTAINER error |
| m4a_itunes_tags | 尾部 moov ilst 解析 |
| opus_ogg_tags / ogg_vorbis_tags | OpusTags / \x03vorbis magic 掃描 |
| wav_untagged | RIFF/WAVE 判定，永遠 fallback |
| va_compilation / deep_path_no_tags | 合輯歸組；VA 資料夾 fallback |
| filename_track_patterns | `NN - Title`、前導零、無連字號、depth 1/0 |
| unknown_ext_ignored | 非音訊副檔名靜默略過 |
| nested_album_dirs | 同藝人兩專輯歸組 |
| m3u8_*（8 案例） | 空、EXTINF+相對路徑、CRLF+BOM、絕對路徑 missing、unicode、畸形 EXTINF、反斜線 |
| replaygain_tags | model.md §1.9：Vorbis `REPLAYGAIN_*`、ID3 `TXXX`（Latin-1/UTF-16）、MP4 `----`；`n/a`→null、截斷第三位小數、同鍵第一個勝 |

## 其他契約案例集（非 scanner cases/）
| 目錄 | 產生器 | 驗什麼 |
|---|---|---|
| `sync_cases/` | `sync_generate.py` | 同步引擎（sync-rules §3） |
| `err_cases/` | `err_generate.py` | 重試政策（provider.md §2.1） |
| `gdrive_cases/` | `gdrive_generate.py` | GDrive provider（provider.md §8）＋視窗化請求數 |
| `dropbox_cases/` | `dropbox_generate.py` | Dropbox provider（provider.md §9） |
| `eq_cases/` | `eq_generate.py` | EQ 設定與播放總增益（model.md §1.10；純整數。浮點 DSP 由各平台性質測試驗） |
| `nowplaying_cases/` | `nowplaying_generate.py` | 現正播放快照與 Widget 顯示規則（model.md §1.11） |
