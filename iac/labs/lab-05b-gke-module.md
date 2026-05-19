# Lab 05b - GKE Autopilot module + IAP bastion kubectl

## 目標

把 GKE Autopilot cluster 包成 `_modules/gke/` reusable module，建立 `stacks/dev/gke/` 把 cluster 落地到既有 `dev-vpc`，並用 `dev-vm` 當 IAP bastion 從本機透過 SSH 連到 cluster API server 跑 kubectl。

驗收條件：
- `tofu plan` PR 顯示 `1 to add`（cluster）+ 必要的 IAM/data source；apply 成功
- `gcloud compute ssh dev-vm --tunnel-through-iap` 後在 VM 內 `kubectl get nodes` 能列出 Autopilot 系統節點
- 部署一個範例 Workload Identity Pod，能拿到 GCP SA token

## 設計重點

### 為何選 Autopilot 而非 Standard

Standard 形態的 lab 教學價值高（學 node pool / shielded VM / preemptible），但本 lab 主軸是「**驗證 custom module + 跨 stack data source 模式**」，不是 GKE 本身的節點調校。Autopilot 把 node 抽象掉後：

- Module 從 5-7 個 resource 縮成 1 個 cluster + 2 個 data source，重點落在 module 介面設計
- 計費模型乾淨（pod request × 時間），不必擔心忘記 destroy node pool
- 升級到 Standard 是 cluster 重建（destroy+create），不是 in-place migration — 接受這個 trade-off，先驗證模式

未來真的需要 node-level 調校（GPU / 特殊 taint / sole-tenant）再開 v2 lab 換成 Standard，與 Lab 05a「v1 跟現狀 1:1，需求驅動加 flag」一致。

### 為何用 GCP data source 而非 `terraform_remote_state`

兩個方案都能拿到 network outputs：

| 方案 | 優點 | 缺點 |
|------|------|------|
| `terraform_remote_state` | 強型別、network stack 已宣告的 output 直接拿 | gke stack SA 要拿 network state bucket 的 `storage.objectViewer`；state 內含其他敏感資料時有 over-exposure 風險 |
| **`data.google_compute_network` + `data.google_compute_subnetwork`** | 依賴雲端真實狀態（如果手動刪 VPC，plan 直接失敗）；無 state bucket 權限耦合；CI plan SA 只要 `compute.viewer` 即可 | 多一次 GCP API call；要靠 naming convention（`${name_prefix}-vpc`）找到資源 |

選 data source：plan 行為更貼近「驗證雲端事實」、權限邊界更窄、與 Lab 05a 的 globals naming convention 天然搭配。

secondary range 名稱（`pods_range_name` / `services_range_name`）已經在 `globals "network"` 內、跟 network stack 同源宣告 —— gke stack 直接讀 global 即可，**不必走 data source 也不必走 remote_state**。

### 為何 Private nodes + Private endpoint + IAP bastion

| 模式 | 與 Lab 03c IAP/NAT 設計 | kubectl 體驗 | production 相似度 |
|------|----------------------|------------|------------------|
| Public nodes + Public endpoint | 破壞既有「無 public IP + IAP only」敘事 | 直接 kubectl | 低 |
| **Private nodes + Private endpoint + IAP bastion** | 一致 | SSH 進 dev-vm 跑 kubectl | 高 |
| Private nodes + Public endpoint + authorized networks | 半 production，API server 仍對外 | 直接 kubectl 但要鎖 IP | 中 |

選私網 endpoint：跟既有 evidence-pack 的「資源無公開介面」敘事一致，且 dev-vm + IAP 已是落地的 bastion 方案，沒有額外基建成本。

### 為何 `location` 做變數但 lab v1 一定傳 region

Autopilot 強制 regional cluster — 但 `google_container_cluster.location` 的 schema 還是接 zone/region 字串。Module 不做 conditional 驗證（過早抽象），單純定義 `variable "location"`，stack globals 傳 `global.gcp.region`。未來 v2 換 Standard 時，這個變數已經是對的形狀，可以傳 zone。

### 為何 release_channel 預設 REGULAR

