# Terramate Change Detection

> 機制 / 設計理解文件。實際驗證情境見文末「實驗驗證對照」段。

## 目的

`terramate list --changed` / `terramate run --changed -- ...` 用來「只對本次有變更的 stack 動作」，是 CI 上 PR 階段只 plan 受影響 stack 的關鍵。本文件釐清它的判定規則、盲點、與替代基準的設定方式。

---

## 核心：git diff + stack 邊界推導

Change detection **不是** 檔案系統 watch，也 **不看 tofu state**。完全建立在 git 之上：

1. **算 diff 範圍**：預設 `HEAD vs merge-base(HEAD, origin/main)`
2. **列出改動檔案路徑**：等同 `git diff --name-only` 的輸出
3. **映射回 stack**：每個改動檔，從它的目錄往上找最近的 `stack.tm.hcl`；那個目錄就是「被影響的 stack」
4. **加入額外觸發**（見下節）
5. **依 `after` / `before` 排 run order**（change detection 不會自動把上游拉進來，只是排序）

### 額外會觸發 stack 變更的來源

除了 stack 自己目錄下的檔案，下列也算：

- **`stack.watch = ["/modules/foo/main.tf"]`** — 明確聲明依賴的 stack 外檔案
- **`import { source = "..." }`** 來源檔被改（globals、generate 設定等）
- **root 層 `generate_hcl` / `generate_file` 規則改了** → 連帶讓 generated 檔出現 diff → 順勢偵測到所有受影響 stack

### 不會自動偵測的

- **上游 stack 的 state 變了**（remote state 改了但 `.tf` 沒動）— Terramate 不看 state
- **provider 端的漂移**（有人到 Console 手改）— 那是 `tofu plan` 才會發現的事
- **未 commit 的本地改動**（safeguard 也會擋 run）

## 比較基準（base ref）

預設行為的關鍵在這個對比基準：

```
HEAD  vs  merge-base(HEAD, origin/main)
```

| 情境 | HEAD | merge-base | diff 結果 |
|------|------|-----------|-----------|
| feature branch 上開發 | branch tip | 從 main 分岔點 | branch 上所有 commit ✅ |
| 直接在 main 上 commit、未 push | main tip | origin/main（落後 N commit） | 本地未推的 N 個 commit ✅ |
| **直接在 main 上 commit、已 push** | **main tip = origin/main** | **自己** | **空 ❌** |

第三種情境就是 **「都在 main 上開發」的盲點**：push 完之後 `--changed` 偵測不到任何 stack，因為 HEAD 跟 base 已經重合。

### 為什麼這樣設計

Terramate 把 change detection 定位成 **「相對於主線基準的變化」**，給 PR / CI 用：在 PR 上跑 `--changed` 只 plan 這次 PR 引入的差異。一旦合進 main，那些變更就「不再是變更」了，CI 不會再對它們動作——這是刻意的，不是 bug。

## 替代基準的設定方式

當預設的 main-relative 不適合（例如 lab repo 直接在 main 開發），有幾種替代：

### 1. CLI flag 指定 base

```bash
terramate run --changed --git-change-base=HEAD~1 -- tofu plan
```

比較「HEAD vs 上一個 commit」，等於只看最新 commit 的改動。

### 2. 用 tag 當 base（「自上次部署以來」）

```bash
terramate run --changed --git-change-base=last-deploy -- tofu plan
```

把「上次 deploy 的 commit」打 tag（`last-deploy`），每次 deploy 後推進 tag。語意清楚：每次 CI 部署 = 跑「自上次部署以來變更的 stack」。

### 3. 改 repo 預設 base ref

在 `terramate.tm.hcl`：

```hcl
terramate {
  config {
    git {
      default_branch_base_ref = "origin/main"  # 預設值，可改
    }
  }
}
```

### 4. 不用 `--changed`，全跑

小 repo 直接 `terramate run -- tofu plan` 全跑也行——`tofu plan` 本身就會 no-op 沒改的 stack。`--changed` 只是省時間 / 減少 CI 噪音。

## 取捨

- **優點**：純 git-based、可重現、CI 友善、不需要 state
- **缺點**：跨 stack 的「邏輯依賴」不會自動展開（例如 network 改了 CIDR、想連帶重 plan 下游 VM stack 不會發生）——要靠 `stack.watch` 或 `after` + 人為加旗標。Terramate 哲學是「每個 stack 自己負責 plan / apply 自己的 drift」

## 實務建議

| 場景 | 建議 |
|------|------|
| 正式 repo（PR workflow） | 預設行為即可，CI 用 `terramate run --changed -- tofu plan` |
| Lab repo（直接在 main commit） | 別依賴 `--changed`，或在 CI 用 `HEAD~1` / 部署 tag 當 base |
| 跨 stack 依賴強的場景 | 用 `stack.watch` 明確列出依賴檔案，或乾脆全跑 |

---

## 實驗驗證對照

本 doc 列出的主要情境已在 Lab 04 系列實際跑過：

| 情境 | 驗證所在 |
|------|---------|
| feature branch 改 1 個 stack，`--changed` 只列出該 stack | [Lab 04](../labs/lab-04-ci-pipeline.md) PR plan（dev/vm）、[Lab 04c](../labs/lab-04c-pr-plan-comment.md) PR #4（dev/network） |
| main 連續 2 個 commit 後 `--changed` 為空（盲點） | [Lab 04 風險與回退段](../labs/lab-04-ci-pipeline.md#風險與回退)：CI 用 `--git-change-base="${{ github.event.before }}"` 解掉，等價於對 main 上「這次 push 前後」做 diff |
| `--git-change-base=HEAD~1` 在 main 上偵測 | 概念同上：CI 用 `github.event.before` 取代 `HEAD~1`，意義一致但 push event SHA 更精確 |
| 改 root globals / `generate.tm.hcl` 規則導致所有 stack 被偵測 | [Lab 04 過程](../../logs/2026-05-16.md)：改 `config.tm.hcl` 後 `terramate generate` 重產所有 stack 的 `_terramate_*.tf`，這些 generated 檔的 commit 即觸發 `--changed` 涵蓋全部 stack |
| 未追蹤檔案下 `--changed` 的 safeguard 行為 | [Lab 04c 踩坑](../labs/lab-04c-pr-plan-comment.md#風險與回退)：`plan-output.md` 寫在 workspace 內 → `Error: repository has untracked files`；解法是寫到 `${{ runner.temp }}` |

未驗證且暫不規劃：

- tag (`last-deploy`) 當 base 演練「自上次部署以來」工作流——CI 已用 push event SHA，個人 lab 不需另一套 tag 追蹤機制
- `stack.watch` 指向 stack 外檔案——本 repo 無共享配置檔需要 watch，無實務情境
