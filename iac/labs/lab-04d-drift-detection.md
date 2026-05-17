# Lab 04d - Scheduled Drift Detection

## 目標

每天定時對所有非 foundational stack 執行 `tofu plan -detailed-exitcode`，偵測 GCP 實際狀態與 Terraform state 是否有偏差（drift）。發現 drift 時在 GitHub repo 開 Issue 通知。

## 設計重點

### 為何用專屬 drift SA 而非 plan SA

Drift detection 只需要讀取 state 和 GCP 資源，不需要寫入。Plan SA（`github-actions-tofu-plan`）的 WIF binding 是 `pull_request` subject，schedule / workflow_dispatch 的 subject 是 `ref:refs/heads/main`，兩者不同。

因此建立獨立的 `github-actions-tofu-drift` SA，WIF binding 綁 `ref:refs/heads/main`，Roles 與 plan SA 相同（read-only）：`objectViewer`、`compute.viewer`、`serviceUsageViewer`。職責拆分清楚，未來個別撤銷不互相影響。

### WIF subject for scheduled events

GitHub OIDC token 的 subject 格式依 event 而定：

| Event | subject |
|-------|---------|
| `push` to main | `repo:fengnux/tofu-terramate-lab:ref:refs/heads/main` |
| `pull_request` | `repo:fengnux/tofu-terramate-lab:pull_request` |
| `schedule` / `workflow_dispatch` on main | `repo:fengnux/tofu-terramate-lab:ref:refs/heads/main` |

### 為何新建專屬 drift SA

Scheduled drift detection 用途獨立，單獨建立 `github-actions-tofu-drift` SA：

- 職責清楚：plan SA 綁 PR、apply SA 綁 main push、drift SA 綁 scheduled/manual
- 未來個別調整權限或撤銷不互相影響
- Roles 與 plan SA 相同（read-only）：`objectViewer`、`compute.viewer`、`serviceUsageViewer`

### tofu plan -detailed-exitcode

| 退出碼 | 意義 |
|--------|------|
| 0 | 成功，無變更 |
| 1 | 錯誤（provider 連線失敗、state 損毀等） |
| 2 | 成功，**偵測到 drift**（有待套用的變更） |

> ⚠️ 實作上不能用 `terramate run --continue-on-error -- sh -c '... tofu plan; printf'`：`sh -c` 的 exit code 是最後一個指令（`printf`，exit 0），會把 exit 2 蓋掉，導致 drift 永遠偵測不到。正確做法是逐 stack 手動迴圈，搭配 `|| plan_exit=$?` 捕捉 exit code（詳見 Phase B）。

### Issue deduplication

避免每天開新 Issue，先查是否有 open 且帶 `drift` label 的 Issue：
- 有 → 在既有 Issue 補留言
- 無 → 新開 Issue

---

## 前置條件

- 完成 Lab 04b（plan/apply SA 拆分）
- `gh` CLI 在 workflow 中可用（GitHub-hosted runner 已內建）

---

## 步驟

### Phase A — WIF stack：新增 drift SA（本機 apply）

修改 `stacks/ci/github-actions-wif/main.tf`，新增以下資源：

```hcl
# locals 內新增
drift_service_account_id = "github-actions-tofu-drift"

drift_project_roles = [
  "roles/storage.objectViewer",
  "roles/compute.viewer",
  "roles/serviceusage.serviceUsageViewer",
]

# 新增 SA
resource "google_service_account" "github_actions_tofu_drift" {
  account_id   = local.drift_service_account_id
  display_name = "GitHub Actions OpenTofu Drift"
  description  = "Read-only SA for scheduled drift detection via Workload Identity Federation"

  depends_on = [
    google_project_service.required["iam.googleapis.com"],
  ]
}

# WIF binding（schedule / workflow_dispatch on main 的 subject）
resource "google_service_account_iam_member" "github_actions_wif_drift" {
  service_account_id = google_service_account.github_actions_tofu_drift.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/subject/repo:${local.github_repo}:ref:refs/heads/main"
}

# 專案 IAM roles（read-only）
resource "google_project_iam_member" "github_actions_tofu_drift" {
  for_each = toset(local.drift_project_roles)

  project = data.google_client_config.current.project
  role    = each.value
  member  = google_service_account.github_actions_tofu_drift.member
}
```

