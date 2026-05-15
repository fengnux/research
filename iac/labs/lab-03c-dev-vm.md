# Lab 03c - 第一個 dev Compute VM（IAP SSH + NAT 出網驗證）

## 目標

在 `stacks/dev/vm/` 建立一台私有 VM（無 public IP），驗證 lab-03b 建好的網路基礎設施實際可用：

1. IAP SSH 可連入（透過 `allow-iap-ssh` firewall + `iap-ssh` tag）
2. Cloud NAT 可出網（VM 內 `curl` 能打到外部）
3. 實驗完成後 destroy VM 資源（避免持續計費），network / apis stack 保留

## 前置條件

- 完成 [Lab 03b](lab-03b-first-dev-stack.md)（dev-vpc、dev-subnet-asia-east1、allow-iap-ssh、dev-nat 均已 apply）
- 個人 ADC 對 `research-lab-495809` 有以下 role：
  - `roles/compute.instanceAdmin.v1`（建立 / 刪除 VM）
  - `roles/iap.tunnelResourceAccessor`（IAP TCP forwarding）
- `gcloud` 已登入同一帳號

---

## 設計重點

### 無 public IP + IAP SSH

VM 的 `network_interface` 不加 `access_config` block，GCP 不配發 external IP。SSH 流量走 IAP TCP forwarding（原理詳見 [docs/iap.md](../../docs/iap.md)）：

```
本機 → IAP（35.235.240.0/20）→ allow-iap-ssh firewall → VM:22
```

`gcloud compute ssh` 會自動透過 IAP 建立 tunnel，使用者不需手動管理 bastion。

### OS Login

VM metadata 設 `enable-oslogin = "TRUE"`，讓 gcloud 以 IAM 身份登入，不需手動管理 `~/.ssh/authorized_keys`。這需要 `iap.googleapis.com` 啟用（本 lab 補進 apis stack）。

### Stack 依賴

```
/stacks/dev/apis
  ↓
/stacks/dev/network
  ↓
/stacks/dev/vm          ← after = ["/stacks/dev/network"]
```

vm stack 只依賴 network（需要 VPC / subnet 存在），apis 已透過 network 的 `after` 傳遞排序。

### 費用控制

| 資源 | 計費方式 | 本 lab 處置 |
|------|----------|-------------|
| `e2-micro` VM | 依執行時間（~$0.007/hr） | 實驗後 destroy |
| Cloud NAT | 依處理流量 + 固定費用（小流量極低） | 保留（後續 lab 依賴） |
| GCS state object | 極低 | 保留（紀錄用） |

---

## 步驟

### 1. 更新 `stacks/dev/apis/main.tf`

補加 `iap.googleapis.com`（OS Login 需要）。注意現有 resource 命名是 `google_project_service.this`、local 名稱是 `enabled_apis`，不需加 `project`（provider 層已設定）：

```hcl
locals {
  enabled_apis = [
    "compute.googleapis.com",
    "iap.googleapis.com",   # ← 新增
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.enabled_apis)

  service            = each.value
  disable_on_destroy = false
}
```

### 2. 建立 `stacks/dev/vm/`

#### 2.1 `stack.tm.hcl`

```hcl
stack {
  id          = "vm"
  name        = "vm"
  description = "實驗用 dev VM（IAP SSH + NAT 驗證，實驗後 destroy）"
  tags        = ["dev", "vm"]
  after       = ["/stacks/dev/network"]
}
```

#### 2.2 `locals.tm.hcl`（Terramate globals → HCL locals）

`.tf` 檔無法直接讀取 Terramate globals，需透過 `generate_hcl` 橋接。subnetwork 路徑需要 project ID，因此在 stack 內建一個 `locals.tm.hcl`：

```hcl
generate_hcl "_terramate_locals.tf" {
  content {
    locals {
      project_id = global.gcp.lab_project
    }
  }
}
```

`terramate generate` 後會產出 `_terramate_locals.tf`，`main.tf` 即可使用 `local.project_id`。

#### 2.3 `main.tf`

```hcl
resource "google_compute_instance" "dev_vm" {
  name         = "dev-vm"
  machine_type = "e2-micro"
  zone         = "asia-east1-b"

  tags = ["iap-ssh"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = "dev-vpc"
    subnetwork = "projects/${local.project_id}/regions/asia-east1/subnetworks/dev-subnet-asia-east1"
    # access_config 不加 → 無 public IP
  }

  metadata = {
    enable-oslogin = "TRUE"
  }
}
```

