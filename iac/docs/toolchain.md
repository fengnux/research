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

OpenTofu / Terramate 工作流中有幾種獨立的「版本鎖定」概念，常被混淆。它們解決的是不同問題，不能只靠其中一層取代全部。

| 層 | 設定方式 | 作用對象 | 強制者 | 用途 |
|----|----------|----------|--------|------|
| **CLI 切換** | `.opentofu-version`、`.terramate-version` | tenv 應呼叫哪個 binary | tenv | 同一台機器多版本切換 |
| **工具版本約束** | `terraform { required_version = ">= 1.11.0" }` | OpenTofu 自己拒絕版本不符 | OpenTofu | 防止用太舊 / 未驗證版本執行 |
| **Provider 版本約束** | `required_providers { google = { version = "~> 7.31.0" } }` | 限制 provider 版本範圍 | OpenTofu | 鎖至 minor 內 patch（拒絕 7.32+） |
| **Provider 確切鎖定** | `.terraform.lock.hcl` | 鎖到 patch 版本與 hash | OpenTofu | 確保所有人 / CI 用一模一樣的 provider |

**本專案的選擇：**

版本鎖定採分層策略：

1. **CLI 工具用 tenv exact pin**：用 `.opentofu-version`、`.terramate-version` 指定本 repo 預期使用的實際 CLI 版本。
2. **工具 runtime guard 保留 `~> X.Y.Z`**：OpenTofu / Terramate 自己仍用 `required_version` 檢查版本是否落在已驗證的 patch line。
3. **Provider 只用 constraint，不 commit lock file**：`required_providers` 在 globals 內統一管理；`.terraform.lock.hcl` 由 `.gitignore` 排除（Terramate 官方做法，見下節）。

這樣分工後，tenv 負責「選哪個 binary」，OpenTofu / Terramate 負責「拒絕未驗證版本」，provider constraint 負責「可重現的版本範圍」。

| 對象 | 約束位置 | 寫法 | 允許範圍 |
|------|----------|------|----------|
| OpenTofu CLI | `.opentofu-version` | `1.11.6` | exactly 1.11.6 |
| Terramate CLI | `.terramate-version` | `0.17.0` | exactly 0.17.0 |
| Terramate | `terramate.tm.hcl` 的 `required_version` | `~> 0.17.0` | 0.17.x |
| OpenTofu | `globals "tofu"` 內 `required_version`，由 `generate_hcl` 注入 | `~> 1.11.6` | 1.11.x |
| google provider | `globals "tofu"` 內 `google_provider`，由 `generate_hcl` 注入 | `~> 7.31.0` | 7.31.x |
| Provider lock file | `.terraform.lock.hcl` | **gitignore，不入 repo** | n/a |

### Provider Lock File 政策

Terramate 官方範例（[terramate-github-actions-example](https://github.com/terramate-io/terramate-github-actions-example)）的 `.gitignore` 將 `.terraform.lock.hcl` 排除掉，本專案沿用此做法。理由：

- **跨平台 hash 衝突**：本機 init 在 macOS（`darwin_arm64`），CI 在 Linux runner（`linux_amd64`）會自動補上新平台的 hash 到 lock file，造成 working tree 變 dirty。
- **Terramate git-clean 安全閥**：`terramate run` 預設拒絕 uncommitted / untracked 檔案；若 lock file 被 CI 修改，後續 step 會 fail。
- **改善方案的代價**：在 CI 加 `--disable-safeguards=git-uncommitted` 治標不治本；以 `tofu providers lock -platform=...` 預錄多平台 hash 又增加維護負擔。

**lock file 政策：**

- `.terraform.lock.hcl` 列入 `.gitignore`，不入 repo
- Provider 版本可重現性由 `globals "tofu"` 內的 constraint（`~> 7.31.0`）負責
- Provider 升級就是改 globals 的 constraint，無 lock file diff 需要 review
- Terramate CLI 由 `.terramate-version` exact pin，加上 `required_version` runtime guard

**權衡：** 失去了 provider package checksum 的供應鏈驗證能力。若未來推向 production / 高度審計的環境，再評估是否需要回頭 commit lock file 並用 `tofu providers lock -platform=linux_amd64 -platform=darwin_arm64` 統一各平台 hash。

**升級流程：**

OpenTofu / Terramate CLI 升級：

1. 修改 `.opentofu-version` 或 `.terramate-version`
2. 修改對應的 `required_version` patch line
3. 執行 `terramate generate`
4. Commit version file、HCL 設定與 generated files 一起 review

Provider 升級：

1. 改 `globals` 中的 provider constraint（例如 `~> 7.31.0` → `~> 7.32.0`）
2. `terramate generate` 同步 generated versions
3. Commit code 與 generated files
4. 下次本機 / CI 的 `tofu init` 會自動下載新版

### Terramate git-clean 與工作流

`terramate run` 預設拒絕在 working tree 有 uncommitted / untracked 檔案時執行，這是為了避免「實際執行的 IaC 沒有被 Git 記錄」。配合 lock file gitignore 政策，新增 stack 或升級 provider 的流程是：

```text
修改 IaC / Terramate globals
→ terramate generate
→ commit IaC 與 generated files
→ terramate run -- tofu init
→ terramate run -- tofu plan/apply
```

這個流程的重點不是「commit 後就代表線上已一致」，而是讓 plan/apply 使用可追溯的 desired state。線上狀態是否一致仍由 remote state、`tofu plan`、`tofu apply` 和後續 drift detection 保證。

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
