# Lab 04a - Apply Approval Gate：GitHub Environment + Required Reviewer

## 目標

把 `tofu-terramate-lab` 的 CI `apply` job 綁定 GitHub Environment，加上 required reviewer，讓 `main` push 不會直接動 GCP，必須人工核可後才會 apply。

## 為什麼要做

Lab 04 完成後 `main` push 會自動 apply 所有 changed stacks。雖然 PR review 已經過一次，但：

- Merge button 一按下去就改 GCP，沒有「最後一道剎車」
- 緊急 hotfix 或 misclick 沒有暫停窗口
- 未來引入新人，approval gate 是基礎治理

業界做法：apply 綁 environment，require manual approval（GitHub Environments protection rules）。

## 前置條件

- Lab 04 完成（WIF + workflow 已可運作）
- `fengnux/tofu-terramate-lab` 為 public repo，個人帳號 GitHub Free plan 也支援 Environment 與 required reviewers

## 設計重點

### Environment 名稱

採 `production`。理由：
- GitHub 慣例（CI 文件、blog post 範例都用這個）
- 之後若加 `staging`、`dev` environment 命名一致

### Protection rules

| 規則 | 設定 |
|------|------|
| Required reviewers | `fengnux`（自己；之後加團隊成員時擴充） |
| Wait timer | 0 分鐘（個人實驗不需強制等待） |
| Deployment branches | `Selected branches` → `main`（防止其他 branch 誤觸） |

### Workflow 改動

只動一處：`apply` job 加 `environment: production`。

```yaml
apply:
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  needs: [generate-check]
  runs-on: ubuntu-latest
  environment: production   # ← 新增
  permissions:
    contents: read
    id-token: write
  steps:
    ...
```

`environment` 欄位是觸發 protection rules 的關鍵，required reviewer 會在這個 job 開始前阻擋執行。

### Secrets / variables 不搬

目前 workflow 用的 WIF provider 名稱與 SA email 寫在 workflow YAML 裡（非 secrets）。本輪不搬到 Environment-scoped variables，維持單純。之後若拆 plan/apply SA（Lab 04b）再評估。

---

## 步驟

### 1. 在 GitHub UI 建立 Environment

路徑：`fengnux/tofu-terramate-lab` → Settings → Environments → New environment

- Name：`production`
- 點進去後設定 `Deployment protection rules`：
  - ✅ Required reviewers → 加 `fengnux`
  - ☐ Prevent self-review（不勾，個人 repo 必須能自己核可）
  - ☐ Wait timer（不勾）
- `Deployment branches and tags` → `Selected branches and tags` → 新增 `main`

> 若 UI 看不到 `Deployment protection rules` 區塊，先確認當前位置是 repo 的 Settings（不是 user/org 的 Settings）；user-owned public repo 的 Environment 細節頁有此區塊。

#### 驗證

```bash
gh api repos/fengnux/tofu-terramate-lab/environments/production \
  | jq '{name, protection_rules, deployment_branch_policy}'
gh api repos/fengnux/tofu-terramate-lab/environments/production/deployment-branch-policies \
  | jq '.branch_policies[].name'
```

預期：
- `protection_rules` 含一筆 `required_reviewers`（reviewer = `fengnux`）與一筆 `branch_policy`
- 允許 branch 為 `main`

### 2. 修改 workflow

編輯 `.github/workflows/opentofu.yml`，在 `apply` job 加入：

```yaml
environment: production
```

放在 `runs-on` 下一行即可，其他保持不變。

### 3. 驗證 PR plan 仍能正常跑

開一個 trivial 修改（例：改 stack 內某 comment），推 PR。預期：

- `plan` job 照常跑（沒綁 environment）
- 無 reviewer 等待

### 4. 驗證 apply 會卡 approval

Merge PR 到 `main` 後，預期：

- `detect-foundational-changes`、`generate-check` 照常跑
- `apply` job 顯示 `Waiting` 狀態，並出現「Review pending deployments」按鈕
- 點 Review → Approve → apply 才開始執行

### 5. 確認 reject 路徑

再開一個 trivial PR merge 後，這次點 Review → Reject。預期：

- `apply` job 標記為 failed
- GCP 無變更
- GCS state 無新 generation

---

## 驗證清單

- [ ] GitHub Environment `production` 存在
- [ ] Required reviewer 設定為 `fengnux`
- [ ] Deployment branch 限制為 `main`
- [ ] `apply` job 在 main push 後進入 `Waiting` 狀態
- [ ] Approve 後 apply 成功執行
- [ ] Reject 後 apply 標記 failed 且 GCP 未變更
- [ ] PR `plan` job 不受 environment 影響

---

## 風險與回退

- **誤 reject 後想重跑**：在 Actions UI 找該 workflow run → Re-run failed jobs，會再次進入 approval 等待。
- **緊急情況需繞過 approval**：暫時把 environment 的 required reviewer 移除（不要刪 environment 本身），apply 完再加回去；或本機直接 `terramate run --no-tags foundational -- tofu apply`。
- **Environment 設錯導致 apply 永遠卡住**：本機直接 apply 是安全 fallback（WIF 不影響本機 ADC 流程）。

---

## 下一步

- Lab 04c：PR plan 結果回寫 PR comment
- Lab 04f：WIF condition 收斂（限定 repo + branch）
- 之後加 staging environment 時，protection rules 套用同一份設定
