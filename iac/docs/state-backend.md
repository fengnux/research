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
| Default labels | 見下節 | 帳務追蹤、找出不合規資源 |

### Resource labeling 策略

所有 GCP 資源透過 provider `default_labels` 自動帶上四個 label，不必在每個 resource 重複：

| Label | 來源 | 用途 |
|-------|------|------|
| `managed-by` | `global.labels.managed_by` = `opentofu` | 區分人為手動 vs IaC 管理 |
| `source-repo` | `global.labels.source_repo` = `tofu-terramate-hcl` | 找出資源由哪個 repo 控制 |
| `stack` | `terramate.stack.name`（自動） | 帳單 / log 按 stack 細分 |
| `environment` | `global.env.name`（缺值時 fallback `shared`） | 跨環境 filter |

Resource 自身可加 stack-specific label（例如 bootstrap bucket 自帶 `purpose = "tofu-state"`），會與 `default_labels` merge。Provider 自動加的 `goog-terraform-provisioned = "true"` 也會出現，無需額外設定。

---

## Bootstrap Chicken-and-Egg

**問題**：state bucket 自己也要被 OpenTofu 管理，但第一次 apply 時 bucket 還不存在，無法當 backend。

**解法**：
1. Bootstrap stack 用 **local state** apply 出 bucket（Lab 02）
2. Bucket 建好後，用 `tofu init -migrate-state` 把 bootstrap state 遷到該 bucket（Lab 03a 已完成）
3. 之後每個新 stack 都直接用 GCS backend，不再有 local state

> Bootstrap 的 local state 在遷移前**只在本機**，需注意備份。

---

## State 路徑慣例（方案 A 的核心）

採 **巢狀 stack** 結構，stack 目錄階層直接決定 GCS prefix。
在 `generate_hcl` 內用 `terramate.stack.path.absolute` 自動推導，不需手寫 stack id。

```hcl
# generate.tm.hcl（Lab 03a 實作）
generate_hcl "_terramate_backend.tf" {
  content {
    terraform {
      backend "gcs" {
        bucket = global.gcp.state_bucket
        # path.absolute 例：/stacks/dev/network → 去掉 /stacks/ 前綴後 = dev/network
        prefix = tm_trimprefix(terramate.stack.path.absolute, "/stacks/")
      }
    }
  }
}
```

> ⚠️ **不要用 `tm_replace(path, "/stacks/", "")`**：第二個參數若被 `/.../` 包住會被當成 regex pattern，
> 實際 match 到的是單字 `stacks`，會生出 `//bootstrap` 這種多斜線結果（Lab 03a 踩過）。
> `tm_trimprefix` 語意明確、不走 regex。

最後路徑長相：

| Stack 目錄 | stack.name | GCS prefix |
|-----------|-----------|-----------|
| `stacks/bootstrap/` | `bootstrap` | `bootstrap/` |
| `stacks/dev/network/` | `network` | `dev/network/` |
| `stacks/dev/gke/` | `gke` | `dev/gke/` |
| `stacks/staging/network/` | `network` | `staging/network/` |

**規則：**

- 環境靠 stack 目錄第一層（`dev/`、`staging/`）區分；`globals "env" { name = ... }` 寫在 env 層的 `globals.tm.hcl`
- `stack.name`（與目錄末段同名）即可表達用途，不需 `<env>-<purpose>` 前綴
- 巢狀 stack 預設依目錄階層執行（parent 先 child 後），通常不必手寫 `after` 表達依賴

### Bootstrap 例外

Bootstrap stack 跨環境，不屬於任何 env：

- 不在 env 目錄底下（直接放 `stacks/bootstrap/`），所以 `tm_trimprefix` 算出來的 prefix 直接是 `bootstrap`
- 沒有 `global.env.name`；Provider `default_labels` 中 `environment` 欄位用 `tm_try(global.env.name, "shared")` fallback 為 `shared`
- State 與其他 stack 共用同一顆 bucket（受同一份 versioning / soft delete / `prevent_destroy` 保護）

---

## 復原情境

| 場景 | 機制 | 視窗 |
|------|------|------|
| State 檔被覆寫成壞值 | Bucket versioning 取舊版蓋回 | 受 lifecycle `num_newer_versions = 10` 限制，最多保留 10 個舊版 |
| State 物件被刪 | Soft delete 救回 | 90 天 |
| Bucket 被刪 | `prevent_destroy` 已擋住一般情境；若仍發生需重建 + 還原 | — |
| Lock 卡住（罕見） | 手動刪 GCS backend lock object（`<prefix>/default.tflock`） | — |

### Object 救回操作

> ⚠️ **救回前先做兩件事**：
> 1. **停手**：state 異常時不要再跑 `tofu apply`，會把壞狀態固化
> 2. **備份現況**：先把目前的（壞的）state 拷一份到本機，免得救錯版本還想回頭看
>     ```bash
>     gcloud storage cp gs://<bucket>/<prefix>/default.tfstate ./broken.tfstate.bak
>     ```
> 救回後一律以 `tofu plan` 驗證（預期看到空 plan 或符合心中模型的 diff），才繼續操作。

**情境 A：Object 被覆寫成壞值（用 versioning 回滾）**

Versioning 保存「被覆寫」前的舊版本，物件本身仍存在。

```bash
# 列出所有版本（含舊版），會看到多筆 GENERATION 號
gcloud storage ls --all-versions \
  gs://research-lab-495809-tofu-state/bootstrap/default.tfstate

# 複製特定 generation 蓋回最新版（GENERATION 是純數字）
gcloud storage cp \
  gs://research-lab-495809-tofu-state/bootstrap/default.tfstate#<GENERATION> \
  gs://research-lab-495809-tofu-state/bootstrap/default.tfstate
```

**情境 B：Object 被刪除（用 soft delete 救回，90 天內）**

Soft delete 保存「被刪除」的物件，與 versioning 是兩套獨立機制——列舉指令不同。

```bash
# 列出 soft-deleted 物件
gcloud storage ls --soft-deleted \
  gs://research-lab-495809-tofu-state/bootstrap/

# 救回（要帶從上面查到的 soft-deleted GENERATION）
gcloud storage objects restore \
  gs://research-lab-495809-tofu-state/bootstrap/default.tfstate#<GENERATION>
```

**情境 C：Bucket 被刪（disaster recovery）**

`prevent_destroy` + uniform access + IAM 已大幅降低此情境發生機率，但仍可能因 project 層級災難（誤刪 project、billing 中斷導致資源回收）發生。一旦發生：

1. 確認 GCP project 若被 soft-deleted（30 天內），先 `gcloud projects undelete` 救回 project，bucket 與物件可能跟著回來
2. 若 project 還在但 bucket 不見，bucket 名稱在 GCP 全域唯一，幾分鐘內可能還無法被別人搶註但不保證
3. 重新 bootstrap：
   - 用 local state 跑一次 bootstrap stack 建立新 bucket（同 Lab 02 流程）
   - 若有本機備份的 state（如上面 `./broken.tfstate.bak` 或更早的 `gcloud storage cp` 備份）→ `gcloud storage cp` 推回新 bucket 對應 prefix
   - 若無備份 → 只能用 `tofu import` 把現存的 GCP 資源逐個 reimport 到新 state（工作量視資源數而定）
4. 全部 stack 跑 `tofu init -reconfigure` 指向新 bucket

> 教訓：bootstrap 完成後，建議每隔一段時間（或重大變更前）手動把 state 物件 `gcloud storage cp` 出來離線備份一份，作為 bucket 級災難的最後保險。
