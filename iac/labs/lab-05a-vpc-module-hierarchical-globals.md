# Lab 05a - VPC 抽 module + 階層化 globals

## 目標

把 `stacks/dev/network/` 內 5 個 GCP resource 抽出為 `_modules/network/` reusable module，**stack 變薄殼**只剩 module call；同時把參數階層化進 globals（root → env → stack），讓未來新增 `stacks/staging/network/` 只需要新增 globals 檔，不複製任何 `.tf`。

驗收條件：refactor 完成後 `tofu plan` 顯示 **0 add / 0 change / 0 destroy**（用 `moved` block 保 state 連續）。

## 設計重點

### 為何先做 refactor，不直接複製 stack

最容易示範 multi-env 的做法是直接 `cp -r stacks/dev/network stacks/staging/network`，但這違反「設定 re-use」精神 —— 兩份 `.tf` 之後會各自漂移。先抽 module，未來不論幾個 env 都共用同一份實作；單一變更點才是 re-use 的價值。

### 為何用 `moved` block 而非 `terraform state mv`

| 方案 | 優點 | 缺點 |
|------|------|------|
| `terraform state mv` | 直接、不留 `.tf` 痕跡 | 命令式、CI 不可重現、要 plan/apply 前手動跑 |
| **`moved` block** | 聲明式、可 review、CI 直接 plan 即生效 | 多一份檔案需事後清掃（可保留作為歷史） |

選 `moved`：plan 階段就能驗證 refactor 正確、PR reviewer 可直接看到對應關係。

#### `moved` block 的 state 改寫時序

| 階段 | 動作 | tfstate 變化 |
|------|------|--------------|
| local `tofu plan`（Phase C） | preview | ❌ 不變，輸出顯示 `# X has moved to Y` |
| CI `tofu apply`（Phase E） | 真實執行 | ✅ resource address 從 `google_compute_*` 改寫為 `module.vpc.google_compute_*`，**雲端資源不重建** |
| 之後再 plan | TF 看 state 已是新 address | moved block 變 no-op |
| Phase G 刪 moved.tf | 純清理 | state 不變 |

關鍵：state 真正改寫在 **apply**，不在 plan。本 runbook 在 Phase A 與 Phase E 各加一次 `tofu state list` snapshot，產出可 diff 的證據。

### 為何 module call 用 `generate_hcl` 而非靜態 `.tf`

兩種寫法都能跑，但靜態 `.tf` 需要額外 `variable` 宣告 + locals 橋接才能拿到 globals 值。`generate_hcl` 直接從 globals 展開 module 呼叫，少一層轉接、未來新 env 真的零 `.tf` 撰寫，純加 globals 即可。

### 為何 globals 拆兩層（env + per-stack）

- `stacks/dev/env.tm.hcl`：env 維度共用（name、name_prefix），未來 `stacks/dev/vm/` 等其他 stack 也會用到
- `stacks/dev/network/network.tm.hcl`：只 network stack 用的 CIDR、range 名等

scope 切清楚：env 層放「整個 dev 環境共用」，stack 層放「該 stack 私有」。一檔包完未來會變垃圾桶。

### 為何 v1 不加 `enable_nat` / `enable_iap_ssh` flags

過早抽象。先讓 module 跟現狀 1:1，driver 是「plan 0 changes」這條硬驗收。等到第二個 env 真的有「不要 NAT」需求時再加 flag，conditional logic 才有實際對應的決策邏輯。

### Module versions.tf 的 provider constraint

Module 內部宣告 `google >= 7.0`（彈性下限），實際 pin（`~> 7.31.0`）仍由 stack 端 `_terramate_versions.tf` 控制。Module 不該 pin patch 版，否則無法被多個 stack 共用。

## 變更檔案總覽

### 新增

```
_modules/network/
├─ main.tf        # 5 resources，name/region/cidr 全參數化
├─ variables.tf   # 8 個變數
├─ outputs.tf     # 6 outputs（同現有）
└─ versions.tf    # required_providers { google = ">= 7.0" }

stacks/dev/env.tm.hcl                  # globals "env" { name, name_prefix }
stacks/dev/network/network.tm.hcl      # globals "network" { CIDR, range names, IAP source }
stacks/dev/network/generate.tm.hcl     # generate_hcl "_module_vpc.tf"
stacks/dev/network/moved.tf            # 5 個 moved blocks（靜態）
```

### 修改

