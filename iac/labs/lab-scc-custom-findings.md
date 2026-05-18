# Lab — SCC Custom Findings：unmanaged resource → SOC

> **狀態**：草稿／評估中，尚未排入執行計畫

## 目標

- 把「IaC 未管理的 GCP 資源」變成 SCC finding，讓 SOC 在既有平台看到
- 端到端打通：Asset Inventory 盤點 → diff Terraform state → 寫入 SCC Custom Findings

## 前置條件

- 既有 GCP lab project（沿用 bootstrap 已建立的 project）
- caller 有 `roles/securitycenter.admin`（建立 Source 需要，一次性操作後可撤銷）
- Terramate stacks 能正常跑 `plan` / `state list`
- Python 3.11+（PoC script 用）

> **啟用 tier 警告**：Console 啟用 SCC 時務必選 **project 層級 + Standard tier**。
> 不要點 Premium／Enterprise trial，Premium 是依 org 整體 GCP 月支出計費，有 annual commitment，誤啟後難退。

## 費用說明

| 元件 | 費用 |
|---|---|
| Cloud Asset Inventory API | 免費（search / export / feed） |
| SCC API enable | 免費 |
| SCC Standard tier（project 層級） | 免費 |
| SCC Premium / Enterprise | **付費，本 lab 不使用** |
| BigQuery export（若後續整合） | BQ 儲存／查詢計費，非 SCC 收費 |

## 架構概要

```
CI / local script
    │
    ├─ gcloud asset search-all-resources   → 實際資源清單
    ├─ terraform state list (per stack)    → IaC 管理清單
    │
    └─ diff → unmanaged list
                  │
                  └─ SCC Findings API POST → Custom Source
                                               │
                                           SOC 在 SCC Console 看到
```

## 步驟

### 1. 啟用 API

```bash
gcloud services enable securitycenter.googleapis.com \
  cloudasset.googleapis.com \
  --project=PROJECT_ID
```

### 2. 在 Console 啟用 SCC Standard tier（project 層級）

Security Command Center → Settings → 選擇 project 層級 → Standard → Activate

### 3. 建立 SCC Custom Source（一次性）

```bash
# 取得 org ID
ORG_ID=$(gcloud projects get-ancestors PROJECT_ID \
  --format='value(id)' | tail -1)

# 建立 custom source
gcloud scc sources create \
  --organization=$ORG_ID \
  --display-name="IaC Drift & Unmanaged" \
  --description="Resources not managed by Terramate/OpenTofu stacks"
# 記下 output 的 source name: organizations/ORG_ID/sources/SOURCE_ID
```

> 若沒有 org-level 權限，可改用 project-level source（目前 SCC v2 API 支援）：
> `gcloud scc sources create --project=PROJECT_ID ...`

### 4. 建立 finding-writer SA + IAM

```bash
# 建立 SA
gcloud iam service-accounts create scc-finding-writer \
  --display-name="SCC Finding Writer" \
  --project=PROJECT_ID

# 授予 findingsEditor on custom source
gcloud scc sources set-iam-policy organizations/ORG_ID/sources/SOURCE_ID \
  --policy=policy.json  # member: serviceAccount:scc-finding-writer@PROJECT_ID.iam.gserviceaccount.com
                        # role: roles/securitycenter.findingsEditor
```

CI 環境沿用 lab-04f 的 WIF 短期憑證模式，不建立 key。

### 5. PoC Script（Python）

