# Lab 03b - 建立第一個 dev stack：APIs + Network

## 目標

在 `stacks/dev/` 底下建立兩個實際管理 GCP 資源的 stack，讓後續所有 dev lab（VM / GKE / Cloud SQL 等）都有依賴根可掛：

1. **`stacks/dev/apis`** — 用 `google_project_service` 集中管理 dev project 啟用的 GCP API
2. **`stacks/dev/network`** — VPC、subnet（含 GKE 用 secondary ranges）、IAP SSH firewall、Cloud NAT

順便驗證 [Lab 03a](lab-03a-state-migration.md) 在 root 寫的 `_terramate_backend.tf` / `_terramate_provider.tf` 自動生成邏輯，在多 stack 巢狀路徑下會正確產出 `dev/apis` 與 `dev/network` 兩段不同的 GCS prefix。

## 前置條件

- 完成 [Lab 03a](lab-03a-state-migration.md)
- 個人 ADC 對 `research-lab-495809` 至少有 `roles/serviceusage.serviceUsageAdmin`、`roles/compute.networkAdmin`、`roles/compute.securityAdmin`
- `stacks/dev/globals.tm.hcl` 已存在（定義 `global.env.name = "dev"`、`global.env.project`）

---

## 設計重點

### 為什麼把 APIs 拆成獨立 stack

`google_project_service` 是「啟用 API」的宣告。把它與消費它的資源（VPC / GKE / Cloud SQL...）放同一個 stack，會讓「加一個新服務」變成「在不同資源 stack 裡各自加一行 API」，散在多處難管。

獨立成 `stacks/dev/apis` 有三個好處：

- 加新 API 改一個檔
- 其他 stack 用 `after = ["/stacks/dev/apis"]` 表達依賴，順序由 Terramate 保證
- `disable_on_destroy = false` 統一設定（避免 `tofu destroy` 把整個 project 的 API 關掉）

### CIDR 規劃

dev VPC 在 `10.0.0.0/8` 內保留 `10.10.0.0` ~ `10.31.255.255` 區段：

| 用途 | CIDR | 大小 | 說明 |
|------|------|------|------|
| Subnet primary（節點 / VM） | `10.10.0.0/20` | 4096 | asia-east1 |
| Secondary `pods`（GKE alias IP） | `10.20.0.0/14` | 262144 | 預留：GKE VPC-native 需要 |
| Secondary `services`（GKE ClusterIP） | `10.30.0.0/20` | 4096 | 預留：GKE VPC-native 需要 |

> **GKE secondary ranges 是 VPC-native 模式（現行預設）的必要條件**——cluster 建立時必須指定。技術上可以等 GKE lab 再 in-place 加到 subnet 上，但本 lab 一次寫好，未來 GKE lab 不必回頭改 network stack。

### 防火牆策略

GCP 預設 implicit deny ingress / 預設 allow egress（除非明確 deny）。本 lab 只加一條 ingress allow rule：

| Rule | 方向 | Source | Port | Target tag | 用途 |
|------|------|--------|------|------------|------|
| `allow-iap-ssh` | INGRESS | `35.235.240.0/20`（IAP TCP forwarding） | tcp:22 | `iap-ssh` | 私有 VM 經 IAP SSH 進去 |

VM 只有 attach `iap-ssh` tag 才接受這條，避免「全 VPC 任何 VM 都能被 SSH」。

### Cloud NAT 配置

| 屬性 | 值 |
|------|----|
| Router | `dev-nat-router` @ asia-east1 |
| NAT IP allocate | `AUTO_ONLY`（GCP 自動配發 ephemeral） |
| Source ranges | `ALL_SUBNETWORKS_ALL_IP_RANGES` |
| Logging | `ERRORS_ONLY`（避免 dev 噪音 / 費用） |

---

## 步驟

### 1. 建立 `stacks/dev/apis/`

#### 1.1 寫 `stack.tm.hcl`

```hcl
stack {
  id          = "apis"
  name        = "apis"
  description = "啟用 dev project 需要的 GCP API"
  tags        = ["dev", "apis"]
}
```