> `project` 欄位不需填寫——`_terramate_provider.tf` 已由 `generate_hcl` 注入 `project = global.gcp.lab_project`，provider 層統一管理。

#### 2.4 `outputs.tf`

```hcl
output "instance_name" {
  value = google_compute_instance.dev_vm.name
}

output "instance_zone" {
  value = google_compute_instance.dev_vm.zone
}
```

### 3. Generate 並驗收產出

```bash
cd ~/GitHub/tofu-terramate-lab
terramate generate
```

確認新增：
- `stacks/dev/vm/_terramate_backend.tf`（prefix = `dev/vm`）
- `stacks/dev/vm/_terramate_provider.tf`
- `stacks/dev/vm/_terramate_locals.tf`（`local.project_id = "research-lab-495809"`）

### 4. Commit

```bash
git add stacks/dev/apis/main.tf stacks/dev/vm/
git commit -m "feat(dev): add vm stack + iap api"
```

### 5. Apply apis stack（補啟用 iap.googleapis.com）

```bash
terramate run --tags apis -- tofu init
terramate run --tags apis -- tofu plan
terramate run --tags apis -- tofu apply
```

預期：`iap.googleapis.com` 新增 1 個 resource，其餘 no-op。

### 6. Apply vm stack

```bash
terramate run --tags vm -- tofu init
terramate run --tags vm -- tofu plan
terramate run --tags vm -- tofu apply
```

預期：`google_compute_instance.dev_vm` 新增 1 個 resource。

### 7. 驗證 IAP SSH

```bash
gcloud compute ssh dev-vm \
  --project research-lab-495809 \
  --zone asia-east1-b \
  --tunnel-only &

# 或直接開 shell：
gcloud compute ssh dev-vm \
  --project research-lab-495809 \
  --zone asia-east1-b
```

### 8. 驗證 NAT 出網（在 VM 內執行）

```bash
curl -s ifconfig.me   # 應回傳 GCP NAT IP（非 VM 內網 IP）
curl -s google.com    # 應成功
```

### 9. 實驗結束：Destroy VM

```bash
# 退出 VM shell 後，回到本機
cd ~/GitHub/tofu-terramate-lab
terramate run --tags vm -- tofu destroy
```

確認 GCP 無殘留：

```bash
gcloud compute instances list --project research-lab-495809
# 預期：空列表（或無 dev-vm）
```

---

## 驗證清單

- [ ] `terramate list --run-order` 中 `dev/vm` 排在 `dev/network` 之後
- [ ] `gsutil ls gs://research-lab-495809-tofu-state/dev/vm/default.tfstate` 存在
- [ ] `gcloud services list --enabled --project research-lab-495809 | grep iap` 顯示已啟用
- [ ] `gcloud compute instances describe dev-vm --zone asia-east1-b --project research-lab-495809` 顯示無 `networkInterfaces[].accessConfigs`（無 public IP）
- [ ] IAP SSH 可連入
- [ ] VM 內 `curl -s ifconfig.me` 回傳 NAT IP（非內網 IP）
- [ ] destroy 後 `gcloud compute instances list` 無 `dev-vm`
- [ ] `terramate run --tags vm -- tofu plan` 在 destroy 後顯示 1 個 resource 待建（state 留存、實體已移除）

---

## 風險與回退

- **IAP SSH 失敗（permission denied）**：確認 ADC 帳號有 `roles/iap.tunnelResourceAccessor`；若缺可 `gcloud projects add-iam-policy-binding research-lab-495809 --member="user:<email>" --role="roles/iap.tunnelResourceAccessor"`
- **OS Login 拒絕登入**：確認 ADC 帳號有 `roles/compute.osLogin`；或改把 `enable-oslogin` 移除、改用 gcloud 自動注入 SSH key（metadata-based）
- **`iap.googleapis.com` apply 失敗**：確認 ADC 有 `roles/serviceusage.serviceUsageAdmin`
- **忘記 destroy**：VM 計費約 $0.007/hr；若不確定是否已 destroy，`gcloud compute instances list --project research-lab-495809` 確認

---

## 下一步

- Lab 04：CI Pipeline（GitHub Actions + Workload Identity Federation + Terramate `--changed`）
