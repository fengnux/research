# IaC 工具鏈參考文件

## 工具選型

| 工具 | 版本 | 用途 | 安裝方式 |
|------|------|------|---------|
| [tenv](https://github.com/tofuutils/tenv) | 4.12.2 | OpenTofu / Terramate 版本管理 | `brew install tenv` |
| [OpenTofu](https://opentofu.org) | 1.11.6 | IaC 主要工具（Terraform open-source fork）| `tenv tofu install latest` |
| [Terramate](https://terramate.io) | 0.17.0 | Stack 管理、變更偵測、程式碼生成 | `tenv tm install latest` |
| [Google Cloud SDK](https://cloud.google.com/sdk) | 567.0.0 | GCP 認證與資源操作 | `brew install --cask google-cloud-sdk` |

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

#### 與 Terragrunt 的比較

Terragrunt（Gruntwork，2016 起）是同類工具中歷史最久、社群最大的選項。兩者都能解決上述痛點，但在「設定如何被組織與呈現」上採取不同哲學。

| 構面 | Terragrunt | Terramate |
|------|-----------|-----------|
| DRY 機制 | `include` 鏈 + `inputs` 合併，多層繼承 | `globals` 繼承 + `generate_hcl` 產出 `.tf` 檔 |
| 最終設定可見性 | 在 `.terragrunt-cache/` 內動態合成，**不進 git** | 生成檔寫進 stack 目錄並 commit，**PR diff 直接可見** |
| 跨 stack 依賴 | `dependency` block 可直接讀其他 stack output | 靠目錄階層自然排序；跨樹依賴用 `after`；output 傳遞較弱 |
| 變更偵測 | 無內建，靠 wrapper script / CI 自製 | 內建 `terramate list --changed`，git-aware |
| 成熟度 | 2016 起，社群大、案例多 | 2022 起，較新；CI 整合與「設定可見性」是亮點 |

**本專案選 Terramate 的核心原因**：偏好「最終生成設定看得見、commit 在 repo 內」的工作流。

Terragrunt 的 `include` 繼承雖然 DRY，但讀一個葉節點 stack 常需要往上追 2–3 層 `terragrunt.hcl`，再去 `.terragrunt-cache/` 看合成結果才能完整理解該 stack 實際會 apply 什麼。Terramate 的 `generate_hcl` 輸出直接寫在 stack 目錄下並 commit（如 `_terramate_backend.tf`、`_terramate_provider.tf`），PR review 看到的就是 OpenTofu 真正執行的內容，認知成本較低。

代價是：跨 stack output 傳遞、社群案例量目前不如 Terragrunt 成熟，需自行驗證踩過再用。

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

## 版本鎖定的三層機制

OpenTofu / Terramate 工作流中有三種獨立的「版本鎖定」概念，常被混淆。

| 層 | 設定方式 | 作用對象 | 強制者 | 用途 |
|----|----------|----------|--------|------|
| **CLI 切換** | `.opentofu-version`、`.terramate-version` | tenv 應呼叫哪個 binary | tenv | 同一台機器多版本切換 |
| **工具版本約束** | `terraform { required_version = ">= 1.11.0" }` | OpenTofu 自己拒絕版本不符 | OpenTofu | 防止用太舊 / 未驗證版本執行 |
| **Provider 版本約束** | `required_providers { google = { version = "~> 7.31.0" } }` | 限制 provider 版本範圍 | OpenTofu | 鎖至 minor 內 patch（拒絕 7.32+） |
| **Provider 確切鎖定** | `.terraform.lock.hcl` | 鎖到 patch 版本與 hash | OpenTofu | 確保所有人 / CI 用一模一樣的 provider |

**本專案的選擇：**

統一規則：所有版本約束採 `~> X.Y.Z` 形式（minor pin），只允許 patch 升級。原因：本 repo 對外公開，需避免「`~> 7.0` 含整個 7.x」這類解讀模糊；同時保留 patch 升級的彈性以接收安全更新。

| 對象 | 約束位置 | 寫法 | 允許範圍 |
|------|----------|------|----------|
| Terramate | `terramate.tm.hcl` 的 `required_version` | `~> 0.17.0` | 0.17.x |
| OpenTofu | `globals "tofu"` 內 `required_version`，由 `generate_hcl` 注入 | `~> 1.11.6` | 1.11.x |
| google provider | `globals "tofu"` 內 `google_provider`，由 `generate_hcl` 注入 | `~> 7.31.0` | 7.31.x |

**lock file 政策：**

- `.terraform.lock.hcl` **必須 commit**（提供 provider 確切版本與 hash 的可重現性）
- Terramate 沒有對等 lock file 機制，靠 `required_version` 收緊到 minor 即是目前能做到的最強約束
- 不使用 `.opentofu-version` / `.terramate-version`（避免 tenv 切換與 code 內版本約束混淆）

**升級流程：**

1. 改 `globals` 中的版本字串（例如 `~> 7.31.0` → `~> 7.32.0`）
2. `terramate generate` 同步生成檔
3. `tofu init -upgrade` 更新 lock file
4. Commit code 與 lock file 一起 review

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