#### 1.2 寫 `main.tf`

```hcl
locals {
  enabled_apis = [
    "compute.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.enabled_apis)

  project = var.project
  service = each.value

  disable_on_destroy = false
  disable_dependent_services = false
}

variable "project" {
  type    = string
  default = null  # 由 generate.tm.hcl 注入的 provider 帶入
}
```

> 註：`google_project_service` 的 `project` 可以省略，會走 provider 預設。明寫成 variable 是為日後若 `google_project_service` 要管多 project 時不用大改。本 lab 預設保留 null，吃 provider 帶入的 `global.gcp.lab_project`。

實務上更簡單的版本可以完全省略 `project` 與 variable：

```hcl
resource "google_project_service" "this" {
  for_each           = toset(local.enabled_apis)
  service            = each.value
  disable_on_destroy = false
}
```

採用哪個寫法看個人偏好。Lab 預設用後者（簡潔）。

#### 1.3 寫 `outputs.tf`

```hcl
output "enabled_apis" {
  value = [for s in google_project_service.this : s.service]
}
```

#### 1.4 generate + 看 diff + commit

```bash
cd ~/GitHub/tofu-terramate-hcl
terramate generate
git status
```

預期 `stacks/dev/apis/` 多出三個 `_terramate_*.tf`，其中 `_terramate_backend.tf` 的 prefix 應為 `dev/apis`：

```hcl
backend "gcs" {
  bucket = "research-lab-495809-tofu-state"
  prefix = "dev/apis"
}
```

```bash
git add stacks/dev/apis/
git commit -m "feat(dev/apis): 啟用 compute API"
git push
```

#### 1.5 init / plan / apply

```bash
terramate run --tags apis -- tofu init
terramate run --tags apis -- tofu plan
terramate run --tags apis -- tofu apply
```

預期 plan 看到 1 個 add（`google_project_service.this["compute.googleapis.com"]`）。

### 2. 建立 `stacks/dev/network/`

#### 2.1 寫 `stack.tm.hcl`

```hcl
stack {
  id          = "network"
  name        = "network"
  description = "dev VPC、subnet（含 GKE secondary ranges）、IAP SSH firewall、Cloud NAT"
  tags        = ["dev", "network"]
  after       = ["/stacks/dev/apis"]
}
```

#### 2.2 寫 `main.tf`

```hcl
locals {
  vpc_name    = "dev-vpc"
  subnet_name = "dev-subnet-asia-east1"

  pods_range_name     = "dev-pods"
  services_range_name = "dev-services"

  cidr_primary  = "10.10.0.0/20"
  cidr_pods     = "10.20.0.0/14"
  cidr_services = "10.30.0.0/20"

  iap_source_range = "35.235.240.0/20"
}

resource "google_compute_network" "vpc" {
  name                    = local.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  description             = "dev shared VPC（lab 環境）"
}

resource "google_compute_subnetwork" "primary" {
  name          = local.subnet_name
  network       = google_compute_network.vpc.id
  region        = "asia-east1"
  ip_cidr_range = local.cidr_primary

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = local.cidr_pods
  }

  secondary_ip_range {
    range_name    = local.services_range_name
    ip_cidr_range = local.cidr_services
  }
}

resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "allow-iap-ssh"
  network = google_compute_network.vpc.name

  direction     = "INGRESS"
  source_ranges = [local.iap_source_range]
  target_tags   = ["iap-ssh"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  description = "允許 IAP TCP forwarding 從 35.235.240.0/20 對 tag=iap-ssh 的 VM 做 SSH"
}

resource "google_compute_router" "nat" {
  name    = "dev-nat-router"
  region  = "asia-east1"
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "dev-nat"
  router                             = google_compute_router.nat.name
  region                             = "asia-east1"
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

#### 2.3 寫 `outputs.tf`

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
  description = "GKE alias IP range (pods)，未來 GKE lab 會用"
  value       = google_compute_subnetwork.primary.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "GKE alias IP range (services)，未來 GKE lab 會用"
  value       = google_compute_subnetwork.primary.secondary_ip_range[1].range_name
}
```