```python
#!/usr/bin/env python3
"""
unmanaged_to_scc.py — Asset Inventory vs Terraform state diff → SCC findings
"""
import json
import subprocess
import uuid
from datetime import datetime, timezone

PROJECT_ID = "YOUR_PROJECT_ID"
ORG_ID = "YOUR_ORG_ID"
SOURCE_NAME = "organizations/ORG_ID/sources/SOURCE_ID"

# 白名單：合法的非 IaC 資源（GKE 自動建的 LB、default network 等）
ALLOWLIST_TYPES = {
    "compute.googleapis.com/ForwardingRule",  # GKE managed
    "compute.googleapis.com/BackendService",  # GKE managed
}

def get_asset_inventory():
    """撈 GCP 實際資源"""
    result = subprocess.run([
        "gcloud", "asset", "search-all-resources",
        f"--scope=projects/{PROJECT_ID}",
        "--format=json"
    ], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)

def get_terraform_managed():
    """從所有 stacks 收集 IaC 管理的 resource ID"""
    managed = set()
    # TODO: 走 terramate list 拿到所有 stack path，再對每個 stack 跑 tofu state list
    # 這裡先用 placeholder
    return managed

def post_finding(client, resource_name, asset_type):
    """寫一筆 finding 到 SCC"""
    finding_id = str(uuid.uuid4()).replace("-", "")
    now = datetime.now(timezone.utc).isoformat()
    finding = {
        "name": f"{SOURCE_NAME}/findings/{finding_id}",
        "resourceName": resource_name,
        "state": "ACTIVE",
        "category": "UNMANAGED_RESOURCE",
        "eventTime": now,
        "severity": "MEDIUM",
        "sourceProperties": {
            "assetType": asset_type,
            "detectedAt": now,
            "hint": "Not found in any Terramate stack state",
        },
    }
    # TODO: 使用 google-cloud-securitycenter SDK 寫入
    print(f"[DRY-RUN] Would post finding for {resource_name}")

def main():
    assets = get_asset_inventory()
    managed = get_terraform_managed()

    for asset in assets:
        asset_type = asset.get("assetType", "")
        resource_name = asset.get("name", "")

        if asset_type in ALLOWLIST_TYPES:
            continue
        if resource_name not in managed:
            post_finding(None, resource_name, asset_type)

if __name__ == "__main__":
    main()
```

### 6. 本地 Dry-run 驗證

1. 在 Console 手動建一個 test GCS bucket（不加入任何 stack）
2. 跑 script，確認 output 出現該 bucket 的 `[DRY-RUN]` 紀錄
3. 移除 dry-run flag，再跑一次
4. 到 SCC Console → Findings 確認看到 custom source 的 finding
5. 把 test bucket 刪除，下次跑 script 確認 finding 自動 mark INACTIVE

## 驗收標準（DoD）

- [ ] SCC Console 能看到至少一筆來自 custom source 的 finding
- [ ] Finding payload 含：GCP resource full name、發現時間、asset type
- [ ] 既有 IaC 管理的資源不會被誤報
- [ ] allowlist 機制擋掉 GKE 自動建的資源
- [ ] 手動把 unmanaged resource 納管後，下次跑 script finding 自動 INACTIVE

## 風險與決策點

| 風險 | 說明 | 緩解 |
|---|---|---|
| 誤報爆量 | Asset Inventory 拉到大量系統自建資源 | allowlist + 限定 asset type scope |
| Finding 重複 | 同一資源每次跑都建新 finding | 以 resource name hash 當 finding ID（idempotent） |
| Org-level 權限不足 | 沒有 org admin 建不了 org-level source | 改用 project-level source（SCC v2 支援） |
| SCC Premium 誤啟 | Console 操作不慎啟用付費 tier | 見上方啟用 tier 警告 |

## Cleanup（Lab 結束後）

```bash
# 1. 把所有 custom findings mark INACTIVE（或直接刪除 source）
# gcloud scc findings ... update --state=INACTIVE

# 2. 刪除 custom source
gcloud scc sources delete organizations/ORG_ID/sources/SOURCE_ID

# 3. 在 Console 關閉 SCC tier 啟用
# Security Command Center → Settings → Deactivate

# 4. 停用 API（如不再使用）
gcloud services disable securitycenter.googleapis.com
gcloud services disable cloudasset.googleapis.com \
  --project=PROJECT_ID
```

> `gcloud services disable` 不會刪資料，重新 enable 後 findings 仍在。

## 後續延伸（待評估）

- **lab-06b**：Cloud Logging structured log + BigQuery sink（SOC SQL 查詢）
- **lab-06c**：DuckDB + Parquet 時序快照（evidence pack 稽核用）
- **CI 整合**：把 script 加進 GitHub Actions daily cron，WIF 憑證短期化