修改 `outputs.tf`，新增：

```hcl
output "drift_service_account_email" {
  description = "Drift detection SA email"
  value       = google_service_account.github_actions_tofu_drift.email
}
```

執行：

```bash
cd /Users/fengnux/GitHub/tofu-terramate-lab

# 確認變更（預期：SA 1 + WIF binding 1 + IAM 3 = 5 to add）
terramate run --tags foundational -- tofu plan

# apply
terramate run --tags foundational -- tofu apply
```

commit：

```bash
git add stacks/ci/github-actions-wif/main.tf stacks/ci/github-actions-wif/outputs.tf
git commit -m "feat(wif): add drift SA for scheduled drift detection"
git push
```

> ⚠️ push main 會觸發 foundational warning（WIF stack 變更），屬預期行為。

### Phase B — 新增 drift detection workflow

建立 `.github/workflows/drift.yml`（最終版本）：

```yaml
name: Drift Detection

on:
  # schedule:
  #   - cron: '0 2 * * *'   # 每天 02:00 UTC（台灣時間 10:00）
  workflow_dispatch:        # 手動觸發，方便測試

permissions:
  contents: read
  id-token: write
  issues: write

env:
  TOFU_VERSION: "1.11.6"
  TERRAMATE_VERSION: "0.17.0"
  GCP_PROJECT_ID: "research-lab-495809"
  GCP_WIF_PROVIDER: "projects/1074394836652/locations/global/workloadIdentityPools/github-actions/providers/github"
  GCP_SERVICE_ACCOUNT_DRIFT: "github-actions-tofu-drift@research-lab-495809.iam.gserviceaccount.com"

jobs:
  drift:
    name: Detect drift in all stacks
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6

      - name: Create plugin cache dir
        run: |
          mkdir -p "$HOME/.terraform.d/plugin-cache"
          echo "TF_PLUGIN_CACHE_DIR=$HOME/.terraform.d/plugin-cache" >> "$GITHUB_ENV"

      - uses: actions/cache@v5
        with:
          path: ~/.terraform.d/plugin-cache
          key: ${{ runner.os }}-tofu-providers-${{ env.TOFU_VERSION }}-google-7.31
          restore-keys: |
            ${{ runner.os }}-tofu-providers-

      - id: auth
        uses: google-github-actions/auth@v3
        with:
          project_id: ${{ env.GCP_PROJECT_ID }}
          workload_identity_provider: ${{ env.GCP_WIF_PROVIDER }}
          service_account: ${{ env.GCP_SERVICE_ACCOUNT_DRIFT }}

      - uses: terramate-io/terramate-action@v3
        with:
          version: ${{ env.TERRAMATE_VERSION }}

      - uses: opentofu/setup-opentofu@v2
        with:
          tofu_version: ${{ env.TOFU_VERSION }}
          tofu_wrapper: false

      - name: tofu init (all non-foundational stacks)
        run: terramate run --no-tags foundational -- tofu init -input=false

      - name: Drift check
        id: drift
        run: |
          drift_found=false
          error_found=false
          report="${{ runner.temp }}/drift-report.md"

          {
            echo "## Drift Detection Report"
            echo ""
            echo "**Run:** ${{ github.run_id }} | **Time:** $(date -u '+%Y-%m-%d %H:%M UTC')"
            echo ""
          } > "$report"

          while IFS= read -r stack; do
            printf "\n### Stack: %s\n\`\`\`\n" "$stack" >> "$report"
            plan_exit=0
            (cd "$GITHUB_WORKSPACE/$stack" && tofu plan -detailed-exitcode -no-color -input=false -lock=false) \
              >> "$report" 2>&1 || plan_exit=$?
            printf "\`\`\`\n" >> "$report"

            case $plan_exit in
              0) ;;
              2) drift_found=true ;;
              *) error_found=true ;;
            esac
          done < <(terramate list --no-tags foundational)

          echo "drift_found=$drift_found" >> "$GITHUB_OUTPUT"
          echo "error_found=$error_found" >> "$GITHUB_OUTPUT"

      - name: Open or update GitHub Issue on drift
        if: steps.drift.outputs.drift_found == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh label create drift --color "#e4e669" --description "Infrastructure drift detected" 2>/dev/null || true

          report=$(cat ${{ runner.temp }}/drift-report.md)
          existing=$(gh issue list --label drift --state open --json number -q '.[0].number')

          if [ -n "$existing" ]; then
            echo "Drift issue #$existing already open, adding comment."
            gh issue comment "$existing" --body "$report"
          else
            echo "Opening new drift issue."
            gh issue create \
              --title "Drift detected: $(date -u '+%Y-%m-%d')" \
              --label drift \
              --body "$report"
          fi

      - name: Fail workflow on plan error
        if: steps.drift.outputs.error_found == 'true'
        run: |
          echo "::error::One or more stacks failed to plan. Check the logs above."
          exit 1

      - name: Fail workflow on drift
        if: steps.drift.outputs.drift_found == 'true'
        run: |
          echo "::error::Drift detected. See GitHub Issue for details."
          exit 1
```

