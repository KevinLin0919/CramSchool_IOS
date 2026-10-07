# Issue tracker：本機 Markdown（與後端 repo 共用）

spec 與 issue 不放在這個 repo，而是放在後端 repo 的 `docs/changes/`：

```
../CramSchool_Backend/docs/changes/<slug>/spec.md
../CramSchool_Backend/docs/changes/<slug>/issues/<NN>-<slug>.md
```

格式、狀態行、認領與交接規則都照 `../CramSchool_Backend/docs/agents/issue-tracker.md`。
建立或更新 issue 時，記得也在後端 repo commit 並 push。

## When a skill says "publish to the issue tracker"

在 `../CramSchool_Backend/docs/changes/<slug>/` 底下建立檔案，並更新 `../CramSchool_Backend/docs/progress.md`。

## When a skill says "fetch the relevant ticket"

讀使用者給的路徑或編號對應的檔案。
