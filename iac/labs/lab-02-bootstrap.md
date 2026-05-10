# Lab 02 - Bootstrap：建立 GCS State Bucket

## 目標

使用 OpenTofu 在實驗 project 建立 GCS bucket，作為後續所有 stack 的 remote state backend。
Bootstrap stack 本身使用 **local state**（雞生蛋問題：建 backend 的 stack 還沒有 backend 可用）。

## 前置條件

- 完成 [Lab 01 - 環境準備](lab-01-environment-setup.md)
- GCP project `research-lab-495809` 已建立並綁定 billing account
- 個人帳號 ADC 已設定（`gcloud auth application-default login`）

---

## 環境

| 項目 | 值 |
|------|----|
| GCP Project ID | `research-lab-495809` |
| Region | `asia-east1` |
| State Bucket | `research-lab-495809-tofu-state` |
| 設定檔 Repo | [fengnux/tofu-terramate-hcl](https://github.com/fengnux/tofu-terramate-hcl) |

---

## 步驟

### 1. 啟用所需的 GCP API

```bash
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com \
  --project=research-lab-495809
```

驗證：

```bash
gcloud services list --enabled --project=research-lab-495809 \
  --filter="config.name:(cloudresourcemanager OR storage)" \
  --format="table(config.name)"
```

### 2. Clone 設定檔 repo

```bash
cd ~/GitHub
git clone https://github.com/fengnux/tofu-terramate-hcl.git
cd tofu-terramate-hcl
```

目錄結構：

```
tofu-terramate-hcl/
├── terramate.tm.hcl        # Terramate root config
├── config.tm.hcl           # 共用 globals (gcp / tofu / labels)
├── generate.tm.hcl         # generate_hcl 規則：產生 versions / provider
└── stacks/
    └── bootstrap/
        ├── stack.tm.hcl    # Terramate stack 定義
        ├── main.tf         # GCS bucket 資源
        └── outputs.tf      # bucket 名稱與 URL
```

### 3. 產生 Terramate 自動生成檔

```bash
terramate generate
```

會在 `stacks/bootstrap/` 產生：

- `_terramate_versions.tf` — `terraform { required_version, required_providers }`
- `_terramate_provider.tf` — `provider "google" { project, region, default_labels }`

> 生成檔會 commit 進 repo，但開頭有 `// TERRAMATE: GENERATED AUTOMATICALLY DO NOT EDIT`，請勿手改。

### 4. 列出 stack

```bash
terramate list
```

預期輸出：

```
stacks/bootstrap
```

### 5. 透過 Terramate 執行 OpenTofu

```bash
# 初始化（local state）
terramate run --tags bootstrap -- tofu init

# 預覽變更
terramate run --tags bootstrap -- tofu plan

# 套用
terramate run --tags bootstrap -- tofu apply
```

`terramate run` 的好處：

- 自動 `cd` 到每個符合條件的 stack 目錄執行命令
- 後續可改用 `--changed` 只跑有變動的 stack（CI 友善）
- 統一介面，不必記每個 stack 的路徑

### 6. 驗證

```bash
gcloud storage buckets describe gs://research-lab-495809-tofu-state \
  --format="yaml(name,location,versioning,labels,iamConfiguration.publicAccessPrevention,softDeletePolicy)"
```

確認：

- Bucket 存在
- `location: ASIA-EAST1`
- `versioning.enabled: true`
- `iamConfiguration.publicAccessPrevention: enforced`
- Labels 包含 `managed-by: opentofu`、`purpose: tofu-state`
- Soft delete 保留 90 天

---

## 驗證清單

- [ ] `terramate generate` 無錯誤
- [ ] `terramate list` 顯示 `stacks/bootstrap`
- [ ] `terramate run -- tofu apply` 執行成功
- [ ] GCS bucket `research-lab-495809-tofu-state` 存在於 `research-lab-495809`
- [ ] Bucket 位於 `asia-east1`、versioning 啟用、`prevent_destroy` 生效
- [ ] Default labels 正確套用

---

## 設計重點

### 為什麼 bootstrap 用 local state

- 要建立的 GCS bucket 本身就是其他 stack 的 state backend
- 第一次執行時 bucket 還不存在，無法把 state 放進去
- 解法：bootstrap stack 用 local state，apply 後產生的 `terraform.tfstate` commit 進設定檔 repo（或保存於安全位置）

### `prevent_destroy = true`

State bucket 是關鍵基礎設施，誤刪會導致所有環境的 state 遺失。
設定 `lifecycle { prevent_destroy = true }` 後，任何 `tofu destroy` 或刪除動作會被 OpenTofu 主動拒絕。

### Soft delete + Versioning

- Versioning 防止覆寫遺失（state 修改歷史可追溯）
- Soft delete 90 天可救回誤刪的 object
- Lifecycle rule 自動清理超過 10 個版本，避免帳單膨脹

---

## 下一步

[Lab 03 - 將 bootstrap state 遷移至 GCS、建立第一個 dev stack](lab-03-first-stack.md)
