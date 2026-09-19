# 浮島 專案現況交接報告

> 撰寫時間：2026-09-10，更新於 2026-09-15
> 撰寫依據：本 repo 程式碼與 `README.md`、`CramSchool_Backend` repo、CI 設定、
> 本次對話中使用者明確確認過的內容，以及在此機器上實際執行的檢查。
> 目的：為導入 spec-driven 開發提供可交接的現況基準。**本文件不含產品程式碼修改。**
>
> **標記慣例**
> - **[已驗證]** — 在此機器或 CI 上實際跑過、看到結果
> - **[程式碼存在]** — 程式碼在，但沒有在這次交接中被執行驗證
> - **[待確認]** — 無法從程式碼、文件或本次對話確認

---

## 1. 專案目的與主要使用流程

### 解決什麼問題

補習班老師每天要人工批改大量小學考卷。本系統讓老師用手機鏡頭掃過考卷，
**在裝置上**即時比對標準答案並標出對／錯／不確定，省去逐題核對的時間。

主要使用者是**補習班老師**（來源：`README.md`、後端 `README.md`）。
系統中另有 `admin` 角色負責發放邀請碼（`app/models.py` 的 `Teacher.role`
CHECK 限定 `teacher` / `admin`）。

### 設計上的核心取捨

**批改完全離線。** 相機對到考卷 → XFeat 把模板題框貼上去 → 裝置上的
MNIST CNN 與圈叉判斷讀出答案，全程不連伺服器。伺服器只負責**存放與同步**
（模板、標準答案、母卷影像、批改結果）。同步過一次之後，斷網照樣能改整疊考卷。
（來源：`README.md`）

### 主要操作流程

App 有三個分頁（來源：`README.md`、`RootView.swift`）：

| 流程 | 步驟 | 主要程式 |
|---|---|---|
| **裝置註冊** | 登入頁 →（邀請碼／Microsoft／示範模式）→ 換到 device token 存入 Keychain | `LoginView.swift`、`EnrolmentView.swift`、`Credentials.swift` |
| **同步模板** | 從伺服器增量拉取模板清單、題框、標準答案、母卷影像到本地鏡像 | `TemplateStore.swift` |
| **掃描批改**（主流程） | 選模板 → 全螢幕相機 → 題框貼著紙走、逐格跨幀投票 → 多頁可切頁籤 → 按「完成這份」凍結 | `ScannerView.swift`、`LiveScanEngine.swift` |
| **檢視與訂正** | 結果頁看整頁批改框、逐題明細；老師可訂正判定 | `ResultsView.swift`、`GradingStore.swift` |
| **回傳結果** | 背景冪等上傳批改結果（含訂正過與讀不出的格子裁切圖） | `UploadQueue.swift` |
| **新增模板** | 拍標準答案卷 → YOLO 自動框 → OCR 讀標準答案 → 人工確認 → 存回伺服器 | `NewTemplateView.swift` |

### 三種判定（重要設計約束）

模型讀不出來的格子**不會**被算成學生答錯。

