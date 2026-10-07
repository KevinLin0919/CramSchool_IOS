# Domain Docs

## Before exploring, read these

- **`../CramSchool_Backend/CONTEXT.md`**：全系統共用的用語表（模板、母卷、格、正解、選項、待確認、角色…）。
- **本 repo 的 `docs/adr/`**：App 內部的決策（對位、覆蓋框、逐格定位、選項、數字模型）。
- **`../CramSchool_Backend/docs/adr/`**：系統層級的決策（環境分離、對外連線、批改在手機上、角色）。

檔案不存在就直接往下做，不必提醒使用者補。

## Use the glossary's vocabulary

提到領域概念時用 `CONTEXT.md` 定義的詞；對使用者說話用中文的那個詞。缺詞時交給 `/domain-modeling` 補在後端 repo 的 `CONTEXT.md`。

## Flag ADR conflicts

產出和既有 ADR 衝突時明講，例如：

> _和 ADR-0003（逐格定位、手機在轉時不讀）衝突，但值得重新討論，因為…_