REGULAR 是 GKE 預設的 production 推薦 channel，週期穩定。RAPID 適合測試新版本但 minor version 變動快、lab 環境不需要。STABLE 落後 2-3 minor version，lab 不需要。Module variable 留 default `"REGULAR"`，stack 不覆蓋。

### 為何 deletion_protection 預設 true 但 stack 端設 false

GKE provider 7.x 預設 `deletion_protection = true`，destroy 會拒絕。Lab 階段預期會手動 destroy（避免燒錢），stack globals 設 `false`；module variable default 保持 `true`（production-safe）。

### 成本警告（**重要**）

- Autopilot regional control plane：~$73/月（與 Standard regional 相同；Autopilot 不再有 free tier）
- Pod request × 時間計費：lab 級 hello workload (200m CPU / 256Mi RAM) ≈ $5-10/月
- **預估 dev cluster 啟用期間：$80-90/月**

⚠️ lab apply 完驗收後**直接 destroy**，evidence-pack 留 PR plan + apply log 即可。不要長期掛著。

### 為何 master CIDR `/28` 寫死在 globals

GKE 私網 cluster 的 control plane VPC peering 必須是 `/28`（GCP 硬性規定）。寫 globals 不寫 module default，是因為 CIDR 是 env 共享資產，未來新 env 各自分配。Lab v1 取 `172.16.0.0/28`，與既有 `10.x.x.x` workload CIDR 不重疊。

## 前置：CI / VM 權限擴張（先 manual apply WIF stack）

⚠️ 這部分修改 `stacks/ci/github-actions-wif/`（foundational stack），依 ADR-003 走**本地 manual apply**，不上 CI。

### 變更

`stacks/ci/github-actions-wif/main.tf` `locals` 區塊：

```hcl
locals {
  ci_project_roles = [
    # ... 既有 7 個 ...
    "roles/container.admin",         # 新增：建立/刪除 GKE cluster
  ]

  plan_project_roles = [
    # ... 既有 3 個 ...
    "roles/container.viewer",        # 新增：PR plan 讀 cluster 狀態
  ]

  drift_project_roles = [
    # ... 既有 3 個 ...
    "roles/container.viewer",        # 新增：drift detection 讀 cluster 狀態
  ]
}
```

### dev-vm 自訂 SA（取代 default compute SA）

`stacks/dev/vm/` 目前用 default compute SA。為了支援後續 K8s 系列實驗（頻繁 kubectl + 可能加 Artifact Registry / Cloud SQL 等權限），建立專屬 SA `dev-vm@...`：

`stacks/dev/vm/main.tf` 變更（新增 SA + 替換 VM `service_account` block）：

```hcl
resource "google_service_account" "dev_vm" {
  account_id   = "dev-vm"
  display_name = "dev-vm runtime"
  description  = "dev-vm 執行身份；K8s 實驗系列共用"
}

resource "google_project_iam_member" "dev_vm_container_developer" {
  project = data.google_client_config.current.project
  role    = "roles/container.developer"
  member  = google_service_account.dev_vm.member
}

resource "google_project_iam_member" "dev_vm_container_cluster_viewer" {
  project = data.google_client_config.current.project
  role    = "roles/container.clusterViewer"
  member  = google_service_account.dev_vm.member
}

data "google_client_config" "current" {}
```

`google_compute_instance.dev_vm` 內加 `service_account` block：

```hcl
resource "google_compute_instance" "dev_vm" {
  # ... 既有 ...

  service_account {
    email  = google_service_account.dev_vm.email
    scopes = ["cloud-platform"]
  }
}
```

⚠️ **VM 重啟副作用**：改 `service_account.email` 是 provider 7.x 的 **in-place update**，但 GCP API 會觸發 VM stop/start。Boot disk 上手動裝的 kubectl / gke-gcloud-auth-plugin 會保留（pd-standard 不被刪），但執行中的 session 中斷。

### 三個變更單位（PR-first）

| 變更 | 流程 | 原因 |
|------|------|------|
| WIF stack（ci/plan/drift 各加 container role） | **manual apply** | ADR-003 foundational：「能改誰可以變成 CI」 |
| dev/vm stack（建 SA + 替換 service_account） | **PR** | 一般 dev workload stack；走 [PR-first](feedback_pr_first_workflow.md) |
| dev/gke stack（本 lab 主體） | **PR** | 同上 |

