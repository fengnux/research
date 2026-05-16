# Workload Identity Federation：GitHub Actions 登入 GCP

本文件說明 `tofu-terramate-lab` 在 CI 中使用的 GCP 認證方式：GitHub Actions 透過 OIDC token 與 GCP Workload Identity Federation（WIF）換取短效憑證，再 impersonate 一個專用 service account 執行 OpenTofu。

---

## 為什麼不用 Service Account Key

傳統做法會建立 service account JSON key，放進 GitHub Secrets。這把 key 是長期憑證，只要外洩，任何拿到 key 的人都能以該 service account 身份登入 GCP，直到 key 被刪除或停用。

WIF 不需要 JSON key。每次 GitHub Actions workflow 執行時，才臨時向 GitHub 取得 OIDC token，並向 GCP 換短效憑證。憑證有效時間短，而且 GCP 可以檢查 token 內的 repo、branch、workflow 等 claims，決定是否允許登入。

---

## 本 repo 的身份模型

```
GitHub Actions workflow
        │
        │ 1. 取得 GitHub OIDC token
        ▼
GitHub OIDC issuer
https://token.actions.githubusercontent.com
        │
        │ 2. GCP 驗證 token issuer、audience、attribute condition
        ▼
GCP Workload Identity Provider
projects/1074394836652/locations/global/workloadIdentityPools/github-actions/providers/github
        │
        │ 3. 符合條件的 principalSet 可 impersonate service account
        ▼
Service Account
github-actions-tofu@research-lab-495809.iam.gserviceaccount.com
        │
        │ 4. OpenTofu 使用短效 GCP credentials
        ▼
GCP resources / GCS remote state
```

本 lab 限制只有 `fengnux/tofu-terramate-lab` 這個 GitHub repo 可以進入 WIF provider：

```hcl
attribute_condition = "assertion.repository == 'fengnux/tofu-terramate-lab'"
```

service account 的 impersonation 權限也限制在同一個 repository attribute：

```hcl
member = "principalSet://iam.googleapis.com/<pool-name>/attribute.repository/fengnux/tofu-terramate-lab"
```

---

## GitHub Actions 端需要什麼

Workflow 必須開啟 OIDC token 權限：

```yaml
permissions:
  contents: read
  id-token: write
  pull-requests: read
```

然後使用 `google-github-actions/auth`：

```yaml
- uses: google-github-actions/auth@v3
  with:
    project_id: research-lab-495809
    workload_identity_provider: projects/1074394836652/locations/global/workloadIdentityPools/github-actions/providers/github
    service_account: github-actions-tofu@research-lab-495809.iam.gserviceaccount.com
```

`id-token: write` 不是給 workflow 修改 GitHub token；它是允許 workflow 向 GitHub OIDC issuer 要一張短效 OIDC token。`auth` action 會拿這張 token 去 GCP STS 交換 Google credentials。

---

## GCP 端如何判斷是否可信

GCP Workload Identity Provider 會做三層檢查：

1. **Issuer**：token 必須來自 `https://token.actions.githubusercontent.com`
2. **Attribute mapping**：把 GitHub token claims 映射成 GCP attribute，例如 `attribute.repository`
3. **Attribute condition**：只接受 `assertion.repository == "fengnux/tofu-terramate-lab"`

通過 provider 檢查後，還要通過 service account IAM binding：

```text
roles/iam.workloadIdentityUser
principalSet://iam.googleapis.com/.../attribute.repository/fengnux/tofu-terramate-lab
```

兩邊都通過，GitHub Actions 才能 impersonate `github-actions-tofu`。

---

## 權限與責任邊界

`github-actions-tofu` 是 OpenTofu CI/CD 專用身份。Lab 04 為了讓 PR plan 與 main apply 能完整操作目前實驗資源，先給它下列 project-level roles：

| Role | 用途 |
|------|------|
| `roles/storage.objectAdmin` | 讀寫 GCS remote state |
| `roles/serviceusage.serviceUsageAdmin` | 管理 project API 啟用 |
| `roles/compute.networkAdmin` | 管理 VPC、subnet、router、NAT |
| `roles/compute.securityAdmin` | 管理 firewall rules |
| `roles/compute.instanceAdmin.v1` | 管理 lab VM |
| `roles/iap.tunnelResourceAccessor` | IAP 相關驗證 |
| `roles/iam.serviceAccountTokenCreator` | lab 階段保留給 CI token minting / impersonation 需求 |

正式環境應拆成 plan/apply 兩個 service account，並將 role 收斂到最小權限。

---

## 為什麼 WIF stack 不讓 CI 自動 apply

`stacks/ci/github-actions-wif` 管的是 CI 自己的信任邊界：OIDC provider、attribute condition、service account、IAM binding。

如果讓 CI 自動修改這個 stack，就等於讓 CI 可以修改「誰可以成為 CI」。Lab 04 的 workflow 因此會在 `main` push 偵測到 WIF stack 變更時停止，要求從可信任的本機 ADC session 手動 apply：

```bash
terramate run --tags wif -- tofu init
terramate run --tags wif -- tofu plan
terramate run --tags wif -- tofu apply
```

---

## 常見問題

### `tofu init` 為什麼也需要 GCP credentials

本 repo 每個 stack 都使用 GCS backend。`tofu init` 會初始化 backend、讀取 state bucket、下載 provider。只要 backend 是 GCS，CI 在 init 階段就需要可用的 GCP credentials。

### WIF 設定後馬上失敗

Workload Identity Pool、Provider、IAM binding 可能需要幾分鐘傳播。第一次 apply 後若 GitHub Actions 立刻失敗，先等 5 分鐘再重跑 workflow。

### 可以限制 main 才能 apply 嗎

可以。Lab 04 已透過 GitHub Actions event 分流：

- `pull_request`：只 plan
- `push` 到 `main`：才 apply

更正式的做法是加 GitHub Environment protection rules，讓 `apply` job 需要人工 approval。
