# Lab 04 - CI Pipeline：GitHub Actions + WIF + Terramate Changed Stacks

## 目標

為 `tofu-terramate-lab` 建立 CI/CD：

1. PR 自動對 changed stacks 執行 `tofu init`、`tofu validate`、`tofu plan`
2. merge 到 `main` 後自動對 changed stacks 執行 `tofu apply`
3. GitHub Actions 透過 Workload Identity Federation 登入 GCP，不使用 service account JSON key
4. WIF stack 第一次由本機 ADC bootstrap，後續仍由本機手動維護

WIF 機制說明見 [Workload Identity Federation：GitHub Actions 登入 GCP](../docs/workload-identity-federation.md)。

## 前置條件

- 完成 [Lab 03c - 第一個 dev Compute VM](lab-03c-dev-vm.md)
- `tofu-terramate-lab` repo 已推到 GitHub：`fengnux/tofu-terramate-lab`
- 個人 ADC 對 `research-lab-495809` 有建立 IAM / WIF / service account / project IAM binding 的權限
- `gs://research-lab-495809-tofu-state` 已存在，且 bootstrap state 已遷移到 GCS

---

## 設計重點

### Pipeline 分工

| Event | 行為 |
|-------|------|
| `pull_request` | generate diff check、fmt check、**changed stacks（不含 foundational）** init/validate/plan + foundational 變更警示 |
| `push` to `main` | **changed stacks（不含 foundational）** init/apply + foundational 變更警示 |