### 執行順序

```bash
cd /Users/fengnux/GitHub/tofu-terramate-lab

# Step 1: WIF stack（manual）
git checkout -b lab-05b-wif-container-roles
# 編輯 stacks/ci/github-actions-wif/main.tf
terramate run --tags wif -- tofu init
terramate run --tags wif -- tofu plan
terramate run --tags wif -- tofu apply
git add stacks/ci/github-actions-wif/main.tf
git commit -m "feat(wif): add container roles to ci/plan/drift SAs for GKE lab"
# WIF stack 不走 CI，但仍開 PR 留紀錄（merge 後 main 不會再 apply 一次，因 ADR-003 排除）

# Step 2: dev/vm SA PR
git checkout -b lab-05b-vm-runtime-sa main
# 編輯 stacks/dev/vm/main.tf
terramate generate
cd stacks/dev/vm && tofu init && tofu plan && cd ../../..
git add stacks/dev/vm/main.tf
git commit -m "feat(dev/vm): switch to dedicated dev-vm SA with container.developer"
git push -u origin lab-05b-vm-runtime-sa
gh pr create ...
# merge 後 main apply（per Lab 04a approval gate）
# 驗證：在 dev-vm 內 gcloud auth list 顯示 dev-vm@... 為 active

# Step 3: dev/gke PR（本 lab 主體 Phase B 之後）
git checkout -b lab-05b-gke-module main
# ... 進入下面 Phase B
```

## 變更檔案總覽

### 新增

```
_modules/gke/
├─ main.tf        # 1 個 google_container_cluster (autopilot)
├─ variables.tf   # 8 個變數
├─ outputs.tf     # 5 個 outputs
└─ versions.tf    # required_providers { google = ">= 7.0" }

stacks/dev/gke/
├─ stack.tm.hcl              # tags = ["gke"]
├─ gke.tm.hcl                # globals "gke" { master_cidr, release_channel, ... }
├─ generate.tm.hcl           # generate_hcl "_module_gke.tf"（含 module call + data sources）
└─ outputs.tf                # cluster_name / endpoint / location 等
```

### 修改

```
stacks/ci/github-actions-wif/main.tf   # ci/plan/drift roles 各加一條 container.*
stacks/dev/vm/main.tf                  # 新增自訂 dev-vm SA + 替換 VM service_account block
```

### 不動

```
_modules/network/             # 沿用，secondary range 已備好
stacks/dev/network/           # 沿用
stacks/dev/env.tm.hcl         # 沿用
config.tm.hcl                 # root globals 不動
```

## 步驟

### Phase A：前置 SA 權限擴張（前述）

1. WIF stack 變更 → manual apply（ADR-003）
2. dev/vm 新增 dev-vm SA → PR + CI plan + approval apply
3. 驗證：在 dev-vm 內 `gcloud auth list` 應顯示 `dev-vm@research-lab-495809.iam.gserviceaccount.com` 為 active；`gcloud container clusters list` 回空清單（無 permission error）

### Phase B：建 `_modules/gke/` module

`variables.tf`

```hcl
variable "name_prefix" {
  type        = string
  description = "資源命名前綴（dev / staging / prod）"
}

variable "location" {
  type        = string
  description = "Cluster location；Autopilot 限定 region 字串（如 asia-east1）"
}

variable "network_self_link" {
  type        = string
  description = "VPC self_link（從 data source 傳入）"
}

variable "subnetwork_self_link" {
  type        = string
  description = "Subnet self_link（從 data source 傳入）"
}

variable "pods_range_name" {
  type        = string
  description = "Subnet 內 GKE pods alias range 名稱"
}

variable "services_range_name" {
  type        = string
  description = "Subnet 內 GKE services alias range 名稱"
}

variable "master_ipv4_cidr" {
  type        = string
  description = "Control plane VPC peering CIDR（必須 /28）"
}

variable "master_authorized_cidrs" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "允許存取 private endpoint 的 CIDR 清單（如 dev-subnet 內網段）"
}

variable "release_channel" {
  type        = string
  default     = "REGULAR"
  description = "GKE release channel；REGULAR / RAPID / STABLE"
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Provider 7.x 預設 true；lab 端可關閉以便 destroy"
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

`main.tf`

```hcl
locals {
  cluster_name = "${var.name_prefix}-gke"
}