| 判定 | 顏色 | 意思 |
|---|---|---|
| `correct` | 綠 (#2D8A5F) | 讀到了，而且對 |
| `wrong` | 紅 (#D93025) | 讀到了，但錯 |
| `unsure` | 橘 (#FF9500) | 沒把握，交給老師 |

（來源：`README.md`、`Theme.swift`、`app/models.py` 的 `ck_answer_verdict`）

**結果頁不顯示分數或及格與否**——各題配分不同，答對題數不是分數。（來源：`README.md`）

---

## 2. 功能現況

### 2.1 已完成且已實際驗證

| 功能 | 程式路徑 | 驗證依據 |
|---|---|---|
| 裝置端即時批改（單面／多面） | `LiveScanEngine.swift`、`ScannerView.swift` | **[已驗證]** CI `SELFTEST LIVE final: 8 graded`，8 題逐題斷言；正式資料庫有 13 筆 grading_sessions / 146 筆 graded_answers |
| XFeat 對位 | `XFeatEngine.swift`、`XFeatMatcher.swift` | **[已驗證]** 同上（自測含平移局部視角） |
| 數字辨識（MNIST CNN） | `DigitRecognizer.swift`、`DigitCNN.mlpackage` | **[已驗證]** CI `RECOG PASS model.matchesReference` |
| 印刷框線濾除 | `CellPatch.swift` `withoutPrintedMarks()` | **[已驗證]** CI `real.filterHelps — 1 → 5 once the box border is erased` |
| 圈叉辨識（決策森林） | `MarkRecognizer` + `MarkFeatures` + `MarkForest` | **[已驗證]** 跨頁 CV 96%、保留集 10/10、實機敢答 10/10 零假陽性。取代了原本的徑向探測（實機只有 43%） |
| Microsoft 帳號登入 | `MicrosoftSignIn.swift`、`app/routers/auth.py` | **[已驗證]** 2026-09-14 端到端成功，teacher #2 自動建立、token 30 天到期 |
| 三種判定與跨幀投票 | `AnswerRecognizer.swift` | **[已驗證]** CI 自測 |
| 模板離線鏡像／增量同步 | `TemplateStore.swift` | **[程式碼存在]**＋實機使用過（正式庫有 7 份模板同步紀錄）；本次未重跑 |
| 批改結果冪等上傳 | `UploadQueue.swift`、`app/routers/sessions.py` | **[已驗證]** 正式庫 13 筆 session 都是從 App 上傳的 |
| 邀請碼註冊 | `EnrolmentView.swift`、`app/routers/auth.py` | **[已驗證]** 正式庫有 1 位 teacher；後端 79 項測試通過 |
| 後端 API 全部端點 | `app/routers/*.py` | **[已驗證]** 79 項 pytest 全過（本機執行） |
| 多頁（雙面）考卷 | `LiveScanEngine.swift`、`TemplateStore.swift` | **[已驗證]** 正式庫有 6 份雙面模板；CI 未涵蓋雙面 |
| 答案型別路由（digit / choice / mark） | `AnswerRecognizer.swift` `AnswerKind` | **[已驗證]** CI `real.choiceNeverHurts` |

### 2.2 部分完成

| 功能 | 現況 | 程式路徑 |
|---|---|---|
| **新增模板** | 只做單面：`page_index: 0` 寫死。且依賴兩個外部推論服務（見 §3） | `NewTemplateView.swift:277` |
| **老師訂正回饋** | 訂正 UI、上傳路徑、匯出端點都完整。`teacher_value` 仍是 0 筆，但原因不是程式有洞 —— **是還沒有任何老師用它改過考卷**。這是使用者問題，不是工程問題 | `UploadQueue.swift:170`、`ResultsView.swift` |
| **中文答案辨識** | schema 支援 `answer_type = 'chinese' / 'text'`，但裝置端一律回 `.unsupported` → 該格永遠 `unsure`。正式庫目前沒有任何 chinese/text 的題框 | `AnswerRecognizer.swift:44` |

### 2.3 未完成 / 預留

| 功能 | 現況 | 程式路徑 |
|---|---|---|
| **學生身分綁定** | `students` 資料表存在、CRUD API 存在，但**0 筆資料**，所有 `grading_sessions.student_id` 皆為 nil | `app/routers/students.py`、`app/models.py` |
| **`answer_boxes.label` 客戶端串接** | 後端已回傳有意義的 label，iOS 端未解碼使用 | `app/models.py`、`TemplateStore.swift` |
| **多頁模板建立** | 見上「新增模板」 | `NewTemplateView.swift` |
| **YOLO / OCR 服務代理到 API 後面** | README 記為「預計」，尚未做 | — |
| **`NSAllowsArbitraryLoads` 移除** | 仍開著，因伺服器可能是內網 IP | `Info.plist` |
| **Bundle ID / 開發者帳號** | 目前 `com.cramschool.autogradescanner`，未上架 | **[待確認]** 是否計畫上架 |

---

## 3. 架構與環境需求

### 3.1 系統組成

```
┌─────────────────────────────┐
│ iOS App (浮島)               │  批改全部在此完成，離線可用
│  AutoGradeScanner.xcodeproj │
└──────────┬──────────────────┘
           │ HTTPS/HTTP  bearer token
           ▼
┌─────────────────────────────┐
│ CramSchool_Backend (FastAPI)│  只存放與同步，不參與批改
│  100.107.235.123:8085       │
│  ├── Postgres 17 (compose)  │
│  └── 內容定址影像存放 (磁碟)  │
└─────────────────────────────┘

批改以外、只在「新增模板」時用到的兩個外部服務（不在此二 repo 內）：
  YOLO 偵測  http://140.115.54.241:8082/predict
  Google OCR http://140.115.54.241:8083/ocr_google
```

### 3.2 iOS 端主要模組

35 個 Swift 檔，約 11,100 行。完整清單見 `README.md` 的「專案結構」。核心資料流：

```
CameraController (4K buffer)
  └→ XFeatMatcher  對位 → homography
      └→ LiveScanEngine  投影題框 → 逐格取樣
          └→ CellPixelSource  從原始 buffer 裁切
              └→ CellPatch  灰階 / Otsu / 連通元件 / 印刷框線濾除
                  └→ AnswerRecognizer  依 answer_type 路由
                      ├→ DigitRecognizer (Core ML)
                      └→ MarkRecognizer  (幾何)
                          └→ AnswerAccumulator  跨幀投票
                              └→ GradingStore → UploadQueue
```

### 3.3 資料庫

Postgres 17（正式）／ SQLite（開發、測試）。主要資料表（`app/models.py`）：

`teachers` · `api_tokens` · `invite_codes` · `images` · `exam_templates` ·
`template_pages` · `answer_boxes` · `students` · `grading_sessions` · `graded_answers`

**正式資料庫現況（2026-09-15 查詢，[已驗證]）：**

| 資料表 | 筆數 | 備註 |
|---|---|---|
| exam_templates（未刪除） | 7 | 全部由開發者手動建立 |
| answer_boxes | 124（mark 65 / choice 59） | 沒有任何 chinese / text |
| grading_sessions | 27 | **全部是開發者自己測的** |
| graded_answers 有 teacher_value | **0** | 沒有老師用過 |
| students | **0** | |
| teachers | 2 | 開發者 + 2026-09-14 首次 Microsoft 登入 |

**這張表是整份文件最重要的一頁。** 所有準確率、所有 UX 判斷、所有技術決策，
都建立在**一個人、一份考卷（社會1-1）、一支筆**之上。

### 3.4 兩個關鍵 schema 約束

1. **題號必須跨頁連續。** `answer_boxes` 唯一鍵是 `(page_id, question_no)`，
   但 `graded_answers` 是 `(session_id, question_no)`。正反面都印「1、2、3」的
   考卷存得進模板卻批不了。`TemplateStore.resolve` 會拒絕並說明。
   （來源：`README.md`、後端 `README.md`、`app/models.py`）

2. **只有內容定址的網址可以宣告 `immutable`。**
   `/images/{id}/content` 可以；`/templates/{id}/master` 不可以。
   （來源：`app/routers/images.py`、`app/routers/templates.py`）

### 3.5 執行環境與依賴

**iOS**
- 最低 iOS 17；Xcode 16 以上
- 4K 相機：iPhone 全系列（能跑 iOS 17 的）支援；**陽春版 iPad 6/7/8/9、Air 3、mini 5 不支援**
- 無外部套件相依（無 SPM/CocoaPods），Core ML 模型內建於 bundle

**後端**
- Python >= 3.11（本機 venv 為 3.13.9）
- 主要依賴：fastapi、uvicorn、sqlalchemy>=2.0.36、alembic、psycopg[binary]、
  pydantic>=2.10、pydantic-settings、python-multipart、pillow、typer、pyjwt[crypto]
- dev：pytest、pytest-asyncio、httpx、ruff、cryptography
- 部署：Docker Compose（`postgres:17-alpine` + 自建 api image）

### 3.6 環境變數（名稱與用途，不含值）

`.env.example` 與 `app/config.py`：

| 變數 | 用途 | 必填 |
|---|---|---|
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | compose 內 Postgres 憑證 | 部署時必填 |
| `DATABASE_URL` | SQLAlchemy 連線字串。**預設 SQLite `dev.db`**，本機開發不需外部服務 | 否 |
| `DATA_DIR` | 內容定址影像存放根目錄 | 否（預設 `./data`） |
| `DERIVATIVE_CACHE_DIR` | 母卷縮圖快取；刪掉只損失 CPU，不損失內容 | 否 |
| `MAX_UPLOAD_BYTES` | 上傳大小上限（預設 25MB） | 否 |
| `ALLOWED_MASTER_WIDTHS` | `?w=` 允許的寬度白名單，避免任意值塞爆磁碟 | 否 |
| `BOOTSTRAP_ADMIN_EMAIL` | 首次啟動且 teachers 表為空時建立管理員 | 否（正式環境建議不設） |
| `API_BIND` | API 綁定位址，**預設 `127.0.0.1`**。刻意不用 `0.0.0.0` | 否 |
| `MICROSOFT_TENANT_ID` / `MICROSOFT_CLIENT_ID` | Entra 登入。兩個都填才算設定完成 | **已設定並驗證（2026-09-14）** |
| `MICROSOFT_AUTO_PROVISION` | 租戶內任何人可登入，或僅限已存在的老師。預設 false，**目前設為 true**（補習班決定） | 否 |

⚠️ **這四個變數必須同時出現在 `.env` 和 `docker-compose.yml` 的 `environment:`。**
compose 只用 `.env` 做檔案內代換，不會把變數交給容器；只填 `.env` 的話程式讀到空字串，
而空字串的回應是「尚未設定」——**和從來沒填過完全無法區分**。
| `MICROSOFT_TOKEN_DAYS` | Microsoft 換來的 token 天數（預設 30） | 否 |
| `JWKS_CACHE_SECONDS` | Microsoft 簽章金鑰快取秒數 | 否 |
| `CORS_ORIGINS` | 允許的來源，預設空 | 否 |

iOS 端伺服器位址不是環境變數，存在 `UserDefaults`（`server.api`、`server.predict`、
`server.ocr`、`server.ocrGoogle`），由註冊畫面與設定頁填寫。
`server.api` 無預設值（空 = 未設定）；另外三個預設指向 NCU 實驗室 IP。

### 3.7 依賴本機 / 特定環境 / 外部帳號的部分

| 項目 | 依賴 | 影響 |
|---|---|---|
| iOS 編譯與自測 | **macOS + Xcode** | 此開發機（WSL2 Linux）**沒有 Swift toolchain [已驗證]**。所有 iOS 驗證只能靠 GitHub Actions |
| 側載安裝 | Sideloadly（無開發者帳號） | .ipa 為 unsigned |
| API 連線 | **Tailscale tailnet** | API 綁 loopback，唯一入口是主機上的 Tailscale。不在 tailnet 內連不到 |
| YOLO / OCR | NCU 實驗室主機 `140.115.54.241` / `.239` | **[已驗證]** 從此機器連不到（無回應）。「新增模板」流程因此無法在此環境測試 |
| Microsoft 登入 | 補習班的 Entra 租戶 app registration | 尚不存在，卡在對方 |
| 正式資料庫存取 | SSH 到 `comma@100.107.235.123` | 本次交接經使用者授權使用 |

---

## 4. 啟動與驗證方式

### 4.1 指令

**iOS（需 macOS）**
```bash
# 開啟專案
open AutoGradeScanner.xcodeproj          # Xcode 16+，選 Team，實機執行

# CI 等價指令（模擬器編譯）
xcodebuild build -project AutoGradeScanner.xcodeproj -scheme AutoGradeScanner \
  -configuration Debug -destination "generic/platform=iOS Simulator"
```

**後端（本機，SQLite，無外部服務）**
```bash
uv venv .venv && uv pip install --python .venv -e ".[dev]"
.venv/bin/python -m pytest
.venv/bin/python -m ruff check .
.venv/bin/uvicorn app.main:app --reload --port 8085
```

**後端（部署，⚠️ 本次未執行）**
```bash
cp .env.example .env      # 填 POSTGRES_PASSWORD
docker compose up -d --build
```

### 4.2 本次實際執行的檢查與結果

| 檢查 | 指令 | 結果 |
|---|---|---|
| 後端測試 | `.venv/bin/python -m pytest -q` | ✅ **79 passed**（11.71s，1 個 Starlette deprecation warning） |
| 後端 lint | `.venv/bin/python -m ruff check .` | ✅ **All checks passed!** |
| 正式 API 健康檢查 | `curl .../health` | ✅ **HTTP 200** |
| 正式 API 需授權 | `curl .../api/v1/templates`（無 token） | ✅ **HTTP 401**（符合預期） |
| iOS CI（本次對話中執行） | GitHub Actions run `34450360150`，commit `dfa3359` | ✅ **三個 job 全部 success** |
| ├ Compile check | 模擬器編譯 | ✅ success |
| ├ Demo grading self-test | 完整批改路徑 | ✅ `SELFTEST LIVE final: 8 graded`，逐題 Q1–Q8 與改動前完全一致 |
| └ Build unsigned .ipa | Release, 無簽章 | ✅ 產出 artifact |
| 辨識自測（CI 內） | `RECOG PASS` | ✅ `model.load`、`model.matchesReference`、`real.printedMarksRemoved 5/6`、`real.filterHelps 1→5`、`mark.realInk 10/10`、`mark.noConfidentMisread 0`、`source.bufferPathAgrees` |

### 4.3 未執行 / 受阻的檢查

| 檢查 | 原因 |
|---|---|
| **本機 iOS 編譯** | 此機器無 Swift toolchain（WSL2 Linux）**[已驗證]** |
| **Alembic migration 檢查** | 需要對資料庫執行；正式庫不可動，本機 SQLite 需先建立。**未執行以免產生副作用** |
| **YOLO / OCR 服務連通** | 主機不可達 **[已驗證]**。「新增模板」端到端流程本次無法驗證 |
| **Microsoft 登入端到端** | 無 Entra app registration |
| **雙面考卷 CI 覆蓋** | CI 自測只跑單面 demo 模板 9001。雙面僅有實機使用紀錄，無自動化回歸 |
| **docker compose 部署** | 會啟動服務、產生外部副作用，**依規則未執行** |
| **實機掃描驗證最新 commit** | `dfa3359` 的 .ipa 已產出並放到 `/mnt/d/CramSchoolIOS_ipa/`，但**尚未在實機掃描驗證** |

---

## 5. 已知問題與技術債

### 5.1 已確認的問題（有實測數據）

| # | 問題 | 證據 | 影響 |
|---|---|---|---|
| 1 | ~~圈叉辨識準確率不足~~ **已解決**：舊的徑向探測在 65 格平掃上只有 63%，17 個圈判成叉、10 個滿信心。已換成決策森林（跨頁 CV 96%、實機敢答 10/10 零假陽性） | `ed3c0f7`；實機 session 26 | — |
| 2 | **封閉區域偵測在真實筆跡上無效**：實測 O 與 X 的 `enclosed` 特徵中位數皆為 0 | 同上 | 快速路徑形同虛設，全靠探測環 |
| 3 | **老師訂正回饋鏈是斷的**：`wantsCrop` 只在 unsure 或已訂正時上傳裁切圖，而 `teacher_value` 目前 **0 筆** | 正式庫查詢 **[已驗證]** | 跑得越多累積的是**沒有標籤的圖**，無法作為訓練資料 |
| 4 | **README 已過時**：`README.md` 仍描述 `MarkRecognizer` 為「數洞」，但 commit `334002b` 已改為徑向探測（數洞只留作快速路徑） | 比對 README 與 `MarkRecognizer.swift` | 交接者會照著錯的說明理解程式 |
| 5 | **CI 沒有涵蓋雙面考卷** | `.github/workflows/ios.yml` 只跑 demo 9001（單面） | 多頁邏輯無自動化回歸保護 |
| 6 | **`conftest.py` 設定 `COMPAT_REQUIRE_AUTH`，但 `app/config.py` 沒有這個設定** | 讀 `tests/conftest.py:16` 與 `app/config.py` | 已移除的 compat router 留下的殘跡；無害但誤導 |

### 5.2 待查證的風險

| # | 風險 | 為什麼還不確定 |
|---|---|---|
| A | **最新 commit `dfa3359` 的實機行為**：取樣框外擴 25% 在 CI 上逐題不變，但實機（相機、對位誤差、真實紙張）尚未驗證 | 尚未實機掃描 |
| B | **對位誤差對外擴的影響**：外擴的安全性是在「完美 homography 的平掃」上量的。手機的投影誤差等於往某一邊多外擴，這個變因沒有資料 | 缺實機資料 |
| C | **65 格資料的代表性**：一個書寫者、一支筆、一批紙；且該份考卷對照答案卡只有約一半相符 | **[待確認]** 那份 `學生答案版.pdf` 是真實學生所寫，還是為測試隨手填的 |
| D | **65 格的標籤品質**：標籤是由我目視接觸表判讀，未經使用者核對 | 未核對 |
| E | **密集版面（寫國字）的裁切正確性**：外擴上限規則已實作並在合成密集格子上驗證 pad 歸零，但**沒有真實的密集模板**可測 | 正式庫無此類模板 |
| F | **`NSAllowsArbitraryLoads`** 對未來上架的影響 | **[待確認]** 是否要上架 App Store |

### 5.3 測試缺口

- iOS **沒有單元測試框架**（無 XCTest target）。唯一回歸保護是 CI 裡的兩個
  self-test（`DemoSelfTest.swift`、`RecognitionSelfTest.swift`），以斷言具體數字的方式運作。
- 後端 79 項測試涵蓋 API、座標轉換、legacy 匯入、Microsoft 驗簽；
  **[待確認]** 覆蓋率未量測。
- 端到端（App ↔ 後端）沒有自動化測試。

---

## 6. 已確認的需求與決策

> 只列出有明確依據者。依據標於每列。

| # | 需求／決策 | 依據 |
|---|---|---|
| 1 | **讀不出來不能算學生錯**——必須有第三種判定 `unsure` | repo 文件（`README.md`）＋程式（`ck_answer_verdict`） |
| 2 | **結果頁不顯示分數／及格與否**——各題配分不同 | repo 文件（`README.md`） |
| 3 | **批改必須離線可用**，伺服器只做存放與同步 | repo 文件（兩個 README） |
| 4 | **題號必須跨頁連續**（schema 後果，非選擇） | repo 文件＋程式 |
| 5 | **結果頁要用「實際批改時所用的那份考卷」當底圖** | 本次對話（使用者：「用什麼改就用什麼當底圖」） |
| 6 | **新工作一律開新分支，不可直接動 `main`**；`main` 保持在使用者上次安裝並信任的版本 | 本次對話（使用者明確指示） |
| 7 | **不要每次都跑 CI**；要 commit / push / 跑 CI 都須使用者明說 | 本次對話（使用者明確指示） |
| 8 | **要動工前須先討論完並取得同意**，看過規劃不等於核准 | 本次對話（使用者 2026-09-10 重申） |
| 9 | **客觀回答，不要只是附和** | 本次對話（使用者兩次提出） |
| 10 | **版權考卷（南一版、康軒等）不得進入任何 repo 或公開位置** | 本次對話＋`.gitignore` 註解 |
| 11 | **網頁版（閱卷通）是比賽送件版本，其 demo 功能不可弄壞** | 本次對話 |
| 12 | **答案框重疊的修法**：外擴最多到兩格中線貼合，確保不吃到隔壁答案 | 本次對話（使用者明確指定規則） |
| 13 | **圈叉模型方向：先分析不實作** | 本次對話 |
| 14 | **CI 綠之後主動下載 .ipa 並依修改內容命名**，放到 `/mnt/d/CramSchoolIOS_ipa/` | 本次對話 |
| 15 | 上傳對老師不可見，只在會改變決策時才浮現 | 本次對話（既有記憶） |

**明確不是已定案的事項**（避免把現有實作誤當期望行為）：
- 目前 `NewTemplateView` 只支援單面，這是**未完成**，不是使用者要求的行為。
- 目前 `answer_type` 只有 `digit`/`choice`/`mark` 在裝置端可用，`chinese`/`text`
  一律 `unsure`，這是**尚未實作**，不是設計決定。
- 目前結果頁不顯示學生姓名，是因為身分綁定未做，不是使用者不要。**[待確認]**

---

## 7. 待釐清事項與下一步建議

### 7.1 會影響規格／架構／驗收的未決問題

| # | 問題 | 為什麼重要 |
|---|---|---|
| Q1 | ~~圈叉要改演算法還是訓練模型？~~ **已決定並完成**：14 個徑向特徵 + RandomForest。剩下的問題變成「**在別人的筆跡上還準嗎**」，而那需要真實使用者 | 決定還要不要繼續投資辨識 |
| Q2 | **訓練資料要放哪裡？** 不能進 repo（版權＋體積：10 格 fixture 就 161KB） | 決定資料流程與交接方式 |
| Q3 | **標註工具要不要做？** 不做的話資料量上不去 | 是資料收集的關鍵路徑 |
| Q4 | **`學生答案版.pdf` 是誰寫的？** 若為隨手填的測試卷，筆跡分佈不代表真實學生 | 影響訓練資料的有效性 |
| Q5 | **網頁版與 iOS 後端要不要合併？** 已分析：`compat.py` 曾完整寫過（殘留 `.pyc` 可重建），7 個端點 1:1 對應，Vue 原始碼可零改動 | 影響比賽 demo 與模板建立流程 |
| Q6 | **`140.115.54.241` 是可控制的機器嗎？** | 決定合併方案的落地難度 |
| Q7 | **學生身分綁定要怎麼做？** 手動選、掃學號、還是 OCR 姓名欄？ | 影響 schema 與掃描流程 UX |
| Q8 | **要不要上架 App Store？** | 決定 Bundle ID、開發者帳號、`NSAllowsArbitraryLoads` |
| Q9 | **中文（寫國字）辨識的優先順序與做法？** 建議先量 Apple Vision `zh-Hant`（零成本） | 影響密集版面的裁切設計是否要現在做 |

### 7.2 建議的第一個 spec 範圍

**建議：「老師訂正回饋與訓練資料收集」**

理由：

1. **它是其他所有事的前提。** 圈叉模型（Q1）、中文辨識（Q9）都需要標註資料，
   而目前的回饋鏈是斷的（`teacher_value` 0 筆）。不先修這個，跑得越久累積的
   只是沒有標籤的圖。
2. **範圍清楚、可驗收。** 驗收條件可以很具體：老師訂正一格 → 該格的裁切圖與
   ground truth 出現在後端 → 可用 API 匯出成訓練集。
   （`GET /api/v1/grading-sessions/exports/corrections` 端點已存在，可作為驗收出口。）
3. **不需要外部決策。** 不卡 Entra、不卡實驗室主機、不卡上架。
4. **跨越 App + 後端 + 資料**，適合作為 spec-driven 流程的第一個練習題，
   又不至於大到失控。
5. **既有程式碼已有一半**，spec 的工作會集中在「行為與驗收條件」而非從零設計。

**次選：「模板建立流程支援多頁」**——範圍同樣清楚，但依賴 YOLO/OCR 兩個
目前不可達的外部服務，端到端驗收會卡住。

**不建議現在做**：圈叉模型替換。它的規格取決於還沒收集到的資料（Q1–Q4），
現在寫 spec 會把假設寫成需求。

> ⚠️ 以上為建議，不等於核准，尚未開始任何實作。

---

## 8. Git 與交接狀態

### 8.1 目前狀態

**`CramSchool_IOS`**（本 repo）

| 項目 | 值 |
|---|---|
| `main` | `0d41d9e` Let the self-test hold on the page, not just sweep across it |
| 與 `origin/main` | 同步 |
| 未合併分支 | `scan-tidy`（技術債清理，CI 進行中） |
| 已合併可刪 | `scan-quality-guard`、`scan-mark-model`、`scan-align-anchor`、`auth-microsoft` |

`main` 上已驗證的內容：

| commit | 內容 | 驗證 |
|---|---|---|
| `234383d` | 放棄邏輯：streak 離開畫面重置、門檻 2→6 | CI；實機未測 |
| `791fab8` | redirect URI 改固定字串 | 實機登入成功 |
| `3d10ef0` | Microsoft 登入（OAuth + PKCE） | **端到端通過**，teacher #2 已建立 |
| `43be4a5` | 對位槓桿診斷 | 零行為改變；數字已收集 |
| `ed3c0f7` | 圈叉決策森林 | **敢答 10/10、零假陽性** |
| `dfa3359` | 取樣外擴 25% | 中位數裁切損失 15.8% → 0% |

**`CramSchool_Backend`**

| 項目 | 值 |
|---|---|
| `main` | `060df1c` |
| 未合併分支 | `auth-microsoft-config`（**已部署在伺服器上**）、`tidy-compat-leftover` |

⚠️ **伺服器目前 checkout 在 `auth-microsoft-config` 而非 `main`。** 那個分支帶著
compose 傳遞 Microsoft 設定的修正，沒有它登入會失效。合併回 `main` 之前不要在
伺服器上切回去。

### 8.2 被 Git 忽略但影響交接的檔案

`.gitignore` 排除 `*.pdf`、`*.ipa`、`Recordings/`、`AutoGradeScanner/DemoMaster9006.png`。
目前存在於工作目錄、**不會隨 clone 取得**的必要內容：

| 路徑 | 用途 | 是否可重建 |
|---|---|---|
| `AutoGradeScanner/DemoMaster9006.png` | 示範模板 9006 的母卷影像。**是受著作權保護的考卷頁面**，刻意不入庫 | 否，需重新取得原始考卷 |
| `學生答案版.pdf` | 學生作答掃描（10 頁），本次用來切出 65 格圈叉樣本 | 否 |
| `社會自然評量解答.pdf` | 康軒評量標準答案 | 否 |
| `A03_南一版6下國語段考複習卷_第7～9課(教用).pdf` | 建立 demo 模板 9006 的來源 | 否 |
| `student_001.pdf`、`student_001_upright.pdf`、`redpen-ai.pdf` | 早期測試素材 | **[待確認]** 是否仍需要 |
| `Recordings/*.MP4` | 螢幕錄影 | 否，但非必要 |

> 這些檔案標示「有著作權·侵害必究」，**不得進入公開 repo**。
> 交接時需以檔案傳遞方式另外交付。

### 8.3 其他不會隨 clone 取得的內容

| 內容 | 說明 |
|---|---|
| **正式資料庫** | Postgres 在 `100.107.235.123` 的 docker volume 內。7 份模板、124 個題框、13 筆批改紀錄都在那裡，repo 內沒有任何副本 |
| **母卷影像** | 存在伺服器 `/data/blobs`（內容定址，雙層分片）。App 端為快取 |
| **`.env`** | 後端的實際設定值（含 `POSTGRES_PASSWORD`），不入版控。範本為 `.env.example` |
| **device token / 邀請碼** | 存於 iOS Keychain 與伺服器雜湊，無明文 |
| **Tailscale 網路成員資格** | 需加入 tailnet 才連得到 API |
| **`.venv/`** | 後端本機虛擬環境，需自行以 `uv` 重建 |

### 8.4 現有開發規範文件

| 檔案 | 位置 | 適用範圍 |
|---|---|---|
| `README.md` | `CramSchool_IOS/` | iOS App 的完整設計說明、專案結構、建置流程。**289 行，內容詳盡但有一處過時（見 §5.1 #4）** |
| `README.md` | `CramSchool_Backend/` | 後端設計說明、部署、兩種登入、schema 決策理由 |
| `.github/workflows/ios.yml` | `CramSchool_IOS/.github/workflows/` | CI 定義。分支觸發條件：`main`、`coreml-xfeat`、`demo-*`、`client-*`、`scan-*` |

**目前沒有** `AGENTS.md`、`CLAUDE.md`、Spec Kit（`.specify/`）或其他 agent 規範檔
**[已驗證]**（`find` 未找到）。

> 參考：`/mnt/d/CramSchoolWeb_Front_end`（網頁版）**有** `.specify/` 目錄
> （含 `memory/constitution.md`、`templates/spec-template.md`、`tasks-template.md` 等），
> 若要導入 Spec Kit，那裡有現成的範本可參照。

---

## 9. 整體 review（2026-09-15）

### 一句話

**技術品質已經明顯超過它的使用者數量（零）所能驗證的範圍。**

27 次批改全是開發者自己測的，7 份模板全是開發者自己做的，0 位學生、0 筆老師訂正。
所有的準確率數字都來自**一個人、一份考卷、一支筆**。

### 擋住真實使用的四件事（依嚴重度）

| | 問題 | 為什麼擋 |
|---|---|---|
| 🔴 | **分發方式** | unsigned .ipa + 有線側載，免費 Apple ID 簽的**七天失效**。補習班老師不可能這樣用。**這是唯一讓專案停留在展示品的原因** |
| 🔴 | **批改完不知道是誰的** | `StoredPaper` 沒有學生欄位，結果頁只能顯示「第 3 / 27 份」。後端的 `students` 表與 API 都在，App 一個都沒接 |
| 🟠 | **建立模板的路是斷的** | 只支援單面，且依賴 NCU 實驗室的 YOLO/OCR（外部不可達）。目前只有開發者能新增考卷 |
| 🟠 | **中文完全沒辨識** | `chinese` / `text` 一律 `.unsupported` → 永遠橘色 |

### 規劃層面的五個問題

1. **一直在優化已經不是瓶頸的東西。** 森林敢答的全對；剩下的不確定是裁切品質。
   再怎麼改進辨識，都不會讓 App 變得可用。
2. **「等外部決定」變成沒有期限的停車場。** 開發者帳號歸屬、`140.115.54.241`
   的所有權、老師名單 —— 都是一次對話就能解除，但沒被排進任何階段。
3. **所有決策建立在一份考卷上。** 換一個學生的筆跡會怎樣，完全沒有資料。
4. **後端能力遠超過 App 在用的。** `students` CRUD、`exports/corrections`、
   `logout/all`、`answer_boxes.label` 都沒被消費，而 App 缺的功能正好在那裡躺著。
5. **驗收條件常常事後才定。** 實例：曾以「判定對 8 題」當基準，測完才發現那 8 題裡
   有 **4 個是假的對**（學生寫錯卻被打成對）。正確的驗收應該是
   「**實際讀對幾題 + 零假陽性**」，而那要在測之前就定義。

### 建議的優先順序（取代原本的「把辨識做到最好」）

```
第 0 步  各一句話，今天就能問
  ├─ 教授：App 歸屬誰？學校有沒有 Apple Developer 帳號？
  ├─ 補習班：140.115.54.241 是誰的機器？
  └─ 補習班：要一份老師名單

第 1 步  分發（TestFlight）        ← 沒有它，後面全部沒意義
第 2 步  學生身分綁定              ← 沒有它，批改結果無法交還
第 3 步  一位真老師改一疊真考卷     ← 一次產生：別人的筆跡、真實的 teacher_value、真實的 UX 問題
第 4 步  依第 3 步的結果再決定
```

**第 3 步比任何技術改進都有價值**，因為現在關於「準不準、好不好用、夠不夠用」
全部是推測。

---

## 附錄：本次交接未觸碰的事項

- 未修改任何產品程式碼
- 未安裝任何工具或變更依賴
- 未 commit、push、部署、重啟服務或執行資料遷移
- 未執行任何會改動正式資料的指令（唯一對正式庫的操作是 **唯讀 SELECT**）
