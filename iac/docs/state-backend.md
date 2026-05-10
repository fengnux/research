# State Backend 設計

OpenTofu state 採 **單一 GCS bucket + 路徑區隔環境** 的設計（方案 A）。
此文件記錄為何這樣選、bucket 安全基線、bootstrap chicken-and-egg 解法、與 state 路徑慣例。

---

## 設計選擇

研究專案目前所有環境（dev、未來可能的 staging）共用同一個 `research-lab-495809` GCP project，
state 也共用一個 bucket：

```
gs://research-lab-495809-tofu-state/
├── dev/<stack-id>/default.tfstate
├── staging/<stack-id>/default.tfstate
└── bootstrap/default.tfstate            # 視 Lab 03 是否遷移
```

**Bucket 跟著 project 命名**，環境靠 `prefix` 區隔。

> 若日後要做 production-grade 隔離，正規做法是另開 GCP project（方案 C），
> 在新 project 內 bootstrap 自己的 bucket，**不會**修改本 bucket。

### 為什麼不每個環境一個 bucket（方案 B）

- 隔離強度落在 IAM/lifecycle policy，但仍同 project，幫助有限
- 維運多一倍（每環境都要 bootstrap）
- 想要更強隔離直接走方案 C 比較划算

---

## Bucket 安全基線

| 設定 | 值 | 用意 |
|------|------|------|
| `lifecycle { prevent_destroy = true }` | 開 | OpenTofu 拒絕刪除動作，避免誤砍 |
| `versioning.enabled` | true | state 修改可追溯，覆寫不會永久遺失 |
| `soft_delete_policy.retention_duration_seconds` | 7,776,000（90 天） | 誤刪 object 90 天內可救回 |
| `lifecycle_rule { num_newer_versions = 10, Delete }` | 開 | 自動清舊版本，避免帳單膨脹 |
| `uniform_bucket_level_access` | true | 統一 IAM，禁止舊式 ACL |
| `public_access_prevention` | `enforced` | 禁止任何公開存取設定 |
| Default labels | `managed-by`、`source-repo`、`purpose=tofu-state` | 帳務追蹤、找出不合規資源 |

---

## Bootstrap Chicken-and-Egg

**問題**：state bucket 自己也要被 OpenTofu 管理，但第一次 apply 時 bucket 還不存在，無法當 backend。

**解法**：
1. Bootstrap stack 用 **local state** apply 出 bucket
2. （Lab 03）把 bootstrap stack 的 state 用 `tofu init -migrate-state` 遷到剛建好的 bucket
3. 之後每個新 stack 都直接用 GCS backend，不再有 local state

> Bootstrap 的 local state 在遷移前**只在本機**，需注意備份。

---

## State 路徑慣例（方案 A 的核心）

採 **巢狀 stack** 結構，stack 目錄階層直接決定 GCS prefix。
在 `generate_hcl` 內用 `terramate.stack.path` 自動推導，不需手寫 stack id。

```hcl
# generate.tm.hcl（示意，Lab 03 才實作）
generate_hcl "_terramate_backend.tf" {
  condition = tm_try(global.env.name, "") != ""   # 只對有 env 的 stack 產 backend；bootstrap 跳過
  content {
    terraform {
      backend "gcs" {
        bucket = global.gcp.state_bucket
        # terramate.stack.path 例：/stacks/dev/network → 去掉 /stacks/ 前綴後 = dev/network
        prefix = tm_replace(terramate.stack.path, "/stacks/", "")
      }
    }
  }
}
```

最後路徑長相：

| Stack 目錄 | stack.name | GCS prefix |
|-----------|-----------|-----------|
| `stacks/bootstrap/` | `bootstrap` | （local state，不適用） |
| `stacks/dev/network/` | `network` | `dev/network/` |
| `stacks/dev/gke/` | `gke` | `dev/gke/` |
| `stacks/staging/network/` | `network` | `staging/network/` |

**規則：**

- 環境靠 stack 目錄第一層（`dev/`、`staging/`）區分；`globals "env" { name = ... }` 寫在 env 層的 `globals.tm.hcl`
- `stack.name`（與目錄末段同名）即可表達用途，不需 `<env>-<purpose>` 前綴
- 巢狀 stack 預設依目錄階層執行（parent 先 child 後），通常不必手寫 `after` 表達依賴

### Bootstrap 例外

Bootstrap stack 跨環境，不屬於任何 env：

- 不在 env 目錄底下（直接放 `stacks/bootstrap/`）
- 沒有 `global.env.name`，所以 `generate_hcl` 的 backend 區塊跳過它（保留 local state，或 Lab 03 用獨立 prefix `bootstrap/` 遷移到 GCS）
- Provider `default_labels` 中 `environment` 欄位用 `tm_try(global.env.name, "shared")` fallback 為 `shared`

---

## 復原情境

| 場景 | 動作 |
|------|------|
| State 檔被覆寫成壞值 | Bucket versioning 取舊版（`gsutil ls -a`）覆蓋回來 |
| State 物件被刪 | 90 天內 soft delete 救回（`gcloud storage objects restore`） |
| Bucket 被刪 | `prevent_destroy` 已擋住此情境；若仍發生，只能重建 bucket + 從備份還原 state |
| Lock 卡住（罕見） | GCS backend 的 lock object 可手動刪（`<prefix>/default.tflock`） |
