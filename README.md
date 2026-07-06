# AutoGrade Scanner (iOS)

補習班考卷批改系統的 iOS App —— 依照 Claude Design 的「AutoGrade Scanner」設計稿實作，
後端沿用網頁版（`CramSchoolWeb_Front_end`）既有的 YOLO / OCR / 模板伺服器，**不需要在手機上跑任何模型**。

## 畫面（對應設計稿三個分頁）

| 分頁 | 功能 |
|------|------|
| 考卷 | 從模板伺服器載入考卷模板，依「年級 → 科目」分組瀏覽、搜尋、改名、刪除、預覽；「新增」可拍攝標準答案卷 → YOLO 自動框答案區 → Google OCR 辨識標準答案 → 存回伺服器（與網頁版格式相容） |
| 掃描 | 全螢幕相機。Vision 偵測到穩定的紙張矩形後自動拍照 → YOLO 偵測答案區 → 手寫 OCR 辨識 → 與模板標準答案逐格比對，框框逐一彈出（綠＝正確、紅＝錯誤），完成後彈出分數卡 |
| 結果 | 分數卡（幾分、得分率、通過/未通過）、掃描影像上的批改框（可點選聚焦）、逐題明細底部面板（Q 縮圖格＋「作答 vs 標準」OCR 對照表）、分享 |

## 如何開啟

1. 在 Mac 上用 **Xcode 16 以上**開啟 `AutoGradeScanner.xcodeproj`。
2. 在 Signing & Capabilities 選你的開發者 Team（目前留空）。
3. 選擇實機執行（掃描需要相機；模擬器可用「相簿」選圖代替相機）。

最低支援 iOS 17。

## 後端服務

預設位址與網頁版 `vite.config.ts` 的 proxy 相同，可在 App 內「考卷」頁右上角 ⚙️ 修改：

| 服務 | 預設位址 | 路徑 | 用途 |
|------|----------|------|------|
| YOLO 偵測 | `http://140.115.54.241:8082` | `POST /predict` | 偵測答案區 bbox |
| 手寫 OCR | `http://140.115.54.239:8083` | `POST /ocr` | 學生手寫答案（回傳 chinese / digit 候選） |
| Google OCR | `http://140.115.54.241:8083` | `POST /ocr_google` | 標準答案卷辨識（建模板用） |
| 模板伺服器 | `http://140.115.54.241:8084` | `/api/exam-templates` | 模板 CRUD |

手機需與伺服器在同一網路（或 VPN）。Info.plist 已開 `NSAllowsArbitraryLoads` 允許 HTTP。

## 與網頁版的相容性

- 模板的 `annotations.bbox` 沿用網頁版標註畫布的 **800×600 座標系**（`[x, y, w, h]`），
  App 建立模板時會把照片像素座標換算成該座標系再上傳，網頁版可直接使用，反之亦然。
- 批改比對邏輯與網頁版 `ResultsView.vue` 相同：標準答案為純數字時採用 OCR 的 `digit` 候選，
  否則採用 `chinese` 候選；完全一致才算正確；及格線 60%。
- 年級／科目分組是從 `exam_name` 解析（如「高一數學段考一」→ 高一 / 數學），
  無法解析的歸到「其他」。建模板時名稱包含年級科目即可正確分組。

## 專案結構

```
AutoGradeScanner/
├── AutoGradeScannerApp.swift   App 進入點
├── Theme.swift                 設計稿 tokens.js 的色彩／樣式常數（#2d5a3d 品牌綠）
├── Models.swift                模板、OCR、批改結果資料模型；800×600 畫布常數
├── APIClient.swift             四個後端服務的 HTTP client（容錯解析與網頁版一致）
├── AppModel.swift              全域狀態：目前分頁、模板清單、選取、最近批改結果
├── GradingEngine.swift         批改 pipeline：照片 → YOLO → OCR → 比對
├── CameraController.swift      AVFoundation 相機＋Vision 紙張偵測自動拍照
├── OverlayViews.swift          批改框 overlay（掃描與結果頁共用）
├── RootView.swift              自訂三分頁 tab bar（中央大掃描鍵）
├── TemplatesView.swift         畫面一：考卷模板
├── ScannerView.swift           畫面二：掃描批改
├── ResultsView.swift           畫面三：批改結果
├── NewTemplateView.swift       新增模板流程
└── SettingsView.swift          伺服器位址設定
```