```
stacks/dev/network/outputs.tf  # value 改 module.vpc.*
```

### 刪除

```
stacks/dev/network/main.tf  # resource 全進 module
```

### 不動

```
config.tm.hcl                          # root globals 保持原樣
generate.tm.hcl                        # backend/provider/versions 生成不變
stacks/dev/network/stack.tm.hcl        # stack metadata 不動
其他 stacks（apis / vm / bootstrap / ci）  # 完全不受影響
```

## 步驟

### Phase A：準備分支與 module 骨架

1. 切分支
   ```bash
   cd /Users/fengnux/GitHub/tofu-terramate-lab
   git checkout -b lab-05a-vpc-module
   ```

2. **Refactor 前 state snapshot**（baseline，供 Phase E diff 用）
   ```bash
   cd stacks/dev/network
   tofu state list > /tmp/network-state-before.txt
   cat /tmp/network-state-before.txt
   ```
   預期看到 5 個 resource，全部無 `module.` 前綴：
   ```
   google_compute_firewall.allow_iap_ssh
   google_compute_network.vpc
   google_compute_router.nat
   google_compute_router_nat.nat
   google_compute_subnetwork.primary
   ```
   ⚠️ 同時記下 VPC id 作為「資源未重建」證據：
   ```bash
   gcloud compute networks describe dev-vpc \
     --project=research-lab-495809 \
     --format="value(id,creationTimestamp)" > /tmp/network-vpc-before.txt
   cat /tmp/network-vpc-before.txt
   cd ../../..
   ```

3. 建立 `_modules/network/`

   `variables.tf`
   ```hcl
   variable "name_prefix" {
     type        = string
     description = "資源命名前綴，例如 dev / staging / prod"
   }

   variable "region" {
     type        = string
     description = "subnet 與 Cloud Router 所在 region"
   }

   variable "cidr_primary" {
     type        = string
     description = "主要 subnet CIDR"
   }

   variable "cidr_pods" {
     type        = string
     description = "GKE pods secondary range CIDR"
   }

   variable "cidr_services" {
     type        = string
     description = "GKE services secondary range CIDR"
   }

   variable "pods_range_name" {
     type        = string
     description = "GKE pods alias range name"
   }

   variable "services_range_name" {
     type        = string
     description = "GKE services alias range name"
   }

   variable "iap_source_range" {
     type        = string
     description = "IAP TCP forwarding 來源 CIDR（GCP 固定 35.235.240.0/20）"
     default     = "35.235.240.0/20"
   }
   ```

   `versions.tf`
   ```hcl
   terraform {
     required_version = ">= 1.10"
     required_providers {
       google = {
         source  = "registry.opentofu.org/hashicorp/google"
         version = ">= 7.0"
       }
     }
   }
   ```

   `main.tf`（resource 內所有 `dev-*` 改成 `"${var.name_prefix}-*"`，CIDR 改 `var.cidr_*`）
   ```hcl
   locals {
     vpc_name    = "${var.name_prefix}-vpc"
     subnet_name = "${var.name_prefix}-subnet-${var.region}"
   }

   resource "google_compute_network" "vpc" {
     name                    = local.vpc_name
     auto_create_subnetworks = false
     routing_mode            = "GLOBAL"
     description             = "${var.name_prefix} shared VPC（lab 環境）"
   }

   resource "google_compute_subnetwork" "primary" {
     name          = local.subnet_name
     network       = google_compute_network.vpc.id
     region        = var.region
     ip_cidr_range = var.cidr_primary

     private_ip_google_access = true

     secondary_ip_range {
       range_name    = var.pods_range_name
       ip_cidr_range = var.cidr_pods
     }

     secondary_ip_range {
       range_name    = var.services_range_name
       ip_cidr_range = var.cidr_services
     }
   }

   resource "google_compute_firewall" "allow_iap_ssh" {
     name    = "allow-iap-ssh"
     network = google_compute_network.vpc.name

     direction     = "INGRESS"
     source_ranges = [var.iap_source_range]
     target_tags   = ["iap-ssh"]

     allow {
       protocol = "tcp"
       ports    = ["22"]
     }

     description = "允許 IAP TCP forwarding 從 ${var.iap_source_range} 對 tag=iap-ssh 的 VM 做 SSH"
   }

   resource "google_compute_router" "nat" {
     name    = "${var.name_prefix}-nat-router"
     region  = var.region
     network = google_compute_network.vpc.id
   }

   resource "google_compute_router_nat" "nat" {
     name                               = "${var.name_prefix}-nat"
     router                             = google_compute_router.nat.name
     region                             = var.region
     nat_ip_allocate_option             = "AUTO_ONLY"
     source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

     log_config {
       enable = true
       filter = "ERRORS_ONLY"
     }
   }
   ```

   `outputs.tf`（與現有 `stacks/dev/network/outputs.tf` 同 schema）
   ```hcl
   output "vpc_self_link" {
     value = google_compute_network.vpc.self_link
   }

   output "vpc_name" {
     value = google_compute_network.vpc.name
   }

   output "subnet_self_link" {
     value = google_compute_subnetwork.primary.self_link
   }

   output "subnet_name" {
     value = google_compute_subnetwork.primary.name
   }

   output "pods_range_name" {
     value = google_compute_subnetwork.primary.secondary_ip_range[0].range_name
   }

   output "services_range_name" {
     value = google_compute_subnetwork.primary.secondary_ip_range[1].range_name
   }
   ```

