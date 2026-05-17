# Lab 04h - Dependabot: 自動追蹤 Action SHA 更新

## 目標

Lab 04e 把所有 third-party action 改成 commit SHA pinning，但**長期不升級會錯過安全修補與功能**。本 lab 加入 GitHub 內建 Dependabot，**每週**自動掃描所有 `.github/workflows/*.yml`，偵測 third-party action 有新版時，**集中開 1 個 PR** 更新 SHA + 版本 comment，讓 review 兼顧時效與成本。

## 設計重點

### 為何選 Dependabot 而非 Renovate

| 比較 | Dependabot | Renovate |
|------|-----------|----------|
| 安裝 | GitHub 內建，零安裝 | GitHub App 安裝 |
| GH Actions 支援 | ✅ | ✅ |
| 配置語法 | YAML | JSON5（更彈性） |
| 識別 SHA pin + comment 自動同步 | ✅ | ✅ |
| 監控 generic version（如 `TRIVY_VERSION` env var） | ❌ | ✅ via `regexManagers` |
| 我們用得到的功能 | 都有 | 多餘 |

→ Dependabot 已夠用，少一個外部 GitHub App 等於少一個攻擊面（與 Lab 04e 的「收斂信任源」哲學一致）。

### 為何每週、不每日

| 頻率 | 優點 | 缺點 |
|------|------|------|
| 每日 | 安全 patch 最快進來 | 多數天 0 PR；偶爾出現也常是無關緊要的小升級，造成 review 疲勞 |
| **每週** | 一週一次集中 review，配合人類週期 | 安全 patch 最多延遲 7 天 |
| 每月 | 維護成本最低 | 安全 patch 可能延遲 30 天，違反 supply chain 防禦的目的 |

選週一 06:00 UTC（台灣週一 14:00），避開 security-scan 03:00 與 drift 02:00，工作日下午有時間 review。

### 為何全部 group 成 1 PR

我們只有 7 個 third-party action，多數版本同步釋出（如官方 `actions/*` 系列）。Group 後：
- 一週最多 1 PR、一次 CI 跑、一次 review/merge
- Group 內任一 action 升級失敗（CI fail）→ 整個 PR 留著等修復；不會分散注意力
- Default 每 action 一 PR 會變成 5-7 個 PR/週，PR list 雜訊大

### 為何不 auto-merge

Lab 04e 整套設計目的就是**強制人類在意 supply chain**。Auto-merge 哪怕只在 patch 級別都會讓人習慣性放行（「反正 CI 過就好」），與初衷相反。每週手動 review changelog 是可承受的成本（< 5 分鐘）。

> 如果未來想加 auto-merge：建議只在 patch（`vX.Y.Z` 變 Z 部分）且 CI 全綠時自動 merge，並排除 trivy-action / setup-trivy 等供應鏈高風險 action。

### 不含 trivy binary 版本追蹤

Lab 04e 用 env var pin trivy：

```yaml
TRIVY_VERSION: "v0.70.0"
TRIVY_INSTALL_COMMIT: "8a3177aedf7ee0864920eb1852eef031cd3742b8"
```

Dependabot 不會追這兩個（不是 action）。**接受手動升級**，理由：
1. Trivy 剛經歷大型供應鏈事件，每次升版都應手動讀 release notes
2. 升級流程已文件化（lab 04e Phase A 的 SHA 查詢命令可直接 reuse）
3. 引入 Renovate `regexManagers` 為了追兩個 var 不划算

### 為何 `dependabot.yml` 不放在 `.github/workflows/`

GitHub 對 `.github/` 下有幾個**固定路徑約定**，不是我們的選擇：

| 路徑 | 用途 | 性質 |
|------|------|------|
| `.github/workflows/*.yml` | GitHub Actions workflows | 你定義的「流程」（事件觸發跑 job） |
| `.github/dependabot.yml` | Dependabot 設定 | **GitHub 託管服務**的設定檔 |
| `.github/CODEOWNERS` | code review 自動分派 | repo metadata |
| `.github/ISSUE_TEMPLATE/` | issue 範本 | UI metadata |
| `.github/FUNDING.yml` | 贊助連結 | UI metadata |

關鍵差別：

