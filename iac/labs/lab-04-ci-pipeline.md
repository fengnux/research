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
| `pull_request` | generate diff check、fmt check、**changed stacks（不含 WIF）** init/validate/plan + WIF 變更警示 |
| `push` to `main` | **changed stacks（不含 WIF）** init/apply + WIF 變更警示 |

PR 只做預覽，不改 GCP。合併到 `main` 後才由 CI apply。WIF stack 由 CI 完全跳過（見 [Workload Identity Federation：為什麼 WIF stack 不讓 CI 自動 apply](../docs/workload-identity-federation.md#為什麼-wif-stack-不讓-ci-自動-apply)）。

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
| `detect-wif-changes` | PR 與 `push` 都跑 | 用 `terramate list --changed --tags wif` 偵測 WIF stack 變更；有變更時印 warning 並提示「需本機 apply」，**不 fail CI** |
| `generate-check` | PR 與 `push` 都跑 | `terramate generate && git diff --exit-code`，確保 generated files 與 source 同步 |
| `plan` | 僅 `pull_request` | `terramate run --changed --no-tags wif -- tofu init/validate/plan` |
| `apply` | 僅 `push` to `main` | `terramate run --changed --git-change-base="${{ github.event.before }}" --no-tags wif -- tofu init/apply` |

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
- `terramate run --changed -- tofu fmt -check` 成功
- `terramate run --changed -- tofu validate` 成功
- `terramate run --changed -- tofu plan` 成功
- 沒有執行 apply

### 7. Merge 後驗證 apply

PR merge 到 `main` 後，`push` workflow 會執行：

```bash
terramate run --changed --git-change-base="$PUSH_CHANGE_BASE" --include-all-dependencies --no-tags wif -- tofu init -input=false
terramate run --changed --git-change-base="$PUSH_CHANGE_BASE" --no-tags wif -- tofu apply -input=false -auto-approve -lock-timeout=5m
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
- [ ] 修改 WIF stack 時，CI 印出 warning 但不 fail，並提示需本機 apply
- [ ] GitHub repo 沒有儲存任何 service account JSON key

---

## 風險與回退

- **WIF 立即失敗**：等待 5 分鐘再重跑 workflow，IAM/WIF 傳播需要時間。
- **`tofu init` 無法讀 GCS backend**：確認 `github-actions-tofu` 有 `roles/storage.objectAdmin`。
- **`terramate list --changed` 在 main 為空**：這是 git base 行為；PR workflow 最符合 changed stacks 模型。直接在 main 開發時，必要時用 `--git-change-base=HEAD~1` 做實驗。
- **WIF stack 需要修改**：從本機 ADC 執行 `terramate run --tags wif -- tofu apply`，不要讓 CI 自行修改。
- **PR plan 不嘗試 plan WIF stack**：CI service account 沒有 WIF resources 的 viewer 權限，若 PR 觸發 WIF stack 的 plan 會失敗。改以 `--no-tags wif` 跳過 + `detect-wif-changes` job 提示變更，讓審查者改走本機 apply 流程。

---

## 下一步

- 將 apply job 綁定 GitHub Environment，加上人工 approval
- 拆分 plan/apply service account，縮小 PR workflow 權限
- 將 plan 結果回寫 PR comment