resource "google_container_cluster" "primary" {
  name     = local.cluster_name
  location = var.location

  enable_autopilot    = true
  deletion_protection = var.deletion_protection

  network    = var.network_self_link
  subnetwork = var.subnetwork_self_link

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = var.master_ipv4_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  release_channel {
    channel = var.release_channel
  }

  # Autopilot 預設啟用 Workload Identity（pool = PROJECT_ID.svc.id.goog），不需顯式宣告
  # 但 outputs 仍會曝露給 application 層用
}
```

`outputs.tf`

```hcl
output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_location" {
  value = google_container_cluster.primary.location
}

output "endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true
}

output "ca_certificate" {
  value     = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "workload_identity_pool" {
  value       = google_container_cluster.primary.workload_identity_config[0].workload_pool
  description = "格式 PROJECT_ID.svc.id.goog，給應用層 KSA→GSA binding 用"
}
```

commit：

```bash
git add _modules/gke
git commit -m "feat(modules): add GKE Autopilot reusable module (private cluster + IAP-only)"
```

### Phase C：建 `stacks/dev/gke/` stack

`stack.tm.hcl`

```hcl
stack {
  name        = "dev-gke"
  description = "dev Autopilot GKE cluster on dev-vpc"
  id          = "<uuidgen 產生>"
  tags        = ["gke"]
}
```

`gke.tm.hcl`

```hcl
globals "gke" {
  master_cidr     = "172.16.0.0/28"
  release_channel = "REGULAR"

  master_authorized_cidrs = [
    {
      cidr_block   = "10.10.0.0/20"  # 與 globals.network.cidr_primary 對齊；dev-subnet 內所有 VM 可達
      display_name = "dev-subnet-primary"
    },
  ]

  # lab 階段允許 destroy，production 應改回 true
  deletion_protection = false
}
```

`generate.tm.hcl`

```hcl
generate_hcl "_module_gke.tf" {
  content {
    data "google_compute_network" "vpc" {
      name = "${global.env.name_prefix}-vpc"
    }

    data "google_compute_subnetwork" "primary" {
      name   = "${global.env.name_prefix}-subnet-${global.gcp.region}"
      region = global.gcp.region
    }

    module "gke" {
      source = "../../../_modules/gke"

      name_prefix          = global.env.name_prefix
      location             = global.gcp.region
      network_self_link    = data.google_compute_network.vpc.self_link
      subnetwork_self_link = data.google_compute_subnetwork.primary.self_link
      pods_range_name      = global.network.pods_range_name
      services_range_name  = global.network.services_range_name

      master_ipv4_cidr        = global.gke.master_cidr
      master_authorized_cidrs = global.gke.master_authorized_cidrs
      release_channel         = global.gke.release_channel
      deletion_protection     = global.gke.deletion_protection
    }
  }
}
```

`outputs.tf`（靜態，stack 端）

```hcl
output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_location" {
  value = module.gke.cluster_location
}