- `workflows/*.yml` 是「**你定義的流程**」，GitHub Actions runner 跑它
- `dependabot.yml` 是「**Dependabot 服務的設定**」。Dependabot 本身跑在 GitHub 基礎設施上，不是 Action — 它讀這個檔案知道「要追什麼 ecosystem、多久掃一次、PR 怎麼設」，**自己安排排程**，根本不需要 workflow 觸發。

放錯位置（例如丟去 `.github/workflows/dependabot.yml`）會被當壞掉的 workflow YAML fail，Dependabot 服務則找不到設定不會啟動。

類似的還有 Renovate：預設找 `.github/renovate.json` 或 `renovate.json5`（也不在 `workflows/` 內）。

### 不影響的範圍

| 項目 | 行為 |
|------|------|
| 我們自己 push 的 commit | 不影響 |
| GitHub Action workflow 既有功能（plan/apply/scan/drift） | 不影響 |
| Branch protection（如設） | Dependabot PR 需通過 status checks（含 Trivy IaC scan） |
| `.trivyignore` | Dependabot 不會改 |
| `TOFU_VERSION` / `TERRAMATE_VERSION` env var | 不追（同 trivy 理由） |

---

## 前置條件

- 完成 Lab 04e（action 已 SHA-pinned，Dependabot 才能正確識別）
- 對 `tofu-terramate-lab` repo 有 admin 權限（Dependabot 預設啟用，但確保 repo Settings → Code security → Dependabot alerts/security updates 開啟）

---

## 步驟

### Phase A — 建立 `.github/dependabot.yml`

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: monday
      time: "06:00"
      timezone: Etc/UTC
    groups:
      all-actions:
        patterns:
          - "*"
    labels:
      - dependencies
      - github-actions
    commit-message:
      prefix: "chore(deps)"
      include: scope
    open-pull-requests-limit: 5
    # 兩個目錄都要掃：Dependabot 預設只看 .github/workflows/，但保險起見明示
    # （directory: / 已涵蓋 workflows，這裡無需額外配置）
```

> 設計註解：
> - `directory: /` 是 GitHub Actions ecosystem 的慣例：表示「掃 `.github/workflows/` 下所有 yml」
> - `groups.all-actions.patterns: ["*"]` 把所有 action 更新合併到 1 個 PR
> - `commit-message.prefix: "chore(deps)"` + `include: scope` → PR title 形如 `chore(deps): bump actions/checkout group`
> - `open-pull-requests-limit: 5` 是 group 上限（不是 PR 數量上限）；group 本身會壓成 1 PR

### Phase B — 開 PR 加入設定

```bash
cd /Users/fengnux/GitHub/tofu-terramate-lab
git checkout -b lab-04h-dependabot
mkdir -p .github  # 已存在
# 用 editor 寫入 .github/dependabot.yml
git add .github/dependabot.yml
git commit -m "feat(deps): add Dependabot for weekly action SHA updates (grouped, no auto-merge)"
git push -u origin lab-04h-dependabot

gh pr create --title "Lab 04h: enable Dependabot for action SHA updates" --body "..."
```

PR Checks 預期：plan + scan + generate-check + detect-foundational 全綠（無 stack 變更）

### Phase C — Merge 後驗證 Dependabot 識別

merge 後 5-30 分鐘 Dependabot 第一次 scan 會跑：

```bash
# 方法 1：UI
# https://github.com/fengnux/tofu-terramate-lab/network/updates
# 應顯示「github-actions」ecosystem 與所有偵測到的依賴

# 方法 2：API
gh api repos/fengnux/tofu-terramate-lab/dependabot/alerts 2>&1 | head -20