#### 2.4 generate + diff + commit

```bash
terramate generate
git status
```

預期 `stacks/dev/network/_terramate_backend.tf` 的 prefix = `dev/network`。

```bash
git add stacks/dev/network/
git commit -m "feat(dev/network): VPC + subnet + IAP SSH + Cloud NAT"
git push
```

#### 2.5 確認 run order

```bash
terramate list --run-order
```

預期 `apis` 在 `network` 之前：

```
stacks/bootstrap
stacks/dev/apis
stacks/dev/network
```

#### 2.6 init / plan / apply

```bash
terramate run --tags network -- tofu init
terramate run --tags network -- tofu plan
terramate run --tags network -- tofu apply
```

預期 plan 看到 5 個 add：network、subnetwork、firewall、router、router_nat。

---

## 驗證清單

- [ ] `terramate list --run-order` 中 `dev/apis` 排在 `dev/network` 之前
- [ ] `gsutil ls gs://research-lab-495809-tofu-state/dev/apis/default.tfstate`
- [ ] `gsutil ls gs://research-lab-495809-tofu-state/dev/network/default.tfstate`
- [ ] `gcloud services list --enabled --project research-lab-495809 | grep compute.googleapis.com`
- [ ] `gcloud compute networks describe dev-vpc --project research-lab-495809` 顯示 `routingMode: GLOBAL`、`autoCreateSubnetworks: false`
- [ ] `gcloud compute networks subnets describe dev-subnet-asia-east1 --region asia-east1 --project research-lab-495809` 顯示兩個 `secondaryIpRanges`（dev-pods、dev-services）與 `privateIpGoogleAccess: true`
- [ ] `gcloud compute firewall-rules describe allow-iap-ssh --project research-lab-495809` 顯示 source `35.235.240.0/20`、target tag `iap-ssh`、allow tcp:22
- [ ] `gcloud compute routers nats describe dev-nat --router dev-nat-router --region asia-east1 --project research-lab-495809` 顯示 `sourceSubnetworkIpRangesToNat: ALL_SUBNETWORKS_ALL_IP_RANGES`、`natIpAllocateOption: AUTO_ONLY`
- [ ] `terramate run --tags apis -- tofu plan` 與 `--tags network -- tofu plan` 都顯示 no changes
- [ ] `terramate generate --detailed-exit-code` exit code = 0（無漂移）
- [ ] 兩個 stack 各自的 commit 已 push 至 `tofu-terramate-hcl` 主分支

---

## 風險與回退

- **API enable 卡 quota / 權限**：`serviceusage.googleapis.com` 必須在 project 上先可用（GCP 預設啟用）。若 ADC 帳號權限不足，先在 GCP Console 手動 enable Compute API 再 import 即可。
- **Subnet CIDR 衝突**：dev 環境目前還沒其他 VPC，直接用本 lab 規劃的 CIDR。若日後加 peering，重看 [docs/networking.md] 規劃表。
- **destroy 順序**：必須 `network` 先於 `apis`（resource dependency 之外，邏輯上也是先拆網路再關 API）。`tofu destroy` 對單 stack 沒問題；跨 stack 時用 `terramate run --tags network -- tofu destroy` 然後 `--tags apis`。
- **誤把 `disable_on_destroy = true` 設下去**：未來 destroy `apis` stack 會把 compute API 從整個 project 關掉，影響任何用此 project 的東西。本 lab 已設 `false`。
- **Cloud NAT 出現異常費用**：dev 環境流量小應可忽略；若放久不用，可單獨 destroy `google_compute_router_nat.nat` 與 router 即可（VPC / subnet 保留）。

---

## 下一步

- Lab 03c：第一個 Compute VM（驗證 IAP SSH + NAT 出網）
- Lab 04 系列：CI Pipeline（GitHub Actions + WIF + Terramate `--changed`）
