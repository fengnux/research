# IaC 工具鏈參考文件

## 工具選型

| 工具 | 用途 | 安裝方式 |
|------|------|---------|
| [tenv](https://github.com/tofuutils/tenv) | OpenTofu / Terramate 版本管理 | `brew install tenv` |
| [OpenTofu](https://opentofu.org) | IaC 主要工具（Terraform open-source fork）| `tenv tofu install latest` |
| [Terramate](https://terramate.io) | Stack 管理、變更偵測、程式碼生成 | `tenv tm install latest` |
| [Google Cloud SDK](https://cloud.google.com/sdk) | GCP 認證與資源操作 | `brew install --cask google-cloud-sdk` |

### 為何選擇 OpenTofu

HashiCorp 於 2023 年將 Terraform 授權從 MPL 2.0 改為 BSL 1.1（Business Source License），
限制競爭性商業使用，對於需要長期維護或商業化的專案存在授權風險。
OpenTofu 是由社群主導的 Terraform open-source fork（MPL 2.0），
由 Linux Foundation 下的 OpenTF Foundation 維護，確保長期開放性。

### 為何選擇 Terramate

單純使用 OpenTofu/Terraform 管理大型基礎設施時，常見的痛點：

- 所有資源放在同一個 state，任何變更都需要完整 plan/apply
- 多環境設定重複，難以保持 DRY
- 缺乏變更影響範圍的可視性

Terramate 解決這些問題的方式：

| 功能 | 說明 |
|------|------|
| **Stack 管理** | 將基礎設施切分為獨立單元，各自擁有獨立 state |
| **變更偵測** | 整合 git diff，只對有變更的 stack 執行 plan/apply，大幅縮短 CI 時間 |
| **程式碼生成** | 用 `generate_hcl` / `generate_file` 產生重複設定，避免 copy-paste |
| **執行協調** | 管理 stack 間依賴關係，確保正確的執行順序 |
| **Globals** | 跨 stack 共用設定（project ID、region 等），單點維護 |

### 為何選擇 tenv

tenv 單一工具即可管理 OpenTofu（`tenv tofu`）與 Terramate（`tenv tm`）的版本，
支援專案層級版本鎖定（`.opentofu-version`、`.terramate-version`），無需分別安裝 tfenv 等其他版本管理工具。

---

## 實驗環境

| 項目 | 值 |
|------|----|
| GCP 主要 Project | `fengnux` |
| GCP 實驗 Project | `research-lab` |
| 預設 Region | `asia-east1`（台灣）|
| State Backend | GCS bucket `research-lab-tofu-state`（位於 `research-lab`）|
| 本機認證 | 個人帳號 ADC（`gcloud auth application-default login`）|
| CI 認證（規劃中）| Service Account |

---

## tenv 設定

### GitHub Token（解決下載 rate limit）

安裝 OpenTofu / Terramate 時，tenv 從 GitHub Releases 下載，未認證的請求受 GitHub API rate limit 限制（60 req/hr），大量下載時容易觸發。

**解法：** 建立 Fine-grained Personal Access Token（唯讀、僅需 public repo 存取），設定於 shell profile：

```bash
# ~/.zshrc 或 ~/.bash_profile
export TENV_GITHUB_TOKEN="your_token_here"
```

> Token 建立位置：GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens

---

## 安裝過程紀錄

### tenv 可同時管理 OpenTofu 與 Terramate

原本預期 Terramate 需要透過 `brew install terramate` 單獨安裝，
實際測試後發現 tenv 已內建 `tenv tm` 子命令支援 Terramate 版本管理，
因此統一改用 tenv，移除 brew 安裝 Terramate 的步驟。

tenv 完整支援工具：

| 子命令 | 工具 |
|--------|------|
| `tenv tofu` | OpenTofu |
| `tenv tf` | Terraform |
| `tenv tg` | Terragrunt |
| `tenv tm` | Terramate |
| `tenv at` | Atmos |
