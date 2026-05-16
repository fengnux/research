# Lab 04b - Plan/Apply SA 拆分：最小權限原則

## 目標

把單一 CI Service Account 拆成兩個，讓 PR plan job 只有 read-only 權限，無法修改任何 GCP 資源：

| SA | 用途 | 觸發時機 | 權限等級 |
|----|------|---------|---------|
| `github-actions-tofu` （現有） | Apply SA | Push to `main` | 完整 CI 權限（現狀不變） |
| `github-actions-tofu-plan` （新增） | Plan SA | PR plan job | Read-only |

**安全意義：** PR 來自任何貢獻者（fork PR 除外），plan 階段只能讀不能寫。即使 plan job 被惡意程式碼劫持，最多洩漏 state 內容，無法變更 GCP 資源。

## 前置條件

- Lab 04、04a、04c、04f 完成
- 本機 ADC 有建立 SA / project IAM 的權限
- `tofu-terramate-lab` 本地 repo 為最新狀態（`git pull`）

---

## 設計重點

### WIF Binding 策略：用 `principal://subject` 精確匹配

GitHub Actions OIDC token 的 `sub`（subject）claim 格式固定：

| 觸發事件 | subject 值 |
|---------|-----------|
| Push to `main` | `repo:fengnux/tofu-terramate-lab:ref:refs/heads/main` |
| Pull Request | `repo:fengnux/tofu-terramate-lab:pull_request` |

用 `principal://` 精確匹配 subject，讓兩個 SA 的 WIF binding 互不重疊：

```hcl
# Apply SA：只有 main push 能 impersonate
member = "principal://iam.googleapis.com/{pool}/subject/repo:fengnux/tofu-terramate-lab:ref:refs/heads/main"

# Plan SA：只有 PR 能 impersonate
member = "principal://iam.googleapis.com/{pool}/subject/repo:fengnux/tofu-terramate-lab:pull_request"
```

相較現有 `principalSet://...attribute.repository/...`（只限 repo），這個方式進一步把 apply SA 綁定到 main branch，plan SA 綁定到 PR event。

### Plan SA 最小權限

Plan 階段需要：讀 GCS state + 讀 GCP 資源現況（drift check）。
現有 dev/vm stack 管理 Compute Engine，因此 plan SA 需要：

| Role | 用途 |
|------|------|
| `roles/storage.objectViewer` | 讀 GCS backend state 檔 |
| `roles/compute.viewer` | 讀 VM、網路、防火牆資源現況 |
| `roles/serviceusage.serviceUsageViewer` | 讀 API enablement 狀態 |

---

## 變更範圍

| 檔案 | 變更內容 |
|------|---------|
| `stacks/ci/github-actions-wif/main.tf` | 新增 plan SA + plan roles + 更新兩個 WIF binding |
| `stacks/ci/github-actions-wif/outputs.tf` | 新增 `plan_service_account_email` output |
| `.github/workflows/opentofu.yml` | plan job 改用 plan SA |

---

## 步驟

### 1. 修改 `main.tf`

**新增 locals：**
```hcl
plan_service_account_id = "github-actions-tofu-plan"

plan_project_roles = [
  "roles/storage.objectViewer",
  "roles/compute.viewer",
  "roles/serviceusage.serviceUsageViewer",
]
```

**新增 plan SA resource：**
```hcl
resource "google_service_account" "github_actions_tofu_plan" {
  account_id   = local.plan_service_account_id
  display_name = "GitHub Actions OpenTofu Plan"
  description  = "Read-only SA for PR plan jobs via Workload Identity Federation"

  depends_on = [
    google_project_service.required["iam.googleapis.com"],
  ]
}
```

**更新 apply SA WIF binding**（`principalSet` → `principal://subject`）：
```hcl
resource "google_service_account_iam_member" "github_actions_wif" {
  service_account_id = google_service_account.github_actions_tofu.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/subject/repo:${local.github_repo}:ref:refs/heads/main"
}
```

**新增 plan SA WIF binding：**
```hcl
resource "google_service_account_iam_member" "github_actions_wif_plan" {
  service_account_id = google_service_account.github_actions_tofu_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/subject/repo:${local.github_repo}:pull_request"
}
```

