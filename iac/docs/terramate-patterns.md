# Terramate 使用模式

本專案在 [fengnux/tofu-terramate-hcl](https://github.com/fengnux/tofu-terramate-hcl) 中使用 Terramate
管理 OpenTofu stack。本文件記錄專案內的慣例與重點知識。

---

## Repo 結構慣例

```
tofu-terramate-hcl/
├── terramate.tm.hcl       # Terramate root config (required_version, git)
├── config.tm.hcl          # 全域 globals: gcp / tofu / labels
├── generate.tm.hcl        # 跨 stack 共用的 generate_hcl 規則
└── stacks/
    ├── bootstrap/
    │   ├── stack.tm.hcl   # stack {} 定義（id/name/tags）
    │   ├── _terramate_*.tf  # 自動生成檔（勿手改）
    │   ├── main.tf        # 資源
    │   └── outputs.tf
    └── dev/
        └── ...
```

**規則：**

- `terramate.tm.hcl`、`config.tm.hcl`、`generate.tm.hcl` **僅放 root**，stack 內不重複
- 每個 stack **必須** 有 `stack.tm.hcl` 才會被 `terramate list` 認到
- 自動生成檔以 `_terramate_*` 命名（含底線前綴），與手寫檔分開
- `stack.id` 全 repo 唯一，命名建議 `<env>-<purpose>`（如 `dev-network`）

---

## `generate_hcl` 模式

### 用途

把跨 stack 重複的設定（provider、versions、backend、locals）集中在 root 的 `generate.tm.hcl`，
避免每個 stack 都要 copy-paste。`terramate generate` 會把產出的 `.tf` 檔寫進每個符合條件的 stack 目錄。

### 範本

```hcl
# generate.tm.hcl
generate_hcl "_terramate_versions.tf" {
  content {
    terraform {
      required_version = global.tofu.required_version
      required_providers {
        google = {
          source  = "registry.opentofu.org/hashicorp/google"
          version = global.tofu.google_provider
        }
      }
    }
  }
}
```

### `condition` 控制適用範圍

```hcl
generate_hcl "_terramate_backend.tf" {
  condition = global.env.name != "bootstrap"
  content { ... }
}
```

### 產出檔處理原則

- **必須 commit**（CI / 別台機器無需重跑 generate 即能 apply）
- **不可手改**（檔頭有 `// TERRAMATE: GENERATED AUTOMATICALLY DO NOT EDIT`）
- 改了 globals 或 `generate.tm.hcl` 後，跑 `terramate generate` 並 commit 結果

---

## `tm_` 前綴函數（重要）

`generate_hcl` 的 `content` 區塊裡，函數的評估時機由前綴決定：

| 寫法 | 評估時機 | 結果 |
|------|----------|------|
| `replace(x, "/", "_")` | OpenTofu runtime | 產出檔含原始函數呼叫 |
| `tm_replace(x, "/", "_")` | Terramate generate 階段 | 產出檔是計算後的靜態字串 |

**原則：** 純粹要把 globals 變形、不需要參考 Terraform 資源屬性時，用 `tm_*`。

常見 `tm_*` 函數：`tm_replace`、`tm_join`、`tm_lower`、`tm_upper`、`tm_format`、`tm_split`、`tm_jsonencode`、`tm_yamldecode`。

---

## Stack 執行：`terramate run`

### 基本用法

```bash
terramate run --tags bootstrap -- tofu init
terramate run --tags bootstrap -- tofu plan
terramate run --tags bootstrap -- tofu apply
```

`terramate run` 會：

- 對每個符合條件的 stack `cd` 進去執行命令
- 預設要求 git working tree 乾淨（避免狀態漂移）

### 篩選方式

| 旗標 | 用途 |
|------|------|
| `--tags <tag>` | 依 `stack.tags` 篩選 |
| `--changed` | 只跑相對於 `default_branch` 有變動的 stack（CI 友善） |
| `--no-recursive` | 不遞迴子目錄 |

### Working tree 檢查

預設遇到未 commit 或 untracked 檔會中止。臨時繞過用：

```bash
terramate run --disable-check-git-untracked --disable-check-git-uncommitted -- tofu init -upgrade
```

> 用完務必 commit，不要長期關閉檢查。

---

## Globals 階層

Globals 在 `terramate.tm.hcl`、`config.tm.hcl`、stack 自身或路徑上的任何 `.tm.hcl` 都能定義，
依**從 root 到 stack** 的順序合併，越靠近 stack 的覆蓋越外層。

本專案目前的命名空間：

| Namespace | 定義位置 | 內容 |
|-----------|----------|------|
| `global.gcp` | root `config.tm.hcl` | `lab_project`、`region`、`state_bucket` |
| `global.tofu` | root `config.tm.hcl` | `required_version`、`google_provider` |
| `global.labels` | root `config.tm.hcl` | `managed_by`、`source_repo` |
| `global.env` | env 層（如 `stacks/dev/`） | `name`、`project` |

> 命名空間用區塊形式（`globals "gcp" { ... }`）而不是 `globals { gcp = {...} }`，
> 因為 Terramate 對前者支援深層合併與 stack 階層覆蓋。

---

## 常用工作流程速查

| 場景 | 指令 |
|------|------|
| 新增 stack | 建目錄 → 寫 `stack.tm.hcl` → `terramate generate` → `terramate list` 確認 |
| 修改 globals 後同步 | `terramate generate` → 看 diff → commit |
| 只跑有變動的 stack | `terramate run --changed -- tofu plan` |
| 列出 stack 並含 metadata | `terramate list --why`、`terramate experimental run-graph` |
| 偵測 generate 已過時 | CI 跑 `terramate generate --detailed-exit-code` |
