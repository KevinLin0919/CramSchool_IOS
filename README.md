# AutoGrade Scanner (iOS)

補習班考卷批改系統的 iOS App。**批改完全在裝置上執行**——相機對到考卷，
XFeat 把模板題框貼上去，MNIST CNN 與拓樸判斷讀出答案，全程不連伺服器。

伺服器（[`CramSchool_API`](https://github.com/KevinLin0919/CramSchool_API)）只負責
**存放與同步**：考卷模板、標準答案、母卷影像、批改結果。同步過一次之後，
斷網照樣能改整疊考卷。

最低支援 iOS 17。

---

## 三個分頁

| 分頁 | 功能 |
|------|------|
| 考卷 | 從伺服器同步的模板，依「年級 → 科目」分組瀏覽、搜尋、改名、刪除。「新增」可拍標準答案卷 → YOLO 自動框答案區 → OCR 辨識標準答案 → 人工確認後存回伺服器 |
| 掃描 | 全螢幕相機。題框**貼著考卷移動**，鏡頭平移到哪就批改到哪，按「完成」凍結成結果 |
| 結果 | 整頁考卷 + 批改框、逐題明細、分享 |

## 三種判定，不是兩種

模型讀不出來的格子，**不會**被算成學生答錯。

| | 顏色 | 意思 |
|---|---|---|
| `correct` | 綠 | 讀到了，而且對 |
| `wrong` | 紅 | 讀到了，但錯——框外會顯示標準答案，方便老師當場訂正 |
| `unsure` | 黃 | **沒把握**。交給老師判斷 |

把「讀不出來」判成錯，是拿我們的失敗去怪學生。這個狀態一路保留到結果頁，
`GradedAnswer.teacherValue` 一填就會翻轉判定並重算統計。

**結果頁不顯示分數或及格與否。** 各題配分不同，「答對題數 ÷ 總題數」不是分數；
及格線是學校的判斷，不是 App 的。它只報三種判定各有幾題。

---

## 註冊與離線

### 註冊

設定 → 註冊這台裝置，填**伺服器位址**與**一次性邀請碼**（管理員以
`cramctl teachers invite` 產生）。換到的 token 存在 **Keychain**，
`AfterFirstUnlockThisDeviceOnly`：

- `AfterFirstUnlock` 而非 `WhenUnlocked` —— 否則鎖屏時背景上傳讀不到 token
- `ThisDeviceOnly` —— 不進備份，避免還原到別台裝置後憑證復活

### 示範模式 = 尚未註冊的狀態

不是開關，是預設行為。沒有憑證的裝置本來就沒有伺服器可談，退回內建考卷是
唯一不會變成錯誤訊息的行為。

⚠️ 這同時解決 App Review：審核員永遠不會註冊，所以他們打開就是一個完整可用的
離線批改示範，而不是一整片連線失敗。已註冊的裝置想展示時，設定裡有強制開關。

### 離線

`TemplateStore` 是伺服器的**離線鏡像**，不是取檔工具。批改需要的一切都從磁碟讀，
網路只負責更新鏡像：

```
Application Support/TemplateCache/
  index.json           同步游標 + 模板清單
  detail/{id}.json     題框與標準答案
  master/{imageID}_1600.jpg
```

同步走伺服器給的游標增量拉取，刪除的模板以**墓碑**形式抵達，
所以離線一週的裝置回來後不會還留著一份沒人能批改的考卷。

---

## 裝置端辨識

### 對位：XFeat (Core ML)

內建 [XFeat](https://github.com/verlab/accelerated_features)（CVPR 2024，fp16 約 1.3MB，
輸入 832×608 灰階）。相機每隔幾幀與母卷對位一次，題框跟著紙走。

- `XFeatEngine.swift` — 推論、灰階前處理、NMS / top-k / 64 維描述子
- `XFeatMatcher.swift` — mutual-NN 餘弦匹配（Accelerate）、RANSAC homography，
  以及快取模板特徵、可反覆對位相機串流的 `XFeatTemplateMatcher`

### 辨識：MNIST CNN + 拓樸

- **數字** — `DigitRecognizer.swift`，權重與後端 `/ocr` 完全相同。
  重建了 MNIST 的正規化（ink 縮到 20px、依重心置中於 28×28），這是後端沒做的那一步
- **圈叉** — `MarkRecognizer.swift`，數洞：圓圈圍出一個區域，叉沒有。
  形態學閉運算是關鍵，因為學生的圈常常沒收口
- **投票** — `AnswerRecognizer.swift`。一格在鏡頭平移中會被看到幾十次，
  約每五幀有一幀的對位誤差足以讀錯，所以累積投票而非單幀決定

### 為什麼答案格的像素數是關鍵

**主要誤差來源不是模型，是印刷框線過濾器。** 同一格原始圖 1/6，過濾後 5–6/6。
那個過濾器要靠連通元件分析認出框線，而框線只有一兩個像素寬時就不可靠了。

實測：**64px 讀對 3/6，96px 讀對 6/6。**

所以相機用 4K（`canSetSessionPreset(.hd4K3840x2160)`，不支援則退回 `.photo`）。
`.photo` 給拍照輸出全解析度，但給視訊輸出的是約 1080px 寬的預覽 buffer，
一格只有 48–70px。

⚠️ 對位不受影響——它仍在 1200px 縮圖上跑（XFeat 反正會縮到 832×608），
格子則是逐格從 buffer 裁切，所以多的像素只在真正會讀的地方付費。

**診斷：** 設定 → 顯示辨識結果，掃描時會顯示 `格 Npx・畫面 Npx`。
兩個數字分辨兩種完全不同的狀況：

```
格 55px ・畫面 3840px   → 站太遠，靠近就好
格 55px ・畫面 1080px   → 這台機器的硬體上限，靠近也有極限
```

⚠️ iPhone 全系列（能跑 iOS 17 的）都支援 4K；**陽春版 iPad 6/7/8/9、Air 3、mini 5 不支援**。

---

## 座標系

題框是**母卷影像的 0..1 分數**。舊的 800×600「網頁畫布」座標（含置中黑邊偏移）
已隨著說它的服務一起移除——那個格式沒有母卷長寬比就無法解讀，
每個使用者都得自己重算一次同樣的偏移。

---

## 建置與側載

**有 Mac：** Xcode 16 以上開 `AutoGradeScanner.xcodeproj`，選 Team，實機執行。

**無 Mac（目前實際流程）：** GitHub Actions（`.github/workflows/ios.yml`，macOS runner）
在推送 `main` / `demo-*` / `client-*` / `scan-*` 或手動觸發時：

| Job | 內容 |
|---|---|
| Compile check | 模擬器編譯 |
| Demo grading self-test | 在模擬器裡跑完整批改路徑：單張、即時掃描（局部視角平移）、辨識模型比對參考值 |
| Build unsigned .ipa | `CODE_SIGNING_ALLOWED=NO`，產出 artifact 供 **Sideloadly** 側載 |

自測是唯一的回歸保護（沒有 Mac 可以本機跑），所以它斷言的是具體數字而非「有沒有 crash」：
`SELFTEST LIVE final: 8 graded`、`RECOG PASS model.matchesReference — max prob delta 1.49e-07`。

---

## 伺服器設定

| 服務 | 用途 | 何時需要 |
|---|---|---|
| **API** | 模板、標準答案、母卷、批改結果 | 同步時。**批改本身不需要** |
| YOLO 偵測 | `POST /predict` 自動框答案區 | 只在「新增考卷」時 |
| 標準答案 OCR | `POST /ocr_google` | 只在「新增考卷」時 |

後兩者預計代理到 API 後面，屆時 App 只需要一個位址。

⚠️ `Info.plist` 目前開著 `NSAllowsArbitraryLoads`，因為伺服器位址可能是內網 IP。
改用有合法憑證的網址（例如 Tailscale 的 `*.ts.net`）之後應該拿掉——App Store 審核會追問。

---

## 專案結構

```
AutoGradeScanner/
├── AutoGradeScannerApp.swift   App 進入點
├── Theme.swift                 設計 tokens（#2d5a3d 品牌綠）＋判定顏色對應
├── Models.swift                ExamTemplate / GradedAnswer / GradingVerdict
├── APIModels.swift             /api/v1 的 Codable 線上型別
├── APIClient.swift             HTTP client（bearer token、multipart 上傳）
├── Credentials.swift           Keychain 憑證
├── TemplateStore.swift         離線鏡像：增量同步、母卷快取、ResolvedTemplate
├── AppModel.swift              全域狀態
├── EnrolmentView.swift         裝置註冊（伺服器位址 + 邀請碼）
├── RootView.swift              三分頁 tab bar
├── TemplatesView.swift         畫面一：考卷模板
├── TemplatePreview.swift       模板縮圖與預覽
├── ScannerView.swift           畫面二：掃描批改
├── ResultsView.swift           畫面三：批改結果
├── NewTemplateView.swift       新增模板（YOLO + OCR + 人工確認）
├── SettingsView.swift          註冊狀態、同步、診斷
├── OverlayViews.swift          批改框 overlay
├── CameraController.swift      AVFoundation 相機（4K）＋Vision 紙張偵測
├── CellPixelSource.swift       格子取樣來源：原始 buffer 或降採樣影像
├── CellPatch.swift             灰階取樣、Otsu、連通元件、印刷框線過濾
├── DigitRecognizer.swift       MNIST CNN（Core ML）
├── MarkRecognizer.swift        圈叉：形態學閉運算 + 數洞
├── AnswerRecognizer.swift      依答案型別路由 + 跨幀投票
├── DigitCNN.mlpackage          數字模型（與後端同權重）
├── LiveScanEngine.swift        即時批改：逐幀對位、追蹤、整頁 keyframe
├── GradingEngine.swift         單張拍照批改（對位失敗時的退路）
├── DemoData.swift              內建示範考卷（未註冊時使用）
├── DemoSelfTest.swift          DEBUG：命令列跑批改路徑
├── RecognitionSelfTest.swift   DEBUG：辨識模型與取樣路徑自測
├── XFeat.mlmodel               XFeat 特徵模型
├── XFeatEngine.swift           XFeat 推論
├── XFeatMatcher.swift          特徵匹配 + RANSAC homography
├── XFeatDebugView.swift        對位除錯頁
├── ARScanView.swift            ⚠️ 已停用的 ARKit 實驗，待移除
└── PoseProvider.swift          陀螺儀（**主路徑在用**：靜止時降低送幀頻率）
```
