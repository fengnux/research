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

## Credentials 注入流程（端到端）

整個流程是 **OIDC token → STS 交換 → ADC 環境變數**，跨 GitHub 與 GCP 兩端共四階段：

```
┌─────────────────────── GitHub Actions Runner ────────────────────┐
│                                                                  │
│  ① workflow 宣告 permissions: id-token: write                     │
│     → 允許這個 job 向 GitHub OIDC issuer 索取一張 token           │
│                                                                  │
│  ② google-github-actions/auth@v3 步驟執行：                       │
│                                                                  │
│     a. 向 https://token.actions.githubusercontent.com            │
│        要一張 OIDC token（JWT）                                   │
│        claims: { repository: "fengnux/tofu-terramate-lab",       │
│                  actor: ..., ref: ..., workflow: ... }            │
│                                                                  │
│     b. 拿這張 JWT 打 GCP STS:                                     │
│        POST https://sts.googleapis.com/v1/token                  │
│        body: { audience: <WIF provider name>,                    │
│                subject_token: <github_jwt> }                      │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────── GCP ──────────────────────────────────┐
│                                                                  │
│  ③ STS 拿 audience 找到對應的 WIF provider，驗證：                 │
│     - issuer == https://token.actions.githubusercontent.com      │
│     - attribute_condition == "assertion.repository ==            │
│         'fengnux/tofu-terramate-lab'"                            │
│     通過後回傳一張短效 federated access token                     │
│                                                                  │
│  ④ auth 再用 federated token 向 IAM Credentials API 要：           │
│     POST iamcredentials.googleapis.com/.../serviceAccounts/      │
│       github-actions-tofu@.../:generateAccessToken               │
│                                                                  │
│     IAM 檢查 SA 上有沒有這條 binding：                              │
│       roles/iam.workloadIdentityUser                             │
│       member = principalSet://.../attribute.repository/          │
│                fengnux/tofu-terramate-lab                        │
│     有 → 回傳 SA 的短效 access token（預設 1 小時）                │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼
┌─────────────────────── 回到 Runner ──────────────────────────────┐
│                                                                  │
│  ⑤ auth action 把 token 寫到檔案：                                │
│     $GITHUB_WORKSPACE/gha-creds-<hash>.json                      │
│                                                                  │
│  ⑥ 並設定以下環境變數讓後續 step 透過 ADC 自動撿到：               │
│     GOOGLE_APPLICATION_CREDENTIALS = <path>                      │
│     CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE = <path>              │
│     GOOGLE_GHA_CREDS_PATH = <path>                               │
│     CLOUDSDK_CORE_PROJECT / GOOGLE_CLOUD_PROJECT / ...           │
│                                                                  │
│  ⑦ 接下來的 step 跑 tofu init / plan / apply：                     │
│     google provider 走 ADC chain → 撿到                          │
│     GOOGLE_APPLICATION_CREDENTIALS → 用 SA access token          │
│     打 GCP API                                                   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**關鍵特性：**

- Token 短效：GitHub OIDC 5 分鐘、SA access token 預設 1 小時
- 沒有任何 secret 從 GitHub secrets 注入，全靠 OIDC trust chain
- `gha-creds-*.json` 只存活在 runner 的暫存環境，job 結束就消失（仍需放進 `.gitignore` 防止意外 commit）

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

## WIF stack 資源拓撲

`stacks/ci/github-actions-wif/main.tf` 共建立 15 個資源，分四層：API 啟用 → 信任入口 → SA 身份 → 權限授予。

```
┌─────────────────────────────────────────────────────────────────┐
│                       Layer 0：API 啟用                          │
│                                                                 │
│   google_project_service.required (for_each = 4 個 API)         │
│   ├─ cloudresourcemanager.googleapis.com                        │
│   ├─ iam.googleapis.com  ←─┐                                    │
│   ├─ iamcredentials.googleapis.com                              │
│   └─ sts.googleapis.com                                         │
│                            │                                    │
│                            │ depends_on                         │
│         ┌──────────────────┴────────────────┐                   │
│         ▼                                   ▼                   │
└─────────│───────────────────────────────────│───────────────────┘
          │                                   │
