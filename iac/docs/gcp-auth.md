# GCP 認證與專案管理

本文件說明本專案的 GCP 認證選擇、跨專案管理方式、與未來上 CI 的規劃。

---

## 帳號與 Project

| 項目 | 值 |
|------|----|
| 個人主要 Project | `fengnux-1168` |
| 實驗 Project | `research-lab-495809` |
| 個人帳號 | `fengnux@gmail.com` |
| 本機認證方式 | 個人帳號 ADC |

> Project ID 全球唯一。建立時若名稱被佔用，console 會自動加數字後綴
> （例如 `research-lab` → `research-lab-495809`）。所有設定要用實際 ID，**不能用顯示名稱**。

---

## ADC vs Service Account：兩種跨專案管理模式

### 模式 A：個人 ADC 直接操作（目前採用）

```
fengnux@gmail.com (Personal ADC)
        │
        ├── 預設 project = fengnux-1168 (gcloud default)
        └── OpenTofu 操作 = research-lab-495809 (provider config)
```

**前提：** 個人帳號在 `research-lab-495809` 有足夠 IAM 角色（owner / editor）。

**優點：** 設定最少，本機開發直觀。
**限制：** 無法用於 CI；多人協作時 audit log 看不到「誰透過自動化做了什麼」。

### 模式 B：Service Account 模式（CI 規劃）

```
GitHub Actions
        │
        └── impersonate SA: tofu-runner@fengnux-1168.iam.gserviceaccount.com
                │
                └── grant: roles/storage.admin in research-lab-495809
                            roles/<...> in research-lab-495809
```

**前提：** 在 management project（`fengnux-1168` 或專用的 `*-mgmt`）建立 SA，
在實驗 project 授予 SA 必要角色。CI 透過 Workload Identity Federation 取得短期憑證。

**優點：** 可用於 CI、權限可細分、audit log 可追蹤。
**成本：** 建立流程較複雜，需要管理 SA 生命週期。

**未來規劃：** 上 CI 時改 B；本機開發仍維持 A。

---

## gcloud 預設 project ≠ OpenTofu target project

最常見的混淆：以為要 `gcloud config set project research-lab-495809` 才能讓 OpenTofu 操作該 project。**不需要。**

| 機制 | 設定位置 | 影響 |
|------|----------|------|
| gcloud 預設 project | `gcloud config set project ...` | 只影響 `gcloud` CLI 不帶 `--project` 時的目標 |
| ADC 憑證 | `~/.config/gcloud/application_default_credentials.json` | 提供「身份」，跟 project 無關 |
| OpenTofu target | `provider "google" { project = ... }` | 真正決定 OpenTofu 操作哪個 project |

**結論：** 本機 gcloud 維持 `fengnux-1168` 沒問題，OpenTofu 仍會透過 provider 設定操作 `research-lab-495809`。

---

## 必要 API 啟用

每個 GCP project 預設沒啟用任何服務 API，需手動或用 IaC 開啟。

本 project 目前已啟用：

| API | 用途 |
|-----|------|
| `cloudresourcemanager.googleapis.com` | 讀取 / 修改 project metadata、IAM |
| `storage.googleapis.com` | GCS（state bucket） |

新增資源類型前先啟用對應 API（例如 GKE 要 `container.googleapis.com`）。
未來可考慮用獨立 stack（`stacks/dev/services/`）統一管理 API 啟用，避免散落各處。

---

## IAM 角色查詢

```bash
# 個人帳號在某 project 的角色
gcloud projects get-iam-policy research-lab-495809 \
  --flatten="bindings[].members" \
  --filter="bindings.members:user:fengnux@gmail.com" \
  --format="table(bindings.role)"
```

> 若回傳 `permission denied`，通常是 project 不存在、或帳號連 `getIamPolicy` 都沒有
> （需要 `resourcemanager.projects.getIamPolicy`，包含在 owner / viewer 角色內）。

---

## 認證疑難排解

| 症狀 | 可能原因 | 處理 |
|------|----------|------|
| `does not have permission` 但確實有角色 | ADC 未更新、token 過期 | `gcloud auth application-default login` |
| OpenTofu 用到錯的 project | provider 區塊沒設 `project` | 檢查 `_terramate_provider.tf` 是否從 globals 帶入 |
| `Cloud Resource Manager API has not been used...` | 未啟用 API | `gcloud services enable cloudresourcemanager.googleapis.com` |
| 想暫時切到別的帳號 | 多帳號需求 | `gcloud auth application-default login --account=...` 或 `CLOUDSDK_ACTIVE_CONFIG_NAME` |
