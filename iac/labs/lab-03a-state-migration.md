# Lab 03a - 將 bootstrap state 遷移至 GCS

## 目標

把 [Lab 02](lab-02-bootstrap.md) 建立的 bootstrap stack 從 **local state** 遷到 **GCS backend**（同一顆 bucket），並把「自動生成 backend 設定」的機制加進 Terramate root config，讓後續所有 stack 都能套用同一份 state 路徑慣例。

## 前置條件

- 完成 [Lab 02 - Bootstrap](lab-02-bootstrap.md)
- `gs://research-lab-495809-tofu-state` 已 apply 並啟用 versioning + soft delete
- `stacks/bootstrap/terraform.tfstate` 仍為 local（雞生蛋階段的產物）

---

## 設計重點

### State 路徑慣例

GCS prefix 由 stack path 自動推導：

```hcl
prefix = tm_trimprefix(terramate.stack.path.absolute, "/stacks/")
```

| Stack | path.absolute | GCS prefix | 完整物件 |
|-------|---------------|------------|----------|
| `stacks/bootstrap` | `/stacks/bootstrap` | `bootstrap` | `gs://<bucket>/bootstrap/default.tfstate` |
| `stacks/dev/network` | `/stacks/dev/network` | `dev/network` | `gs://<bucket>/dev/network/default.tfstate` |

> 「env」不是 Terramate 概念，只是 stack path 中的一層目錄。巢狀更深時 prefix 自然延伸（如 `dev/network/peering`）。

### 為什麼 bootstrap 也搬到同一顆 bucket

雞生蛋只在「建 bucket 的當下」成立。bucket 一旦存在，bootstrap 自己的 state 沒理由不放進去——同一顆 bucket 的安全基線（versioning / soft delete / prevent_destroy）也保護它。為避免命名混淆，bootstrap 不放在任何 env 目錄下，prefix 直接為 `bootstrap`。

---

## 步驟

### 1. 在 root 加入 backend 生成規則

編輯 [tofu-terramate-lab/generate.tm.hcl](https://github.com/fengnux/tofu-terramate-lab/blob/main/generate.tm.hcl)，新增一個 `generate_hcl` block：

```hcl
generate_hcl "_terramate_backend.tf" {
  content {
    terraform {
      backend "gcs" {
        bucket = global.gcp.state_bucket
        prefix = tm_trimprefix(terramate.stack.path.absolute, "/stacks/")
      }
    }
  }
}
```

順便把 `stacks/bootstrap/stack.tm.hcl` 裡關於「不繼承 root backend」的舊註解移除——現在它要繼承了。

### 2. 產生新的 backend 檔

```bash
cd ~/GitHub/tofu-terramate-lab
terramate generate
```

預期：`stacks/bootstrap/_terramate_backend.tf` 新增，內容：

```hcl
// TERRAMATE: GENERATED AUTOMATICALLY DO NOT EDIT
terraform {
  backend "gcs" {
    bucket = "research-lab-495809-tofu-state"
    prefix = "bootstrap"
  }
}
```

### 3. 備份本地 state（保險）

```bash
cp stacks/bootstrap/terraform.tfstate stacks/bootstrap/terraform.tfstate.lab03a-backup
```

### 4. 先 commit 設定變更

Terramate 預設拒絕在 repo 有未提交/未追蹤檔案時 `terramate run`，避免「執行了但設定沒紀錄」。
所以順序是「先 commit 設定 → 再做 state 遷移」，而非反過來。

```bash
git add generate.tm.hcl stacks/bootstrap/_terramate_backend.tf stacks/bootstrap/stack.tm.hcl
git commit -m "feat: 加入 backend 自動生成、bootstrap 改用 GCS state"
git push
```

> 注意：這個 commit 之後、migrate 之前，`_terramate_backend.tf` 指向 GCS 但 state 仍在 local。
> 單人操作沒影響；多人協作時 migrate 完再次 push 會更安全。

### 5. 執行 state 遷移

維持 Lab 02 的慣例：所有 `tofu` 指令都透過 `terramate run` 呼叫，不要直接 `cd` 進 stack。
這樣未來 stack 變多時可用 `--tags` / `--changed` 篩選，介面統一。

```bash
terramate run --tags bootstrap -- tofu init -migrate-state -force-copy
```

- `-migrate-state`：偵測到 backend 從 local 變 gcs 時，把現有 state 複製過去
- `-force-copy`：跳過互動式 yes/no 確認（已自行備份，可安全跳過）

預期輸出片段：

```
Initializing the backend...
Terraform detected that the backend type changed from "local" to "gcs".
Copying configuration from "local" to "gcs"...
Successfully configured the backend "gcs"!
```

### 6. 驗證 state 已在 GCS

```bash
gcloud storage ls gs://research-lab-495809-tofu-state/bootstrap/
```

預期看到 `default.tfstate`。

再跑一次 plan 確認沒有飄移：

```bash
terramate run --tags bootstrap -- tofu plan
```

預期：`No changes. Your infrastructure matches the configuration.`

### 7. 清掉本地 state

確認 GCS state 可用後，刪掉本地檔案（避免之後 init 時被當成衝突來源）：

```bash
rm stacks/bootstrap/terraform.tfstate \
   stacks/bootstrap/terraform.tfstate.backup \
   stacks/bootstrap/terraform.tfstate.lab03a-backup
```

`.gitignore` 已排除 `*.tfstate*`，git status 不會看到變化。

---

## 驗證清單

- [ ] `terramate generate` 在 `stacks/bootstrap/` 產生 `_terramate_backend.tf`
- [ ] `tofu init -migrate-state` 完成，無錯誤
- [ ] `gs://research-lab-495809-tofu-state/bootstrap/default.tfstate` 存在
- [ ] `tofu plan` 顯示 no changes
- [ ] 本地 `terraform.tfstate*` 已刪除
- [ ] Commit 推上 GitHub

---

## 風險與回退

- **遷移失敗時**：保留 `terraform.tfstate.lab03a-backup`，可隨時還原本地檔並把 backend block 從 generated 檔案中拿掉重新 init。
- **State 上傳後 plan 出現 drift**：先檢查 prefix 是否與預期一致；不要直接 apply。
- **Bucket 權限不足**：個人 ADC 帳號需要 `roles/storage.objectAdmin`（或更高）對該 bucket 有權限。

---

## 下一步

[Lab 03b - 建立第一個 dev stack](lab-03b-first-dev-stack.md)