# 方法 3：手動觸發第一次 scan
# Settings → Code security → Dependabot → 找 "Check for updates" 按鈕
```

預期偵測到的 dependencies（21 處 uses，去重後 7 個 action）：

1. `actions/checkout` v6.0.2
2. `actions/cache` v5.0.5
3. `terramate-io/terramate-action` v3.3.0
4. `opentofu/setup-opentofu` v2.0.0
5. `google-github-actions/auth` v3.0.0
6. `marocchino/sticky-pull-request-comment` v2.9.4
7. `github/codeql-action` v4.35.5

### Phase D — 等下次週一觀察首個 Dependabot PR

下個週一 06:00 UTC 會出現第一個 PR。

驗收項目：
- [ ] PR title 形如 `chore(deps): bump the all-actions group with X updates`
- [ ] 所有更新合併在 **1 個** PR 內（不是多個）
- [ ] 每筆變更同時改 SHA 與後面的 `# vX.Y.Z` comment
- [ ] PR 觸發完整 CI（generate-check / plan / security-scan-pr / detect-foundational）
- [ ] 若 CI 全綠且 changelog 看完無疑慮 → 手動 merge
- [ ] 若某 action 升級導致 CI fail → 在 PR 評論 `@dependabot ignore this minor version` 暫排除該版本

> 第一個 PR 可能不會立刻出現（如果當天沒有 action 有新版可升）。可在 repo Insights → Dependency graph → Dependabot 看到「all dependencies up to date」。

---

## 驗收清單

| 項目 | 預期結果 |
|------|---------|
| `.github/dependabot.yml` 存在且 syntax 正確 | ✅ |
| Repo Settings → Code security → Dependabot 啟用 | ✅ |
| Dependabot 識別出 7 個 third-party action | ✅ |
| Schedule 設為每週一 06:00 UTC | ✅ |
| 所有 action 更新合併到 1 個 PR（group `all-actions`） | ✅（首個 PR 出現時驗證） |
| commit message prefix = `chore(deps)` | ✅ |
| PR 觸發完整 CI（含 security-scan-pr） | ✅ |
| 無 auto-merge | ✅（design choice） |
| trivy / tofu / terramate 等 env-var 版本**不**被追蹤 | ✅（預期行為） |

---

## 後續

- [ ] 每週週一觀察 Dependabot PR、review changelog 後手動 merge
- [ ] 若 Dependabot 升級頻繁打擾，調整為 `interval: monthly`
- [ ] 若決定加 auto-merge：建立 workflow `dependabot-auto-merge.yml`，只 auto-merge patch + CI 全綠（範圍：排除 trivy-action / setup-trivy 等供應鏈高風險 action）
- [ ] 評估 Renovate（regexManagers）以納入 `TRIVY_VERSION` / `TRIVY_INSTALL_COMMIT` 追蹤 — 待 Renovate 比 Dependabot 顯著有利時才換
- [ ] research repo 自己也加 Dependabot？（無 workflow，沒必要）

---

## 實際執行紀錄（2026-05-17）

詳見 [logs/2026-05-17.md](logs/2026-05-17.md) 最下方「Lab 04h」段。重點 PR：

| PR | 內容 | 狀態 |
|----|------|------|
| [#14](https://github.com/fengnux/tofu-terramate-lab/pull/14) | 主 PR：加 `.github/dependabot.yml` | merged [41804ff](https://github.com/fengnux/tofu-terramate-lab/commit/41804ff) |
| [#15](https://github.com/fengnux/tofu-terramate-lab/pull/15) | **Dependabot 自動開的首個 PR**：升 `sticky-pull-request-comment` v2.9.4 → v3.0.4（merge 後 ~5 分鐘就出現） | merged [d523e49](https://github.com/fengnux/tofu-terramate-lab/commit/d523e49) |
| [#16](https://github.com/fengnux/tofu-terramate-lab/pull/16) | 修 PR 15 暴露的 title bug：`chore(deps)(deps)` → `chore(deps)` | merged [8f79f6d](https://github.com/fengnux/tofu-terramate-lab/commit/8f79f6d) |

### 驗證重點

- ✅ Dependabot 即裝即用，merge 後幾分鐘就動
- ✅ PR 15 證明三件事：SHA + 版本 comment 同步更新、group 機制有效、PR 觸發完整 CI
- ✅ v3.0.0 major bump 純 Node 24 runtime upgrade，無 API breaking change（與 Lab 04d followup `dca9e86` 方向一致）

### 坑

1. **`prefix: "chore(deps)"` + `include: scope` 會疊加** → title 變 `chore(deps)(deps)`，要嘛 `prefix: chore`（讓 scope 自己加），要嘛去掉 `include: scope`
2. **`gh api repos/.../dependabot/alerts` 不是 dependency list**，那是 security alerts；version updates 在 `/network/updates` 網頁或 PR 直接看