> ⚠️ `TF_PLUGIN_CACHE_DIR` 必須透過 `GITHUB_ENV` 設定而非 YAML `env` block：YAML env 不展開 `~`，OpenTofu 的 Go 程式碼會把 `~/` 當相對路徑在 stack 目錄下建立 `~` 資料夾，觸發 Terramate git-untracked safeguard。

commit + push main：

```bash
git add .github/workflows/drift.yml
git commit -m "feat(ci): add scheduled drift detection workflow"
git push
```

### Phase C — 驗證

#### 方法 1：`workflow_dispatch`（推薦）

1. GitHub UI → Actions → "Drift Detection" → **Run workflow** → 選 `main`
2. 觀察 workflow：
   - 若無 drift：drift step 綠，無 Issue 建立
   - 若有 drift：drift step 標 failure，自動開 Issue

#### 方法 2：手動製造 drift

1. 在 GCP Console 直接修改某 compute 資源（如改 VM description）
2. 觸發 `workflow_dispatch`
3. 驗收 drift 偵測 → Issue 建立
4. 恢復資源 → 確認下次執行 Issue 有留言更新

---

## 驗收清單

| 項目 | 預期結果 |
|------|---------|
| Drift SA WIF auth（`ref:refs/heads/main` subject） | ✅ |
| 所有非 foundational stack 執行 `tofu plan -detailed-exitcode` | ✅ |
| exit 0（無變更）→ 不開 Issue，workflow 成功 | ✅ |
| exit 2（drift）→ 自動開 Issue，workflow fail | ✅ |
| exit 1（plan error）→ 不開 Issue，workflow fail | ✅（設計驗證） |
| 重複執行時在既有 Issue 留言（不重複開） | ✅（設計驗證） |
| `workflow_dispatch` 手動可觸發 | ✅ |
| Provider plugin cache 避免下載 timeout | ✅ |

### 已知 drift：dev/vm

`stacks/dev/vm` 在 Lab 03c 執行 `tofu destroy` 後 VM 已從 GCP 刪除，但 `main.tf` 保留供實驗參考，drift detection 會持續偵測到 `Plan: 1 to add`。此為預期狀態，Schedule trigger 暫時停用，待日後決定處置方式（移除 config 或排除該 stack）後再重新啟用。