⚠️ **比對檢查**：name_prefix = "dev" 時，所有資源名稱必須與現有完全一致：
- `dev-vpc` ✓
- `dev-subnet-asia-east1` ✓
- `allow-iap-ssh` ✓（與 prefix 無關，獨立命名）
- `dev-nat-router` ✓（原本是 `dev-nat-router`）
- `dev-nat` ✓

4. commit
   ```bash
   git add _modules/network
   git commit -m "feat(modules): add reusable network module (VPC/subnet/NAT/IAP firewall)"
   ```

### Phase B：階層化 globals

1. 新增 `stacks/dev/env.tm.hcl`
   ```hcl
   globals "env" {
     name        = "dev"
     name_prefix = "dev"
   }
   ```

2. 新增 `stacks/dev/network/network.tm.hcl`
   ```hcl
   globals "network" {
     cidr_primary        = "10.10.0.0/20"
     cidr_pods           = "10.20.0.0/14"
     cidr_services       = "10.30.0.0/20"
     pods_range_name     = "${global.env.name_prefix}-pods"
     services_range_name = "${global.env.name_prefix}-services"
     iap_source_range    = "35.235.240.0/20"
   }
   ```

3. commit
   ```bash
   git add stacks/dev/env.tm.hcl stacks/dev/network/network.tm.hcl
   git commit -m "feat(globals): introduce env + network hierarchical globals"
   ```

### Phase C：stack 改寫（module call + moved + outputs）

1. 新增 `stacks/dev/network/generate.tm.hcl`
   ```hcl
   generate_hcl "_module_vpc.tf" {
     content {
       module "vpc" {
         source = "../../../_modules/network"

         name_prefix         = global.env.name_prefix
         region              = global.gcp.region
         cidr_primary        = global.network.cidr_primary
         cidr_pods           = global.network.cidr_pods
         cidr_services       = global.network.cidr_services
         pods_range_name     = global.network.pods_range_name
         services_range_name = global.network.services_range_name
         iap_source_range    = global.network.iap_source_range
       }
     }
   }
   ```

2. 新增 `stacks/dev/network/moved.tf`（靜態，refactor 用）
   ```hcl
   moved {
     from = google_compute_network.vpc
     to   = module.vpc.google_compute_network.vpc
   }

   moved {
     from = google_compute_subnetwork.primary
     to   = module.vpc.google_compute_subnetwork.primary
   }

   moved {
     from = google_compute_firewall.allow_iap_ssh
     to   = module.vpc.google_compute_firewall.allow_iap_ssh
   }

   moved {
     from = google_compute_router.nat
     to   = module.vpc.google_compute_router.nat
   }

   moved {
     from = google_compute_router_nat.nat
     to   = module.vpc.google_compute_router_nat.nat
   }
   ```

3. 改寫 `stacks/dev/network/outputs.tf`
   ```hcl
   output "vpc_self_link" {
     value       = module.vpc.vpc_self_link
     description = "dev VPC 的 self_link（供其他資源參照）"
   }

   output "vpc_name" {
     value       = module.vpc.vpc_name
     description = "dev VPC 名稱"
   }

   output "subnet_self_link" {
     value       = module.vpc.subnet_self_link
     description = "asia-east1 主要子網路的 self_link"
   }

   output "subnet_name" {
     value       = module.vpc.subnet_name
     description = "asia-east1 主要子網路名稱"
   }

   output "pods_range_name" {
     value       = module.vpc.pods_range_name
     description = "GKE alias IP range（pods），未來 GKE lab 使用"
   }

   output "services_range_name" {
     value       = module.vpc.services_range_name
     description = "GKE alias IP range（services），未來 GKE lab 使用"
   }
   ```

