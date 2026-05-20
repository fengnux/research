# CI Apply 失敗處理 Runbook

> 事件發生時照著做的可重複手冊。不是學習路徑，與 `iac/labs/` 區隔。

## 適用情境

- GitHub Actions workflow（PR 階段 plan、main 階段 apply、Trivy scan）在執行中失敗
- 涉及 stack 是**非 foundational**（dev/* 等走 CI apply 的 stack）
- foundational stack（org/, ci/, 帳號 bootstrap）走 manual apply，不適用本文件 → 見 [ADR-003](../../decisions/0003-foundational-vs-application-stacks.md)

不適用：

- 雲端資源已建立但 state 漂移 → 由 drift workflow 處理（另案）
- 本地開發階段的 `tofu plan` 失敗 → 直接修 code 重跑，不需要走 recovery

---

## 故障分類與處理路徑

```
CI workflow fail
├─ A. Code 本身有問題（syntax、HCL 錯、validate fail、plan 報 invalid value）
│     → 新 commit 修 code → push 自動觸發 CI
│
├─ B. Code 沒問題，外部條件不足（IAM 403、API not enabled、quota、上游資源不存在）
│     → 1. 先修外部條件（補 IAM / 開 API / 申請 quota / 補上游 stack）
│     → 2. 用 terramate trigger --change 強制重 apply（見下方步驟）
│     → ❌ 不要用 gh run rerun --failed（解釋見「為什麼不能 rerun」）
│
└─ C. Apply 部分成功部分失敗（中途 timeout、partial state）
      → 1. tofu state list 看實際建到哪
      → 2. 評估：補 code 讓 plan 收斂 / import 既有資源 / destroy 重來
      → 3. 走 B 的 trigger 路徑重 apply
```

---

## 路徑 B 步驟：用 terramate trigger 重 apply

### 適用前提

- 失敗原因已排除（IAM 已補、API 已開、上游已 apply）
- stack code 沒改，純粹要讓 CI 重跑

### 操作

```bash
# 1. 切新分支
git checkout main && git pull
git checkout -b <fix-stack>-rerun

# 2. 標記 stack 為 changed
terramate trigger --change \
  --reason "<為什麼要重 apply，引用失敗 commit / PR>" \
  stacks/<path>/<stack>

# 3. trigger 檔會出現在 .tmtriggers/，commit
git add .tmtriggers
git commit -m "chore(trigger): re-apply <stack> after <reason>"
git push -u origin <branch>

# 4. 開 PR，等 CI plan
gh pr create --title "..." --body "..."

# 5. CI plan 確認與失敗前的 plan 一致（或符合預期變化）後 merge
# 6. main workflow apply 跑完
```

### 驗收清單

- [ ] PR CI plan 顯示該 stack 在 changed list
- [ ] Plan 數字符合預期（與失敗前對照）
- [ ] Merge 後 main apply 無錯誤
- [ ] 雲端資源實際存在（`gcloud … list` / console）
- [ ] `tofu state list` 對得上 plan 內容

### Trigger 檔清理（選）

`.tmtriggers/` 必須 commit 不可 gitignore。trigger 檔刪掉不影響過去 run，可以：

- 留著當紀錄（每次重 apply 各一份）
- 後續 PR 順手 `rm -r .tmtriggers/` 清理

兩者皆可，本 repo 預設留著。

---

## 為什麼不能 `gh run rerun --failed`

`gh run rerun` 重跑的是「當時 commit 的 workflow run」，但：

1. **main 已往前**：失敗的 PR merge 後，main 已多了若干 commit
2. **Workflow 內 git check 對不上**：Terramate change detection / base-branch check / git log 在新的 main HEAD 下，與當初 PR commit 算出來的結果不一致
3. **Symptoms**：rerun attempt 直接掛在 setup / change detection 階段，看不出根因

已踩過的案例：

- Lab 05a 踩坑三（[2026-05-17.md](../../logs/2026-05-17.md)）
- Lab 05b 踩坑三（[2026-05-19.md](../../logs/2026-05-19.md)）
- 雙重打擊 → 列為硬性禁忌

**例外**：如果 main 自失敗以來**完全沒動**（你是唯一推進者、確定 0 commit 進來），`rerun` 在理論上可行；但成本/收益不對等，建議一律走 trigger。

---

## 路徑 A 補充：純 code 修

不需要 trigger。流程：

```bash
git checkout <failed-pr-branch>  # 或開新分支
# 修 code
git commit -am "fix: ..."
git push
```

Change detection 會因為 code diff 自動把 stack 列為 changed，CI 自動跑。

---

## 路徑 C 補充：partial state 處理

優先順序（從輕到重）：

1. **補 code 收斂 plan**：若失敗在後半段且前面 resource 都正常進 state，補對應 code 讓 plan 顯示「只剩未建的部分」，走路徑 B
2. **import 既有資源**：雲端已建但 state 沒記錄（少見，通常發生在 race），用 `tofu import`
3. **destroy 重來**：本 repo 慣例「[運算類資源實驗完即拆](../../../memory/project_teardown_after_lab.md)」，VM/GKE 等便宜砍，砍完走路徑 B 從零 apply

---

## 相關

- [ADR-003 Foundational vs Application Stacks](../../decisions/0003-foundational-vs-application-stacks.md)
- [Terramate Change Detection](../terramate-change-detection.md)
- [Terramate Stack Triggers 官方文件](https://terramate.io/docs/how-to/change-detection/stack-triggers)
- 案例：[Lab 05b PR #24](https://github.com/fengnux/tofu-terramate-lab/pull/24)（trigger 路徑首次成功應用）
