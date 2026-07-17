# AutoGrade Scanner (iOS)

補習班考卷批改系統的 iOS App —— 依照 Claude Design 的「AutoGrade Scanner」設計稿實作。
批改所需的 YOLO / OCR / 模板伺服器沿用網頁版（`CramSchoolWeb_Front_end`）既有服務；
另內建**離線示範模式**與**裝置端 XFeat 對位**，因此側載後即使連不到伺服器也能展示完整流程。

## 畫面（對應設計稿三個分頁）

| 分頁 | 功能 |
|------|------|
| 考卷 | 從模板伺服器載入考卷模板，依「年級 → 科目」分組瀏覽、搜尋、改名、刪除；每列有紙張縮圖、可點 👁 預覽（離線也能看，見下方示範模式）；「新增」可拍攝標準答案卷 → YOLO 自動框答案區 → Google OCR 辨識標準答案 → 存回伺服器（與網頁版格式相容） |
| 掃描 | 全螢幕相機。連上真後端時：Vision 偵測穩定紙張矩形後自動拍照 → YOLO 偵測答案區 → 手寫 OCR 辨識 → 與模板標準答案逐格比對，框框逐一彈出（綠＝正確、紅＝錯誤），批改完提供細長操作列（查看明細／掃描下一張）。示範模式下改走裝置端 XFeat 即時對位（見下方） |
| 結果 | 分數卡（幾分、得分率、通過/未通過）、掃描影像上的批改框（可點選聚焦）、逐題明細底部面板（Q 縮圖格＋「作答 vs 標準」OCR 對照表）、分享 |

## 示範模式（離線 demo）

`DemoData.swift` 提供一層 mock，讓側載出去、連不到校內伺服器的 build 也能離線展示。

- 由「考卷」頁 ⚙️ 設定裡的「示範模式（離線假資料）」開關控制（UserDefaults key `demo.mode`），**全新安裝預設開啟**。
- 開啟時：`APIClient` 每個方法與 `GradingEngine.grade` 都會提前回傳內建假資料，不連任何伺服器。內建 5 份範例模板（國一數學／國二英文／國三理化／高一數學／高二國文，本階段可新增／改名／刪除，重開 App 會重置）。
- 其中**國一數學第三次段考**綁了一張真母卷 `DemoMaster9001.png`：選它掃描時會跑**真正的裝置端 XFeat 對位**，把答案框投影到畫面上（只有「手寫辨識結果」是套好的腳本，第 4、6 題設定為錯）。把這張母卷印出來、或用另一台螢幕顯示，拿相機對準它，即可看到即時批改。
- 其他 4 份沒有母卷圖，掃描時退回 Vision 自動拍照 + 一個約 75% 正確的示意結果。
- 正式使用請關閉示範模式，並在 ⚙️ 填入下方伺服器位址。

### 即時掃描（Live Scan）

`LiveScanEngine.swift`：相機每隔幾幀丟一張給 XFeat 與內建母卷對位，答案框會**貼著考卷移動**，
鏡頭平移到哪、該題的 ✓/✗ 就鎖定到哪（連續看到兩幀才鎖，避免閃爍），按「完成」凍結成批改結果。
目前只對綁了母卷圖的模板（9001）生效；對位品質有門檻（inlier 數與比例），對不準時會請使用者重拍。

## 如何開啟 / 側載

**有 Mac：** 用 **Xcode 16 以上**開啟 `AutoGradeScanner.xcodeproj`，在 Signing & Capabilities
選你的開發者 Team，實機執行（掃描需要相機；模擬器可用「相簿」選圖代替）。最低支援 iOS 17。

**無 Mac（目前實際使用的流程）：** GitHub Actions（`.github/workflows/ios.yml`，macOS runner）
在推送 `main` / 對 main 開 PR / 推送 `demo-*` 分支 / 手動觸發時，會做編譯檢查並打包一個
**未簽章 .ipa**（`CODE_SIGNING_ALLOWED=NO`）上傳成 artifact `AutoGradeScanner-ipa`，
下載後用 **Sideloadly** 側載（首次以 USB 配對，之後同一 Wi-Fi 即可重裝）。

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

## 裝置端 XFeat(Core ML)

App 內建 [XFeat](https://github.com/verlab/accelerated_features)(CVPR 2024)特徵匹配模型
(`XFeat.mlmodel`,fp16 約 1.3MB,由 accelerated_features repo 的 `export_coreml.py` 匯出,
輸入 832×608 灰階,在裝置上離線推論,不需伺服器):

- `XFeatEngine.swift` — 載入模型、灰階前處理、NMS / top-k / 64 維描述子取樣
- `XFeatMatcher.swift` — mutual-nearest-neighbor 餘弦匹配(Accelerate)、RANSAC homography；
  高階 API `XFeatAligner.alignmentHomography` / `partialAlignmentHomography`（局部視角），
  以及快取模板特徵、可反覆對位相機串流的 `XFeatTemplateMatcher`
- `XFeatDebugView.swift` — 對位除錯頁（投影框 + 疊圖）

用途:把考卷照片對位到模板母卷影像,直接投影模板題框
(homography 以 0–1 正規化座標表示,模板 800×600 canvas 座標除以 `WebCanvas` 尺寸即可投影),
不依賴 YOLO 偵測框的順序。示範模式的即時掃描(`LiveScanEngine`)即建立在此之上。

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
├── TemplatesView.swift         畫面一：考卷模板（列縮圖、預覽、分組）
├── TemplatePreview.swift       模板列縮圖 + 離線預覽（母卷圖或答案卡示意）
├── ScannerView.swift           畫面二：掃描批改（即時掃描 + 自動拍照）
├── ResultsView.swift           畫面三：批改結果
├── NewTemplateView.swift       新增模板流程
├── SettingsView.swift          示範模式開關＋伺服器位址設定
├── DemoData.swift              離線示範模式：mock API + 假批改，內建範例模板
├── DemoMaster9001.png          示範母卷（供 XFeat 對位的真圖）
├── DemoSelfTest.swift          DEBUG：命令列跑批改 pipeline 的自測
├── LiveScanEngine.swift        即時掃描：逐幀 XFeat 對位、答案框追蹤、逐題鎖定
├── XFeat.mlmodel               裝置端 XFeat 特徵模型(Core ML)
├── XFeatEngine.swift           XFeat 推論＋特徵點/描述子後處理
├── XFeatMatcher.swift          特徵匹配＋RANSAC homography 對位
└── XFeatDebugView.swift        XFeat 對位除錯頁
```