4. 刪 `stacks/dev/network/main.tf`
   ```bash
   git rm stacks/dev/network/main.tf
   ```

5. 跑 generate
   ```bash
   terramate generate
   ```
   應產出 `stacks/dev/network/_module_vpc.tf`，內容對齊 globals 展開後的值。

6. local plan（在 commit 前先驗一次，確認 0 changes 才 commit）
   ```bash
   cd stacks/dev/network
   tofu init -upgrade
   tofu plan
   ```
   預期輸出：
   ```
   No changes. Your infrastructure matches the configuration.
   ```
   plan 內可能會顯示 `Terraform detected the following changes made outside of Terraform since the last run:` 或 `# (5 resources)` 配合 moved 訊息 —— 這是正常的 refactor display，重點看最末 summary 是否 `0 to add, 0 to change, 0 to destroy`。

7. commit
   ```bash
   cd ../../..
   git add stacks/dev/network/
   git commit -m "refactor(dev/network): use _modules/network via generate_hcl + moved blocks"
   ```

### Phase D：PR + CI plan 驗證

1. push + 開 PR
   ```bash
   git push -u origin lab-05a-vpc-module
   gh pr create --title "Lab 05a: VPC 抽 module + 階層化 globals" --body "..."
   ```

2. CI plan job 應顯示 0 changes（同 local plan）。如果有任何 add/destroy，停下來檢查 moved block 是否漏寫或對應錯誤。

3. PR comment 截圖貼進當日 log。

### Phase E：merge + apply 驗收

1. merge PR
2. main push 觸發 apply workflow（per Lab 04a 需手動 approve），apply 應該是 no-op
3. apply log 內應看到 5 個 `moved` 訊息，類似：
   ```
   google_compute_network.vpc: Refreshing state...
   ...
   Terraform will perform the following actions:
     # google_compute_network.vpc has moved to module.vpc.google_compute_network.vpc
   ...
   Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
   ```

4. **State diff 驗收**（apply 完成後本機跑）
   ```bash
   cd /Users/fengnux/GitHub/tofu-terramate-lab
   git checkout main && git pull
   cd stacks/dev/network
   tofu init  # 對齊 main 後重新 init
   tofu state list > /tmp/network-state-after.txt
   diff /tmp/network-state-before.txt /tmp/network-state-after.txt
   ```
   預期 diff 完整顯示 5 個 address 改寫：
   ```
   < google_compute_firewall.allow_iap_ssh
   < google_compute_network.vpc
   < google_compute_router.nat
   < google_compute_router_nat.nat
   < google_compute_subnetwork.primary
   ---
   > module.vpc.google_compute_firewall.allow_iap_ssh
   > module.vpc.google_compute_network.vpc
   > module.vpc.google_compute_router.nat
   > module.vpc.google_compute_router_nat.nat
   > module.vpc.google_compute_subnetwork.primary
   ```

5. **雲端資源未重建驗證**
   ```bash
   gcloud compute networks describe dev-vpc \
     --project=research-lab-495809 \
     --format="value(id,creationTimestamp)" > /tmp/network-vpc-after.txt
   diff /tmp/network-vpc-before.txt /tmp/network-vpc-after.txt
   ```
   預期：**無 diff**。id 與 creationTimestamp 一致 = 雲端 VPC 沒被重建。

6. outputs 值驗證
   ```bash
   cd /Users/fengnux/GitHub/tofu-terramate-lab
   terramate run --tags network -- tofu output
   ```
   對比 refactor 前的 output 值（vpc_self_link、subnet_self_link 等應完全一致）。

### Phase F：示範 multi-env 模板（文件 only）

寫進當日 log 或新文件 `iac/docs/terramate-multi-env.md`，列出「未來新增 staging 環境需要的最小 diff」：

```
+ stacks/staging/env.tm.hcl
+   globals "env" {
+     name        = "staging"
+     name_prefix = "staging"
+   }

+ stacks/staging/apis/stack.tm.hcl    # 複製 dev/apis/stack.tm.hcl 改 id
+ stacks/staging/network/stack.tm.hcl
+ stacks/staging/network/network.tm.hcl   # 自己的 CIDR
```

