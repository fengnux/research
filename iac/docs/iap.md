# Cloud Identity-Aware Proxy（IAP）

## 什麼是 IAP

IAP（Identity-Aware Proxy）是 Google Cloud 的一層身份驗證閘道，放在 GCP 服務（HTTP 應用或 VM SSH/RDP）的前面，讓 Google 帳號身份（而非網路位置）決定誰能存取資源。

簡單說：**把「你在哪個網路」換成「你是誰」來做存取控制**。

---

## 原理

### 傳統做法：Bastion Host

```
Internet → Bastion Host（public IP）→ 內部 VM（private IP）
```

- Bastion 本身是攻擊面：要修補、要監控、要管 SSH key
- 存取控制靠防火牆 IP allowlist，難以細粒度控管到使用者層級

### IAP TCP Forwarding

```
本機（gcloud）→ HTTPS → IAP（Google Front End）→ 內部 VM:22
```

整個連線流程：

1. `gcloud compute ssh` 對 IAP endpoint 建立 HTTPS 連線（走 443）
2. IAP 驗證 Google 帳號身份（OAuth token）
3. IAP 查 IAM policy，確認帳號有 `roles/iap.tunnelResourceAccessor`
4. 驗證通過後，IAP 從自己的 IP 範圍（`35.235.240.0/20`）往 VM:22 建立 TCP tunnel
5. 本機 SSH client 透過這條 tunnel 與 VM 通訊

從 VM 的角度看，連線來自 `35.235.240.0/20`，所以防火牆只需要開放這段 source IP，完全不需要 public IP 或 bastion。

### 身份驗證層次

```
IAM Role Check（roles/iap.tunnelResourceAccessor）
    ↓ 通過
IAP TCP Tunnel 建立
    ↓
OS Login / SSH Key 驗證（OS 層）
    ↓ 通過
Shell
```

IAP 只管「能不能建 tunnel」，OS 層的身份驗證（OS Login 或 SSH key）是第二道。兩層各自獨立——IAP 通了但 OS 層拒絕，仍然進不去。

---

## IAP TCP Forwarding 的流量路徑

```
┌──────────────────────────────────────────────────────────────────┐
│                         Google Network                           │
│                                                                  │
│  ┌──────────────┐    HTTPS/443     ┌──────────────────────────┐  │
│  │  本機 gcloud  │ ──────────────▶ │  IAP (Google Front End)  │  │
│  └──────────────┘                 └────────────┬─────────────┘  │
│                                                │                 │
│                              35.235.240.0/20   │ TCP:22          │
│                                                ▼                 │
│                              ┌──────────────────────────────┐   │
│                              │  dev-vm（private IP only）    │   │
│                              │  tag: iap-ssh                │   │
│                              └──────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 優點

### 1. 不需要 public IP

VM 完全活在 private subnet，沒有對外攻擊面。Cloud NAT 管出網，IAP 管入網——兩者都不需要 VM 有 public IP。

### 2. 不需要 Bastion Host

省去 Bastion 的維運成本：
- 不需要另開一台 VM、付費、修補 OS
- 不需要管 Bastion 本身的 SSH key / 存取控制
- 不需要設 Bastion → 內網 VM 的第二層防火牆規則

### 3. 存取控制到使用者層級

IAM policy 可精確到：
- 特定帳號（`user:alice@example.com`）
- 特定群組（`group:dev-team@example.com`）
- 特定 VM（resource-level policy）

比 IP allowlist 更容易稽核、撤銷（移除 IAM binding 立即生效）。

### 4. 完整稽核日誌

每次 IAP tunnel 建立都寫進 Cloud Audit Logs（`cloudaudit.googleapis.com`），記錄：
- 誰（Google 帳號）
- 什麼時間
- 連到哪個 VM

不需要額外設 session logging。

### 5. 零信任網路模型

IAP 是 Google BeyondCorp 零信任架構的實現之一——網路位置（公司內網 / VPN）不再是信任依據，帳號身份 + context（device policy 等）才是。對個人 GCP lab 環境而言，等同於不需要 VPN 也能安全連進私有 VM。

---

## 本 Lab 的具體設定

### Firewall（lab-03b 建立）

```hcl
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "allow-iap-ssh"
  network = google_compute_network.vpc.self_link

  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]   # IAP TCP forwarding IP range
  target_tags   = ["iap-ssh"]           # 只套用到有此 tag 的 VM
}
```

`35.235.240.0/20` 是 Google 公開的 IAP TCP forwarding 出口 IP 段，固定不變。

### VM（lab-03c 建立）

```hcl
resource "google_compute_instance" "dev_vm" {
  tags = ["iap-ssh"]   # attach 此 tag → 受 allow-iap-ssh 保護

  network_interface {
    # 無 access_config → 無 public IP
  }

  metadata = {
    enable-oslogin = "TRUE"   # OS 層用 IAM 身份，不用管 SSH key
  }
}
```

### 連線指令

```bash
# 直接開 SSH session（gcloud 自動走 IAP tunnel）
gcloud compute ssh dev-vm \
  --project research-lab-495809 \
  --zone asia-east1-b

# 只建 tunnel（本機 port 轉發，供其他工具使用）
gcloud compute ssh dev-vm \
  --project research-lab-495809 \
  --zone asia-east1-b \
  --tunnel-only \
  -- -L 8080:localhost:8080 -N
```

### 所需 IAM

| Role | 用途 |
|------|------|
| `roles/iap.tunnelResourceAccessor` | 允許建立 IAP TCP tunnel |
| `roles/compute.osLogin` | OS Login — 以 Google 帳號身份登入 OS |
| `roles/compute.instanceAdmin.v1` | 建立 / 刪除 VM（本 lab 的 tofu 操作用） |

---

## 與其他連線方式的比較

| 方式 | 需要 public IP | 需要 Bastion | 存取控制粒度 | 稽核日誌 |
|------|---------------|-------------|-------------|----------|
| 直接 SSH（public IP） | ✅ | ✗ | IP allowlist | 需自建 |
| Bastion Host | ✅（Bastion） | ✅ | IP + SSH key | 需自建 |
| VPN + 內網 SSH | ✗ | ✗ | VPN 帳號 | 需自建 |
| **IAP TCP Forwarding** | **✗** | **✗** | **IAM 帳號層級** | **Cloud Audit Logs** |

---

## 延伸閱讀

- [IAP TCP forwarding 官方文件](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [BeyondCorp Enterprise 概述](https://cloud.google.com/beyondcorp-enterprise/docs/overview)
- [IAP 出口 IP 範圍](https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule)
