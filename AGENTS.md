# AGENTS.md — 浮島 iOS App

**先讀 `../CramSchool_Backend/AGENTS.md`**：兩個 repo 共用的規範、工作流程、現況看板（`docs/progress.md`）、
變更紀錄（`docs/changes/`）和用語表（`CONTEXT.md`）都在後端 repo。兩個 repo 要 clone 在同一個上層資料夾。

讀不到後端 repo 時，至少遵守這幾條：回覆用繁體中文；合併到 `main`（正式版，老師會自動收到）要使用者明確同意；
新東西先上 `develop`（QAT）；密鑰不進 git；這個 repo 是 public，不寫老師姓名、帳號、補習班名稱、主機 IP。

## 這個 repo 是什麼

SwiftUI App「浮島」（iOS 17+，iPhone 與 iPad）。老師掃描學生考卷，App 在手機上即時對位、讀出每一格、批改，
結果存在手機上再上傳後端。三個分頁：考卷、掃描、結果。產品與設計的說明在 `README.md`。

| 檔案 | 負責 |
|---|---|
| `LiveScanEngine.swift` | 掃描主流程：每幀對位、決定讀哪些格、投票定案 |
| `XFeatEngine.swift`、`XFeatMatcher.swift` | 整頁對位（XFeat，Core ML） |
| `CellRegistration.swift` | 逐格定位：用母卷印刷找出每一格的實際位置、擦掉印刷 |
| `CellPatch.swift`、`CellPixelSource.swift` | 裁切格子、去掉印刷（括號）、二值化 |
| `AnswerRecognizer.swift` | 依題型分派辨識、跨幀投票（`AnswerAccumulator`）、選項規則 |
| `DigitRecognizer.swift`、`MarkRecognizer.swift`、`MarkFeatures.swift`、`MarkForest.swift` | 數字（MNIST CNN）與 ○✕（決策森林） |
| `CameraController.swift`、`PoseProvider.swift` | 相機、陀螺儀、覆蓋框繪製 |
| `TemplateStore.swift` | 模板的離線鏡像與同步 |
| `GradingStore.swift`、`GradingRestore.swift`、`UploadQueue.swift` | 批改紀錄、從伺服器還原、上傳佇列 |
| `ResultsView.swift`、`ScannerView.swift`、`TemplatesView.swift`、`SettingsView.swift` | 主要畫面 |
| `APIClient.swift`、`AppEnvironment.swift` | 後端 API；正式版與 QAT 的差別（`AppEnvironment.isQAT`，只在 `develop` 上有） |
| `RecognitionSelfTest.swift`、`DemoSelfTest.swift` | CI 在模擬器上跑的自我測試 |

## 建置與測試

**Windows／WSL 沒有 Xcode**，那裡唯一的編譯器是 CI：把分支推上去，分支名要用 `scan-*` 或 `client-*` 開頭才會觸發。
CI（`.github/workflows/ios.yml`）有這幾個工作：

- 模擬器編譯檢查。
- 示範掃描自我測試：用 `TestFixtures/scan_*.jpg` 模擬鏡頭掃過示範卷 9001，檢查批改結果。
- 辨識自我測試：環境變數 `RECOGNITION_SELFTEST`，會印出 `RECOGNITION SELFTEST: n/n passed`，重要的檢查在 `ios.yml` 裡逐項 grep。
- 簽章並上傳 TestFlight：只在 `develop`（浮島 QAT）和 `main`（浮島）執行。

在 Mac 上可以直接本機編譯，指令和 CI 相同：

```bash
xcodebuild build -project AutoGradeScanner.xcodeproj -scheme AutoGradeScanner \
  -destination "generic/platform=iOS Simulator"
```

自我測試的跑法照抄 `ios.yml` 的 `selftest` 工作：裝到模擬器，再用 `SIMCTL_CHILD_*` 環境變數啟動。

## 慣例

- **註解寫「為什麼」**：這個 codebase 的註解很多、用完整句子說明理由和踩過的坑。新程式照同樣的密度和語氣寫。
- 專案用 Xcode 16 的 synchronized folders：新的 `.swift` 檔放進 `AutoGradeScanner/` 就會自動編進去，不用改 `project.pbxproj`。
- 座標：格子位置是母卷圖片的 0..1 比例（舊的 800×600 網頁座標已經移除）。
- Core ML 模型可以在 Linux 上轉換，但**沒辦法在 Linux 上執行預測**；第一次真正執行是在 CI 的模擬器上。
  改影像演算法前，先用 numpy 照同樣的常數重寫一份驗證，再花一輪 CI。
- 改到辨識前後都要跑辨識基準（`docs/benchmarks/recognition-tpl7.md`），並回報前後數字。

## 文件

- `README.md`：產品行為、判定規則、離線與上傳、裝置端辨識的設計說明。
- `docs/adr/`：App 內部的決策（對位、覆蓋框、逐格定位、選項、數字模型）。系統層級的決策在後端 repo。
- `docs/benchmarks/`：辨識基準集與歷次數字。
- `docs/handoff.md`：2026-09-15 的現況交接，**已過時**，只當歷史參考。

## Agent skills

### Issue tracker

與後端 repo 共用，位置是 `../CramSchool_Backend/docs/changes/<slug>/`。See `docs/agents/issue-tracker.md`.

### Triage labels

使用預設的五個角色字串。See `docs/agents/triage-labels.md`.

### Domain docs

用語表在 `../CramSchool_Backend/CONTEXT.md`；App 內部的決策在本 repo 的 `docs/adr/`。See `docs/agents/domain.md`.