不需要新增任何 `.tf` 檔。**這是本 lab 的價值證明。**

### Phase G：（可選）清理 moved blocks

apply 成功後，moved blocks 已經完成歷史任務。可選：
- **保留**：留作 refactor 歷史紀錄，未來看 git blame 有上下文
- **刪除**：另開一個小 PR 移除 `moved.tf`，PR 標題 `chore: remove no-op moved blocks after refactor`

推薦先保留至少一輪 release cycle，確認沒有遺漏。

## 風險與緩解

| 風險 | 影響 | 緩解 |
|------|------|------|
| `moved` block 漏寫 | TF 對該資源 destroy + create（IP 改變、firewall 短暫中斷） | Phase A 結尾的「比對檢查」清單；plan 看到任何非 0 changes 立即停 |
| name_prefix 算錯（例如多加 dash） | 全部 resource force replace | name_prefix 必須是純字串 "dev"，不是 "dev-"；module 內已加 dash |
| secondary_ip_range 順序錯位 | outputs.tf 的 `[0]` / `[1]` 對應錯誤 | module 內 pods 寫第一、services 寫第二，與現狀 main.tf 一致 |
| Module source 相對路徑算錯 | `tofu init` 找不到 module | 從 `stacks/dev/network/` 出發 `../../../_modules/network`，三層回上去到 repo root |
| `terramate generate` 與既有 `_terramate_*.tf` 衝突 | 檔名衝突 | 新檔名 `_module_vpc.tf`，與既有 `_terramate_versions/backend/provider.tf` 不撞 |
| globals 引用 `${global.env.name_prefix}` 但 dev 子樹外的 stack（如 bootstrap）拿不到 env globals | bootstrap / ci stack 生成失敗 | `env` 與 `network` globals 都定義在 `stacks/dev/` 子樹，scope 不外洩；root generate.tm.hcl 內的 `tm_try(global.env.name, "shared")` 已是防呆 |

## 驗收清單

- [ ] Phase A 起點：`/tmp/network-state-before.txt` 與 `/tmp/network-vpc-before.txt` 已存
- [ ] `_modules/network/` 4 個檔案建立
- [ ] `stacks/dev/env.tm.hcl` 與 `stacks/dev/network/network.tm.hcl` 建立
- [ ] `stacks/dev/network/main.tf` 刪除、`moved.tf` + `generate.tm.hcl` 新增、`outputs.tf` 改寫
- [ ] `terramate generate` 無錯，產出 `_module_vpc.tf`
- [ ] `terramate run --tags network -- tofu init -upgrade` 成功
- [ ] `terramate run --tags network -- tofu plan` 顯示 **0 to add, 0 to change, 0 to destroy**
- [ ] PR opened，CI plan 同樣 0 changes
- [ ] merge → apply no-op，apply log 內含 5 個 `# X has moved to Y` 訊息
- [ ] `diff /tmp/network-state-before.txt /tmp/network-state-after.txt` 顯示 5 個 address 加上 `module.vpc.` 前綴
- [ ] `diff /tmp/network-vpc-before.txt /tmp/network-vpc-after.txt` **無差異**（雲端資源未重建）
- [ ] outputs 值未變（`terramate run --tags network -- tofu output` 對比）
- [ ] log 紀錄 multi-env 範本 diff
- [ ] 當日 log 補 `iac/labs/logs/2026-MM-DD.md` 紀錄

## 不在本 lab 範圍

- `enable_nat` / `enable_iap_ssh` conditional flags（v2 等實際多 env 需求出現）
- 把 module 抽到獨立 versioned repo（另一個 lab：semver release + tag pinning）
- 把 `stacks/dev/apis/` 或 `stacks/dev/vm/` 也 modularize（先驗證 network 模式，再複製方法論）
- Catalyst components / bundles（Lab 05c 主題）
- 真實新增 staging GCP project（範例 diff 文件即可，不真 apply）

## 後續 lab 預告

- **Lab 05b**：把 `terramate run -- tofu init && tofu plan/apply` 包成 `terramate script run`，CI + 本機共用
- **Lab 05c**（若需要）：Catalyst components 把 network module 升級為 reusable blueprint
- **Lab 06**：實際新增 staging 環境（需先決定是否開第二個 GCP project，或共用 project 不同 name_prefix）