output "workload_identity_pool" {
  value = module.gke.workload_identity_pool
}
```

generate + plan：

```bash
terramate generate
cd stacks/dev/gke
tofu init
tofu plan
```

預期：`1 to add, 0 to change, 0 to destroy`（cluster + data source 是 plan-time 查詢，不算 resource）。

commit：

```bash
cd ../../..
git add stacks/dev/gke
git commit -m "feat(dev/gke): add Autopilot cluster stack via _modules/gke + data source"
```

### Phase D：PR + CI plan 驗證

1. push + 開 PR
2. CI plan job 應顯示 `1 to add`，且 data source 在 plan 階段就確認 VPC/subnet 存在
3. PR comment（per Lab 04c）貼截圖到當日 log
4. Security scan（per Lab 04e）應通過 —— Autopilot 預設啟用 shielded VM / secure boot，KICS/tfsec 不該爆
5. ⚠️ 若 scanner 報 `private endpoint should be enabled` —— 已啟用，false positive；若報 `release channel should be specified` —— 已指定，false positive

### Phase E：merge + apply（環境 approval gate）

1. merge PR → main push 觸發 apply workflow（per Lab 04a 走 environment "production" approval）
2. apply 約 5-10 分鐘（GKE cluster create 慢）
3. apply 結束後 `tofu output` 拿到 cluster_name、location

### Phase F：驗收（從 dev-vm IAP bastion 跑 kubectl）

1. SSH 進 dev-vm
   ```bash
   gcloud compute ssh dev-vm \
     --zone=asia-east1-b \
     --tunnel-through-iap \
     --project=research-lab-495809
   ```

2. 在 VM 內安裝 kubectl + gke-gcloud-auth-plugin
   ```bash
   sudo apt-get update
   sudo apt-get install -y google-cloud-cli-gke-gcloud-auth-plugin kubectl
   ```

3. 取 cluster credentials
   ```bash
   gcloud container clusters get-credentials dev-gke \
     --region=asia-east1 \
     --project=research-lab-495809 \
     --internal-ip
   ```

   ⚠️ `--internal-ip` 是 private endpoint cluster 必要 flag，否則 kubeconfig 會寫公開 IP（不存在）。

4. kubectl 連線驗證
   ```bash
   kubectl get nodes
   kubectl get ns
   ```

   預期：`kube-system` 等 system namespace 存在；Autopilot 不會顯示用戶 node（系統節點顯示為 `gk3-*`）。

5. （可選）部署 Workload Identity 範例
   ```bash
   kubectl create namespace wi-demo
   kubectl create serviceaccount demo -n wi-demo

   # 取 cluster 的 workload_identity_pool
   POOL=$(gcloud container clusters describe dev-gke --region=asia-east1 \
     --format="value(workloadIdentityConfig.workloadPool)")

   # 用 default compute SA 當目標 GSA（lab 簡化；production 應建專用 SA）
   PROJECT=research-lab-495809
   GSA="$(gcloud iam service-accounts list --filter='email~^[0-9]+-compute@' --format='value(email)')"

   gcloud iam service-accounts add-iam-policy-binding "$GSA" \
     --role=roles/iam.workloadIdentityUser \
     --member="serviceAccount:${POOL}[wi-demo/demo]"

   kubectl annotate serviceaccount demo \
     -n wi-demo \
     iam.gke.io/gcp-service-account="$GSA"

   # 跑 pod 拿 token
   kubectl run -it --rm wi-test \
     --image=google/cloud-sdk:slim \
     --serviceaccount=demo \
     -n wi-demo \
     -- gcloud auth list
   ```

   預期 output 顯示 `ACTIVE` 為 `${GSA}` —— Workload Identity 鏈通。

### Phase G：拆除（重要，控成本）

驗收完成、log 截圖後：

```bash
cd stacks/dev/gke
tofu destroy
```

`deletion_protection = false` 已在 globals 設好，destroy 不會被擋。確認雲端 cluster 真的消失：

```bash
gcloud container clusters list --project=research-lab-495809
# 應該不再出現 dev-gke
```

選項：保留 stack 檔案不刪（state 為空），下次需要 reapply 即可；或同步刪 stack 目錄走另一個 PR。Lab evidence-pack 保留前者較有教學價值。

## 風險與緩解

| 風險 | 影響 | 緩解 |
|------|------|------|
| Autopilot pod-based 計費比預期高 | 月底帳單超預算 | Phase G 驗收後立刻 destroy；不要長期掛著 |
| master CIDR `172.16.0.0/28` 與既有 VPC route 衝突 | cluster create 失敗 | dev VPC 內 workload CIDR 全在 10.x.x.x；172.16.x.x 是新區間 |
| Private endpoint 連不到（master_authorized_networks 設定漏） | kubectl 從 dev-vm 仍 timeout | 確保 `10.10.0.0/20`（dev-subnet 主要範圍）在 authorized_cidrs 內 |
| dev-vm 沒裝 gke-gcloud-auth-plugin | `kubectl` exec 失敗 | Phase F 步驟 2 明確要求安裝；v2 lab 考慮塞 startup-script |
| 替換 VM service_account 觸發 stop/start | 執行中 SSH session 中斷 | Phase A step 2 apply 前先登出 dev-vm；boot disk 內容保留 |
| Provider 7.x deletion_protection 預設 true | destroy 卡住 | globals 已設 false |
| GKE cluster create 超過 GitHub Actions job timeout（預設 6 小時 OK，但 step timeout 可能短） | apply workflow 失敗 | workflow 已設定 step timeout > 30min；GKE create ≈ 8min 安全 |
| Autopilot 不支援的 workload spec（HostPort、Privileged container） | demo workload 失敗 | hello pod 用 cloud-sdk image，無特權需求 |
| network/subnet data source 找不到 | plan 階段失敗 | naming convention 與 Lab 05a 一致；若改名要同步 |

## 驗收清單

- [ ] WIF stack 加 container.admin / viewer，manual apply 完成
- [ ] dev-vm SA binding container.developer 完成（PR or manual）
- [ ] `_modules/gke/` 4 個檔案建立
- [ ] `stacks/dev/gke/` 4 個檔案建立（stack.tm.hcl 的 id 用 uuidgen 產生）
- [ ] `terramate generate` 無錯，產出 `_module_gke.tf`
- [ ] local `tofu plan` 顯示 1 to add
- [ ] PR opened，CI plan 同樣 1 to add
- [ ] security scan 通過（或記錄 false positive）
- [ ] merge → apply 成功，cluster STATUS = RUNNING
- [ ] `gcloud compute ssh dev-vm --tunnel-through-iap` 成功
- [ ] VM 內 `kubectl get nodes` 列出 Autopilot 系統節點
- [ ] （可選）Workload Identity demo pod 拿到 GSA token
- [ ] `tofu destroy` 完成，cluster 從雲端消失
- [ ] 當日 log 補 `iac/labs/logs/2026-MM-DD.md` 紀錄（含 cost estimate 實際值）

## 不在本 lab 範圍

- Standard 形態 cluster + node pool 調校（v2 lab）
- Connect Gateway / Fleet management（取代 IAP bastion 的 modern 方案，另一個 lab）
- Production-grade KSA→GSA 自動化（demo 階段手動 annotate；正式應 IaC 化）
- Cluster 升級策略（auto-upgrade / maintenance window 設定）
- Application 部署 IaC 化（Helm / Argo CD）
- 跨 region replica / multi-cluster
- 與 Lab SCC findings 整合（GKE security posture findings 是另一個 lab 主題）

## 後續 lab 預告

- **Lab 05c**：把 `terramate run -- tofu init/plan/apply` 包成 `terramate script`（含 GKE stack 在內，CI + 本機共用）
- **Lab 05d**（候選）：Catalyst components 把 network + gke 升級為 reusable blueprint
- **Lab 06**：實際新增 staging 環境（含 staging GKE，驗證 module + globals 的 multi-env reuse）
- **Lab 07**（候選）：Workload Identity IaC 化（KSA→GSA binding 透過 kubernetes provider 或 Config Connector）

## 開放問題（執行前需確認）

1. **master CIDR 是否要寫進 ADR？** 172.16.0.0/28 是 lab 一次性決策，未來 staging 要分配新 /28；建議寫一條 ADR 記錄 CIDR plan（本 lab 範圍外）。
2. **dev-vm kubectl 安裝丟 startup-script？** v1 走手動 apt install（vm stack 變更收斂）；v2（K8s 系列）再塞 startup-script。
3. **Phase G 之後 reapply 驗證 idempotency？** Lab 05a 沒做；GKE create 8min × 2 偏貴，建議跳過，evidence-pack 用單次 apply log 即可。
4. **dev-vm SA 未來 K8s lab 需要的權限怎麼擴？** 本 lab 只加 `container.developer` + `container.clusterViewer`；後續實驗用到 Artifact Registry、Cloud SQL 等再分次加 binding，避免一次給太寬。