┌─────────┼──────── Layer 1：信任入口 ────────┼───────────────────┐
│         │                                   │                   │
│   google_iam_workload_identity_pool         │                   │
│   .github_actions                           │                   │
│   ├─ pool_id = "github-actions"             │                   │
│   └─ name = projects/<num>/.../pools/       │                   │
│            github-actions                   │                   │
│         │                                   │                   │
│         │ workload_identity_pool_id         │                   │
│         ▼                                   │                   │
│   google_iam_workload_identity_pool_        │                   │
│   provider.github                           │                   │
│   ├─ provider_id = "github"                 │                   │
│   ├─ issuer_uri = token.actions.github...   │                   │
│   ├─ attribute_mapping (sub/actor/repo/...) │                   │
│   └─ attribute_condition =                  │                   │
│      "assertion.repository ==               │                   │
│       'fengnux/tofu-terramate-lab'"         │                   │
│                                             │                   │
└─────────────────────────────────────────────┼───────────────────┘
                                              │
┌─────────────────────────────────────────────┼───────────────────┐
│                Layer 2：SA 身份             │                   │
│                                             ▼                   │
│   google_service_account.github_actions_tofu                    │
│   ├─ account_id = "github-actions-tofu"                         │
│   ├─ email = github-actions-tofu@...iam.gserviceaccount.com     │
│   └─ name = projects/.../serviceAccounts/github-actions-tofu    │
│         │                                                       │
│         └─────────────┬──────────────────┐                      │
└───────────────────────│──────────────────│──────────────────────┘
                        │                  │
┌───────────────────────│──── Layer 3：權限授予 ──────────────────┐
│                       ▼                  ▼                      │
│   google_service_account_iam_member      google_project_iam_   │
│   .github_actions_wif                    member.github_actions  │
│                                          _tofu                  │
│   service_account_id = <SA.name>         (for_each = 7 個 role) │
│   role = roles/iam.                      ├─ storage.objectAdmin │
│          workloadIdentityUser            ├─ serviceusage.       │
│   member = principalSet://...            │  serviceUsageAdmin   │
│            /<pool.name>/attribute.       ├─ compute.            │
│            repository/                   │  networkAdmin        │
│            fengnux/tofu-terramate-lab    ├─ compute.            │
│                                          │  securityAdmin       │
│   ↑ 這條 binding 回答的問題：             ├─ compute.            │
│   「來自 GitHub repo fengnux/...的        │  instanceAdmin.v1    │
│    OIDC 身份，可以扮演這個 SA 嗎？」      ├─ iap.tunnelResource  │
│                                          │  Accessor            │
│                                          └─ iam.serviceAccount  │
│                                             TokenCreator        │
│                                                                 │
│                                          ↑ 這些 binding 回答的：│
│                                          「SA 拿到 token 後在    │
│                                           project 內可以做什麼？│
└─────────────────────────────────────────────────────────────────┘
```

### 三個 IAM binding 的意義差異（最容易混淆的地方）

| Binding | 在誰身上 | 角色 | 對象 | 回答的問題 |
|---------|---------|------|------|-----------|
| `google_service_account_iam_member.github_actions_wif` | SA 物件 | `roles/iam.workloadIdentityUser` | `principalSet://.../attribute.repository/fengnux/tofu-terramate-lab` | **誰可以變成這個 SA**（impersonation 入口） |
| `google_project_iam_member.github_actions_tofu` (×7) | Project | 各種 admin role | `serviceAccount:github-actions-tofu@...` | **這個 SA 在 project 內可以做什麼** |
| Provider 內的 `attribute_condition` | WIF provider | n/a | n/a | **誰的 OIDC token 可以進入 WIF**（更前面的閘門） |

### 兩道閘門 + 一道權限

對應到 [Credentials 注入流程](#credentials-注入流程端到端)：

1. **第一道閘門**：provider 的 `attribute_condition` —— 別的 repo 的 OIDC token 連 federated token 都拿不到
2. **第二道閘門**：SA 上的 `workloadIdentityUser` binding —— 即使通過了 provider，沒這條 binding 也不能扮演 SA
3. **拿到 SA token 後的權限範圍**：project IAM 的 7 條 binding

兩道閘門都鎖同一個 `attribute.repository`，是刻意的**雙重保險**：即使未來不小心新增一個寬鬆的 provider attribute condition，SA binding 那層仍會擋住其他 repo。

### `depends_on` 為什麼只寫在兩個地方

`main.tf` 只在 `pool` 和 `SA` 兩處顯式宣告 `depends_on = [google_project_service.required["iam.googleapis.com"]]`。其他資源的依賴是 OpenTofu 從 reference 自動推導的：

- `provider.github` 引用 `pool.workload_identity_pool_id` → 自動排在 pool 後
- `service_account_iam_member` 引用 `pool.name` + `sa.name` → 自動排在兩者後
- `project_iam_member` 引用 `sa.member` → 自動排在 SA 後

只有 API 啟用是 implicit（resource 不直接 reference `google_project_service`），所以才需要手動寫 `depends_on`。

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