**新增 plan SA project IAM：**
```hcl
resource "google_project_iam_member" "github_actions_tofu_plan" {
  for_each = toset(local.plan_project_roles)

  project = data.google_client_config.current.project
  role    = each.value
  member  = google_service_account.github_actions_tofu_plan.member
}
```

### 2. 修改 `outputs.tf`

新增：
```hcl
output "plan_service_account_email" {
  description = "Read-only service account email for PR plan jobs"
  value       = google_service_account.github_actions_tofu_plan.email
}
```

### 3. 本機 apply WIF stack

```bash
cd ~/GitHub/tofu-terramate-lab
terramate run --tags wif -- tofu plan
```

預期 plan 輸出：
- `+` `google_service_account.github_actions_tofu_plan`（新增）
- `+` `google_service_account_iam_member.github_actions_wif_plan`（新增）
- `+` `google_project_iam_member.github_actions_tofu_plan` × 3（新增）
- `~` `google_service_account_iam_member.github_actions_wif`（member 從 principalSet 改 principal）

確認後：
```bash
terramate run --tags wif -- tofu apply
```

### 4. 修改 `.github/workflows/opentofu.yml`

在 workflow 頂層 env 新增 plan SA：

```yaml
env:
  GCP_SERVICE_ACCOUNT_PLAN: "github-actions-tofu-plan@research-lab-495809.iam.gserviceaccount.com"
```

`plan` job 的 auth step 改用 plan SA：
```yaml
- id: auth
  uses: google-github-actions/auth@v3
  with:
    project_id: ${{ env.GCP_PROJECT_ID }}
    workload_identity_provider: ${{ env.GCP_WIF_PROVIDER }}
    service_account: ${{ env.GCP_SERVICE_ACCOUNT_PLAN }}
```

`apply` job 維持原 `GCP_SERVICE_ACCOUNT`（不動）。

### 5. commit + push（到 main）

```bash
git add stacks/ci/github-actions-wif/main.tf \
        stacks/ci/github-actions-wif/outputs.tf \
        .github/workflows/opentofu.yml
git commit -m "security(wif): split plan/apply service accounts for least privilege"
git push
```

> Foundational warning 會觸發（WIF stack 有變更），CI 不 fail。

### 6. 驗證

#### 6a. `gcloud` 確認 plan SA 存在
```bash
gcloud iam service-accounts describe \
  github-actions-tofu-plan@research-lab-495809.iam.gserviceaccount.com \
  --project=research-lab-495809
```

#### 6b. 開測試 PR 驗證 plan job 改用 plan SA
- PR plan job auth step 成功
- plan job 能讀 GCS state（objectViewer）
- plan job 能讀 Compute 資源（compute.viewer）

#### 6c. Merge PR 驗證 apply job 仍正常（apply SA 不變）

---

## 驗收清單（2026-05-16 驗證通過）

- [x] `main.tf` 新增 plan SA + plan roles + 兩個 WIF binding 各自精確匹配
- [x] `tofu apply` 成功（6 added, 1 destroyed）
- [x] PR plan job auth 使用 plan SA 成功（[PR #7](https://github.com/fengnux/tofu-terramate-lab/pull/7)）
- [x] PR plan job `tofu plan -lock=false` 21 秒正常完成
- [x] Apply job 繼續使用 apply SA，auth 成功

---

## 風險與回退

| 風險 | 處理方式 |
|------|---------|
| plan SA 缺少某個 viewer role，`tofu plan` 400/403 | 加對應 viewer role 到 `plan_project_roles`，re-apply |
| apply SA binding 改 `principal://subject` 後 apply job auth 失敗 | 確認 push event subject 格式；可暫時改回 `principalSet://` 解除封鎖 |
| PR plan job 用 plan SA 但 plan SA 沒法讀 state | plan SA 需 `roles/storage.objectViewer`，確認 binding 有套用到正確 bucket |

---

## 後續（Lab roadmap）

04b 完成後，04d（drift detection）即可安全使用 plan SA 跑排程 plan，攻擊面最小。