PR 只做預覽，不改 GCP。合併到 `main` 後才由 CI apply。`foundational` tag 涵蓋 bootstrap 與 WIF stack —— 前者管 state bucket、後者管 CI 信任邊界，兩者都不該由 CI 自身修改（chicken-and-egg）。詳見 [Workload Identity Federation：為什麼 WIF stack 不讓 CI 自動 apply](../docs/workload-identity-federation.md#為什麼-wif-stack-不讓-ci-自動-apply)。

### WIF bootstrap

`stacks/ci/github-actions-wif` 管理：

- Workload Identity Pool：`github-actions`
- OIDC Provider：`github`
- Service Account：`github-actions-tofu`
- `roles/iam.workloadIdentityUser` binding
- CI 所需 project IAM roles

因為這個 stack 建立的是 CI 自己的身份，所以第一次必須由本機 ADC apply。Workflow 也會阻止 `main` 自動 apply WIF stack，避免 CI 修改自己的信任邊界。

### Changed stacks

PR workflow 使用：

```bash
terramate list --changed
terramate run --changed -- tofu plan
terramate run --changed -- tofu apply
```

PR 需要 `fetch-depth: 0`，讓 Terramate 能取得完整 git history 與 merge-base。
`main` push workflow 會改用 GitHub push event 的 `before` SHA 當 base：

```bash
terramate list --changed --git-change-base="${{ github.event.before }}"
terramate run --changed --git-change-base="${{ github.event.before }}" -- tofu apply
```

這樣 merge 到 `main` 後，CI 比較的是「這次 push 前後」的差異，而不是已經更新後的 `origin/main`。

---

## 步驟

### 1. 新增 WIF stack

在 `tofu-terramate-lab` 建立：

```text
stacks/ci/github-actions-wif/
├── stack.tm.hcl
├── main.tf
└── outputs.tf
```

此 stack 會產生 GitHub Actions 使用的 service account 與 WIF provider。Provider 的完整名稱固定為：

```text
projects/1074394836652/locations/global/workloadIdentityPools/github-actions/providers/github
```

### 2. 產生 Terramate generated files

```bash
cd ~/GitHub/tofu-terramate-lab
terramate generate
```

確認新 stack 產生：

- `_terramate_backend.tf`，prefix = `ci/github-actions-wif`
- `_terramate_provider.tf`
- `_terramate_versions.tf`

### 3. 本機 apply WIF stack

```bash
terramate run --tags wif -- tofu init
terramate run --tags wif -- tofu plan
terramate run --tags wif -- tofu apply
```

第一次 apply 完成後，等待約 5 分鐘讓 WIF / IAM 設定傳播。

WIF stack 的 `stack.tm.hcl` 須帶 `foundational` tag（與 bootstrap 一致），讓 CI workflow 可用 `--no-tags foundational` 一次性排除。

### 4. 檢查 outputs

```bash
terramate run --tags wif -- tofu output
```

預期看到：

```text
service_account_email = "github-actions-tofu@research-lab-495809.iam.gserviceaccount.com"
workload_identity_provider_name = "projects/1074394836652/locations/global/workloadIdentityPools/github-actions/providers/github"
```

### 5. 新增 GitHub Actions workflow

新增 `.github/workflows/opentofu.yml`，採單檔多 job 設計，依 event 分流：

| Job | 觸發條件 | 內容 |
|-----|---------|------|
| `detect-foundational-changes` | PR 與 `push` 都跑 | 用 `terramate list --changed --tags foundational` 偵測 bootstrap / WIF 變更；有變更時印 warning 並提示「需本機 apply」，**不 fail CI** |
| `generate-check` | PR 與 `push` 都跑 | `terramate generate && git diff --exit-code`，確保 generated files 與 source 同步 |
| `plan` | 僅 `pull_request` | `terramate run --changed --no-tags foundational -- tofu init/validate/plan` |
| `apply` | 僅 `push` to `main` | `terramate run --changed --git-change-base="${{ github.event.before }}" --no-tags foundational -- tofu init/apply` |

使用的 actions：

- `google-github-actions/auth@v3`
- `terramate-io/terramate-action@v3`
- `opentofu/setup-opentofu@v1`
- OpenTofu version：`1.11.6`
- Terramate version：`0.17.0`

`opentofu/setup-opentofu` 必須設定：

```yaml
tofu_wrapper: false
```

避免 wrapper 影響 Terramate 取得 OpenTofu 的 exit code。

### 6. 建立 PR 驗證 plan

建立 feature branch，修改任一 dev stack，例如 `stacks/dev/vm/main.tf`。

```bash
git checkout -b test/lab04-ci
git add .
git commit -m "test: verify lab04 ci"
git push -u origin test/lab04-ci
```

開 PR 後確認 workflow：

- `terramate generate` 後 `git diff --exit-code` 成功
- `terramate run --changed --no-tags foundational -- tofu fmt -check` 成功
- `terramate run --changed --no-tags foundational -- tofu validate` 成功
- `terramate run --changed --no-tags foundational -- tofu plan` 成功
- 沒有執行 apply

### 7. Merge 後驗證 apply

PR merge 到 `main` 後，`push` workflow 會執行：

```bash
terramate run --changed --git-change-base="$PUSH_CHANGE_BASE" --no-tags foundational -- tofu init -input=false
terramate run --changed --git-change-base="$PUSH_CHANGE_BASE" --no-tags foundational -- tofu apply -input=false -auto-approve -lock-timeout=5m
```

確認 GitHub Actions 成功，並檢查 GCS state 有更新。

---

## 驗證清單

- [ ] `terramate generate` 成功
- [ ] `terramate list --run-order` 顯示 `stacks/ci/github-actions-wif`
- [ ] WIF stack 本機 `tofu apply` 成功
- [ ] `tofu output workload_identity_provider_name` 與 workflow 內設定一致
- [ ] PR workflow 只 plan、不 apply
- [ ] `main` push workflow 可 apply changed stacks
- [ ] 修改 foundational stack（bootstrap 或 WIF）時，CI 印出 warning 但不 fail，並提示需本機 apply
- [ ] GitHub repo 沒有儲存任何 service account JSON key

---

## 風險與回退

- **WIF 立即失敗**：等待 5 分鐘再重跑 workflow，IAM/WIF 傳播需要時間。
- **`tofu init` 無法讀 GCS backend**：確認 `github-actions-tofu` 有 `roles/storage.objectAdmin`。
- **`terramate list --changed` 在 main 為空**：這是 git base 行為；PR workflow 最符合 changed stacks 模型。直接在 main 開發時，必要時用 `--git-change-base=HEAD~1` 做實驗。
- **WIF / bootstrap stack 需要修改**：從本機 ADC 執行 `terramate run --tags wif -- tofu apply`（或對應 bootstrap），不要讓 CI 自行修改。
- **PR plan 不嘗試 plan foundational stack**：CI service account 沒有 WIF resources viewer 權限、也沒有 state bucket 管理權限，若 PR 觸發 foundational stack 的 plan/apply 會失敗。workflow 統一用 `--no-tags foundational` 跳過，再由 `detect-foundational-changes` job 提示變更，讓審查者改走本機 apply 流程。
- **`.terraform.lock.hcl` 不入 git**：Terramate 官方範例做法（避免 CI Linux runner 補 hash 觸發 git-uncommitted safeguard）。詳見 [toolchain.md：Provider Lock File 政策](../docs/toolchain.md#provider-lock-file-政策)。

---

## 延伸實驗 Roadmap

執行順序原則：先做純 workflow 改動（不動 GCP），再做動 WIF stack 的，最後做外部 SaaS。

| Lab | 狀態 | 主題 | 設計重點 |
|-----|------|------|---------|
| [04a](lab-04a-apply-approval-gate.md) | ✅ done (2026-05-16) | Apply approval gate | `apply` job 綁 GitHub Environment `production` + required reviewer |
| [04c](lab-04c-pr-plan-comment.md) | ✅ done (2026-05-16) | PR plan sticky comment | `marocchino/sticky-pull-request-comment` 貼 plan 輸出；輸出檔必須寫 `${{ runner.temp }}` 避開 terramate git-untracked safeguard |
| 04f | 🔜 next | WIF condition 收斂 | 動 `stacks/ci/github-actions-wif`：`attribute_condition` 從只看 repo owner 收緊到 `repository=fengnux/tofu-terramate-lab` + branch/PR；本機 re-apply |
| 04d | 待 04b 後 | Drift detection | scheduled workflow 每日跑 `terramate run --no-tags foundational -- tofu plan -detailed-exitcode`；有 drift 自動開 issue。建議改用 04b 的 read-only SA 跑，較安全 |
| 04b | 待 | Plan/Apply SA 拆分 | WIF stack 新增 `github-actions-tofu-plan`（read-only）+ 第二組 WIF binding；PR workflow 改用 plan SA，apply job 維持原 SA |
| 04e | 待 | IaC 安全掃描 | tfsec 或 checkov 加進 PR job；SARIF 上傳 GitHub Code Scanning |
| 04g | 待 | Terramate Cloud 整合 | 連 Terramate Cloud：stack 拓撲視覺化、plan preview、drift dashboard；需評估免費額度與 OIDC 連線 |

### 共通踩坑提醒

- **`terramate run` git-clean safeguard**：workspace 不能有 untracked / uncommitted 檔案。CI 中若要產生 artifact（如 plan 輸出），一律寫到 `${{ runner.temp }}` 而非 workspace。
- **API payload 覆寫整體**：GitHub `PUT /repos/.../environments/{name}` 會覆寫整個 environment 設定，要動 protection rule 時記得帶上既有的 `deployment_branch_policy`，否則 branch policy 會被清空。
- **Foundational stack 例外**：WIF、bootstrap 永遠由本機 ADC apply，CI workflow 用 `--no-tags foundational` 排除，並由 `detect-foundational-changes` job 印 warning 而非 fail。
