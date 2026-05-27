# Lab 04e - IaC 安全掃描（Trivy）

## 目標

在 CI 加入 Trivy IaC 安全掃描，分兩個觸發場景：

| 觸發 | 範圍 | 失敗行為 | 用途 |
|------|------|---------|------|
| **PR** | 僅變更的 stacks（`terramate list --changed`） | HIGH/CRITICAL → block merge | 快速回饋變更影響、避免無關 finding 干擾 |
| **Schedule（每日）+ manual** | 整個 repo `.tf` | HIGH/CRITICAL → 開 Issue | 抓持續違規、規則庫更新時主動提醒、historic baseline |

結果以 SARIF 上傳 GitHub Code Scanning。同時順手把 workflow 內**所有** third-party action 從 tag pinning 改為 commit SHA pinning，降低供應鏈攻擊面。

## 設計重點

### 為何選 Trivy（在 2026-03 供應鏈攻擊後）

2026-03-19 ~ 03-20 發生 [Trivy 供應鏈攻擊](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)（CVE-2026-33634, CVSS 9.4）：

| 攻擊面 | 影響 |
|--------|------|
| `aquasecurity/trivy-action` 76 個 tag 被 force-push | 任何用 `@v0.28.0` 之類 tag pinning 的 workflow 全部執行惡意 code |
| `aquasecurity/setup-trivy` 全部 7 個 tag 被竄改 | 同上 |
| Trivy `v0.69.4 / 0.69.5 / 0.69.6` 為惡意版本 | 最後乾淨版本：`v0.69.3` |

**為何仍選 Trivy**：

1. Aqua 已撤下惡意 image、於 2026-03-20 重新發布 74 個乾淨 release（`v0.69.3` 及之前 + 事後新版）
2. Tag 已重新指向乾淨 commit；新發布的 `trivy-action v0.35.0+` 為事件後乾淨版
3. tfsec 已被 Aqua 收編並 archive，社群替代品 Checkov 規則數量類似，但事件本身代表整個 IaC 安全掃描生態都需要強化使用方式，換工具治標不治本

**緩解措施（這次 lab 全面落實）**：

| 措施 | 做法 |
|------|------|
| **SHA pinning** | 所有 third-party action 用 commit SHA 而非 tag（包含既有 actions） |
| **Comment 標版本** | `uses: org/repo@<sha> # vX.Y.Z`，方便後續審查與升級 |
| **最小權限 token** | workflow job 只開必要 permissions，不給 `write-all` |
| **不依賴 setup-trivy** | 改用 `trivy-action`（單一 action，攻擊面收斂）或直接 `apt install` |
| **後續用 Dependabot 自動升級 SHA** | 留作 Lab 04h 待辦，本次先手動 pin |

### 為何拆 PR + Schedule 兩條路徑

| 場景 | 為何需要 |
|------|---------|
| **PR scan（changed only）** | 開發者只需聚焦本次 PR 帶入的風險；無關 finding 視為 baseline 噪音、不阻擋小 PR；速度快 |
| **Schedule scan（full repo）** | (1) Trivy 規則庫每週新增規則，過去乾淨的 .tf 可能因新規則被標；(2) 抓 PR 範圍外的歷史債；(3) 與 drift detection 形成「runtime drift + static security drift」雙重監控 |

PR job 與 schedule job 不共用 workflow 檔（與 `drift.yml` 對齊）：
- `opentofu.yml`：plan / apply / **security-scan-pr**（PR-only，並行 plan）
- `security-scan.yml`（新檔）：schedule + workflow_dispatch，掃整個 repo，找到 HIGH/CRITICAL 開 Issue

### 為何 PR scan 並行 plan job

Plan 和 scan 互不依賴 → 設計成**並行 job**（同 `needs: [generate-check]`，無串接）：
- 任一 fail 都會 block PR merge（required status checks）
- Scan 失敗不會阻擋 plan 結果留言，反之亦然

### 為何掃 generated `.tf`

Terramate `generate_hcl` 產生的 `_terramate_generated_*.tf` 也是真正會被 apply 的 IaC，必須一起掃。CI 流程：
1. checkout
2. `terramate generate`（確認 generated files 與 commit 一致）
3. trivy scan（含 generated 檔案）

### Severity Gate 策略

| Severity | 行為 | 理由 |
|----------|------|------|
| `CRITICAL` / `HIGH` | `--exit-code 1` → PR fail | 風險顯著，必須處理或明確 ignore |
| `MEDIUM` / `LOW` | annotate only | 訊息留在 PR Files Changed 標籤、Code Scanning，不阻擋合併 |
| `UNKNOWN` | 忽略 | 通常為 plugin 異常，雜訊 |

### `.trivyignore` 管理

每條 ignore 必須附上 comment 說明：
- **原因**（為何接受此風險）
- **追蹤連結**（GitHub Issue / PR / 文件）
- **複查日期**（多久後重新評估）

範例：
```
# Accepted: dev 環境網段允許 0.0.0.0/0 IAP 來源（IAP 已限制 Google IP）
# Tracking: iac/labs/lab-03c-dev-vm.md
# Review: 2026-08-01
AVD-GCP-0048
```

### SARIF → GitHub Code Scanning

- Public repo 免費啟用 Code Scanning（需於 repo Settings → Code security → enable）
- 上傳後 finding 會出現在：
  - PR Files Changed 標籤（行內 annotation）
  - Security → Code scanning alerts（含歷史追蹤、Dismiss reason）
  - 開發者本機 IDE（VSCode GitHub 擴充套件）

---

## 前置條件

- 完成 Lab 04c（PR plan comment 已 sticky）
- repo Settings → Code security and analysis → **Code scanning** 已啟用（public repo 預設可用，private repo 需 GHAS）
- 已知所有 third-party action 的 commit SHA（執行時透過 `gh api repos/{owner}/{repo}/git/ref/tags/{tag}` 查詢）

---

## 步驟

### Phase A — 查詢並記錄所有 action SHA

對下表每個 action 跑 `gh api repos/{owner}/{repo}/git/ref/tags/{tag}` 取得 commit SHA：

| Action | 目前 tag | 用途 |
|--------|---------|------|
| `actions/checkout` | `v6` | git clone |
| `actions/cache` | `v5` | provider plugin cache |
| `terramate-io/terramate-action` | `v3` | install terramate |
| `opentofu/setup-opentofu` | `v2` | install tofu |
| `google-github-actions/auth` | `v3` | WIF auth |
| `marocchino/sticky-pull-request-comment` | `v2` | plan comment |
| `aquasecurity/trivy-action` | `0.35.0`（待查最新乾淨版） | trivy scan |
| `github/codeql-action/upload-sarif` | `v3` | upload SARIF |

> ⚠️ **major tag 隱含風險**：`@v6` 會隨時跟著新 minor/patch 動，這正是被攻擊時最大的問題。改用 SHA 後等於 freeze；以後升版前可審 changelog。

查詢腳本（在 lab 執行時跑）：

```bash
for spec in \
  "actions/checkout:v6" \
  "actions/cache:v5" \
  "terramate-io/terramate-action:v3" \
  "opentofu/setup-opentofu:v2" \
  "google-github-actions/auth:v3" \
  "marocchino/sticky-pull-request-comment:v2" \
  "github/codeql-action:v3"; do
  repo="${spec%:*}"; tag="${spec##*:}"
  sha=$(gh api "repos/$repo/git/ref/tags/$tag" -q '.object.sha')
  # tags 可能為 annotated tag，需要再 deref
  type=$(gh api "repos/$repo/git/ref/tags/$tag" -q '.object.type')
  if [ "$type" = "tag" ]; then
    sha=$(gh api "repos/$repo/git/tags/$sha" -q '.object.sha')
  fi
  echo "$repo@$sha # $tag"
done
```

Trivy action 特別處理（須挑事件後乾淨版本）：

```bash
# 列出 trivy-action 最近 release，挑 2026-04 之後的 stable
gh api repos/aquasecurity/trivy-action/releases --paginate \
  -q '.[] | select(.created_at > "2026-04-01") | "\(.tag_name)\t\(.created_at)"' \
  | head -20
```

挑定版本後同樣 deref tag → commit SHA。

### Phase B — 改寫 `opentofu.yml`：全 action SHA pinning + 新增 PR security-scan job

修改 `.github/workflows/opentofu.yml`：

1. 把所有 `uses: org/repo@vX` 改為 `uses: org/repo@<sha> # vX.Y.Z`
2. 新增 `security-scan-pr` job（並行 `plan`，僅 PR 觸發，只掃變更 stacks）

```yaml
  security-scan-pr:
    name: Trivy IaC scan (changed stacks)
    if: github.event_name == 'pull_request'
    needs: [generate-check]
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      security-events: write   # upload SARIF
      pull-requests: read
    steps:
      - uses: actions/checkout@<sha>   # v6.0.0
        with:
          fetch-depth: 0

      - uses: terramate-io/terramate-action@<sha>   # v3.x.x
        with:
          version: ${{ env.TERRAMATE_VERSION }}

      - name: terramate generate
        run: terramate generate

      - name: List changed stacks
        id: changed
        run: |
          stacks=$(terramate list --changed --no-tags foundational)
          if [ -z "$stacks" ]; then
            echo "No stack changes — skipping scan."
            echo "has_changes=false" >> "$GITHUB_OUTPUT"
          else
            echo "has_changes=true" >> "$GITHUB_OUTPUT"
            # 把多行 stacks 變成逗號分隔給 trivy --scan-ref
            echo "stacks<<EOF" >> "$GITHUB_OUTPUT"
            echo "$stacks" >> "$GITHUB_OUTPUT"
            echo "EOF" >> "$GITHUB_OUTPUT"
          fi

      - name: Trivy IaC scan changed stacks (HIGH/CRITICAL → fail)
        if: steps.changed.outputs.has_changes == 'true'
        env:
          STACKS: ${{ steps.changed.outputs.stacks }}
        run: |
          # 對每個變更 stack 跑 trivy config，合併 SARIF 結果
          # 使用獨立 trivy binary 避免重複下載 action
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/<sha>/contrib/install.sh \
            | sh -s -- -b /usr/local/bin v0.69.x   # post-incident clean version
          
          # HIGH/CRITICAL pass，先掃出 SARIF
          fail=0
          echo "$STACKS" | while read -r stack; do
            [ -z "$stack" ] && continue
            trivy config "$stack" \
              --severity HIGH,CRITICAL \
              --exit-code 1 \
              --ignore-unfixed \
              --format sarif \
              --output "trivy-$(echo "$stack" | tr / -).sarif" \
              || fail=1
          done
          
          # MEDIUM/LOW annotate only（table 印 log）
          echo "$STACKS" | while read -r stack; do
            [ -z "$stack" ] && continue
            trivy config "$stack" \
              --severity MEDIUM,LOW \
              --format table || true
          done
          
          exit $fail

      - name: Merge SARIF files
        if: always() && steps.changed.outputs.has_changes == 'true'
        run: |
          # github/codeql-action/upload-sarif 一次只接一個 sarif_file，需合併
          # 使用簡易合併（用 jq 把 runs 陣列串起來）
          ls trivy-*.sarif 2>/dev/null || { echo "no SARIF files"; exit 0; }
          jq -s '{ "$schema": .[0]."$schema", version: .[0].version, runs: map(.runs) | add }' \
            trivy-*.sarif > merged.sarif

      - name: Upload SARIF to GitHub Code Scanning
        if: always() && steps.changed.outputs.has_changes == 'true' && hashFiles('merged.sarif') != ''
        uses: github/codeql-action/upload-sarif@<sha>   # v3.x.x
        with:
          sarif_file: merged.sarif
          category: trivy-iac-pr
```

> 💡 **為何不直接用 `aquasecurity/trivy-action`**：該 action 一次只接一個 `scan-ref`，要對多個 changed stack 跑只能多次 invoke action 或自己寫迴圈。直接 `curl` + 命令列反而簡單，且能 pin trivy binary 到具體 commit SHA（雙層保險）。trivy binary 版本與 trivy-action 重新發布版同樣為 post-incident 乾淨版。

### Phase C — 新增 `security-scan.yml`：Schedule 全 repo 掃描

建立 `.github/workflows/security-scan.yml`（仿 `drift.yml` 模式）：

```yaml
name: Security Scan (Full Repo)

on:
  # schedule:
  #   - cron: '0 3 * * *'   # 每天 03:00 UTC（台灣 11:00），錯開 drift 02:00
  workflow_dispatch:

permissions:
  contents: read
  security-events: write
  issues: write             # 開 Issue 通知

env:
  TERRAMATE_VERSION: "0.17.0"

jobs:
  scan:
    name: Trivy IaC scan (full repo)
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>   # v6.0.0

      - uses: terramate-io/terramate-action@<sha>   # v3.x.x
        with:
          version: ${{ env.TERRAMATE_VERSION }}

      - name: terramate generate
        run: terramate generate

      - name: Install trivy
        run: |
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/<sha>/contrib/install.sh \
            | sh -s -- -b /usr/local/bin v0.69.x

      - name: Trivy scan (HIGH/CRITICAL)
        id: scan
        run: |
          set -o pipefail
          trivy config . \
            --severity HIGH,CRITICAL \
            --exit-code 0 \
            --ignore-unfixed \
            --format sarif \
            --output trivy-full.sarif \
            --skip-dirs '.terraform,.git'
          
          # 同時跑一次 table 格式，用於 Issue body
          trivy config . \
            --severity HIGH,CRITICAL \
            --exit-code 0 \
            --ignore-unfixed \
            --format table \
            --skip-dirs '.terraform,.git' \
            > trivy-summary.txt
          
          # 判斷是否有 finding
          count=$(jq '[.runs[].results[]?] | length' trivy-full.sarif)
          echo "finding_count=$count" >> "$GITHUB_OUTPUT"

      - name: Upload SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@<sha>   # v3.x.x
        with:
          sarif_file: trivy-full.sarif
          category: trivy-iac-full

      - name: Open or update GitHub Issue on findings
        if: steps.scan.outputs.finding_count != '0'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh label create security-scan --color "#d93f0b" \
            --description "Trivy IaC scan findings" 2>/dev/null || true

          body=$(printf '## Trivy IaC Scan Report\n\n**Run:** %s | **Time:** %s\n\n**Finding count (HIGH/CRITICAL):** %s\n\n```\n%s\n```\n\nFull SARIF: Security → Code scanning → category `trivy-iac-full`\n' \
            "${{ github.run_id }}" \
            "$(date -u '+%Y-%m-%d %H:%M UTC')" \
            "${{ steps.scan.outputs.finding_count }}" \
            "$(cat trivy-summary.txt)")
          
          existing=$(gh issue list --label security-scan --state open --json number -q '.[0].number')
          if [ -n "$existing" ]; then
            gh issue comment "$existing" --body "$body"
          else
            gh issue create \
              --title "Security findings: $(date -u '+%Y-%m-%d')" \
              --label security-scan \
              --body "$body"
          fi

      - name: Fail workflow on findings
        if: steps.scan.outputs.finding_count != '0'
        run: |
          echo "::error::Trivy found ${{ steps.scan.outputs.finding_count }} HIGH/CRITICAL issues."
          exit 1
```

> ⚠️ 與 `drift.yml` 一樣，schedule 先註解掉，先用 `workflow_dispatch` 手動驗證；確認穩定後再 enable cron。

### Phase D — 加入 `.trivyignore` 骨架（含 baseline 策略）

repo 根新增 `.trivyignore`：

```
# Trivy IaC scan ignore list
# 格式：
#   # 原因說明
#   # Tracking: <文件或 issue 連結>
#   # Review: YYYY-MM-DD
#   <CHECK-ID>
#
# 初始為空，待 Phase E 第一次 schedule scan 後依實際 findings 補 baseline
```

**Baseline 策略**：第一次 `workflow_dispatch` 跑 `security-scan.yml` 通常會抓到一堆既有 finding。為避免 lab 卡在 finding triage：

1. 第一次 scan 完，把**所有 HIGH/CRITICAL** finding 的 check-id 全部加進 `.trivyignore`，每條附「baseline (待評估)」comment + Review 日期（建議 +30 天）
2. Issue 標題改成 `Security baseline established: YYYY-MM-DD`
3. 後續逐條移出 `.trivyignore` → 修 `.tf` 或改為「accepted」狀態並更新 comment
4. 這樣 PR scan 立刻有效（後續任何新引入的 HIGH 都會被擋），不用等全部既有 finding 處理完才能上線

### Phase E — 開 PR 觀察初次掃描結果

```bash
cd /Users/fengnux/GitHub/tofu-terramate-lab

# 改 workflow + 加 .trivyignore
git checkout -b lab-04e-security-scan
git add .github/workflows/opentofu.yml .github/workflows/security-scan.yml .trivyignore
git commit -m "feat(ci): add Trivy IaC scan (PR + scheduled) + pin all actions to SHA"
git push -u origin lab-04e-security-scan

# 開 PR
gh pr create --title "Lab 04e: Trivy IaC scan + action SHA pinning" \
  --body "新增 Trivy 安全掃描：PR 掃變更 stacks、schedule 全 repo；所有 action 改 commit SHA pin"
```

觀察 PR Checks：
- `Plan changed stacks (PR)`：應該還是綠（無 IaC 變更）
- `Trivy IaC scan (changed stacks)`：本 PR 沒改 stack，預期 skip
- Code Scanning alerts：尚不會出現（PR 沒掃描）

接著手動觸發 schedule workflow 看實際 finding：

```bash
gh workflow run security-scan.yml
# 等執行
gh run watch
```

對每個 HIGH/CRITICAL finding：
1. 評估是否為真風險（呼叫 terraform-best-practices skill 對照）
2. 真風險 → 修 `.tf`
3. 接受風險 → 加 `.trivyignore`（必附 comment）
4. 規則誤判 → 加 `.trivyignore`（comment 說明誤判原因）

迭代直到 schedule scan 不再開 Issue。

接著做一次「會觸發 PR scan」的測試 PR（**僅驗證用，不 merge**）：

```bash
git checkout -b lab-04e-test-violation
# 故意加一個 HIGH 違規（例如改 firewall source_ranges = ["0.0.0.0/0"]）
# 編輯 stacks/dev/network/main.tf
git commit -am "test: intentional HIGH violation (DO NOT MERGE)"
git push -u origin lab-04e-test-violation
gh pr create --draft \
  --title "[TEST] Trivy violation 驗證" \
  --body "驗證 PR 引入 HIGH 違規時 scan 會 fail；驗完即 close，不 merge"
```

驗收：
- PR 上 `Trivy IaC scan (changed stacks)` 紅
- Files Changed tab 行內 annotation 標出違規行
- Security → Code scanning → `trivy-iac-pr` category 顯示 alert
- 確認後：`gh pr close lab-04e-test-violation --delete-branch`

### Phase F — 驗證並 merge 主 PR

PR 全綠後：
1. 點開 PR 確認 Code Scanning summary 出現在 PR conversation 頁
2. 點 Files Changed → 確認行內 annotation 顯示 MEDIUM/LOW finding
3. Merge PR
4. main push 不觸發 scan（設計上 PR-only），但 Code Scanning alert 會留存

---

## 驗收清單

| 項目 | 預期結果 |
|------|---------|
| 所有 third-party action 改為 commit SHA + 版本 comment | ✅ |
| Repo Settings 啟用 Code Scanning | ✅ |
| PR 觸發 `security-scan-pr` job（與 plan 並行） | ✅ |
| PR scan 範圍 = changed stacks（無變更時 skip） | ✅ |
| 故意 PR 引入 HIGH violation → PR fail | ✅ |
| MEDIUM/LOW → annotate，不阻擋 | ✅ |
| `security-scan.yml` workflow_dispatch 可手動跑全 repo 掃描 | ✅ |
| Schedule scan 找到 HIGH/CRITICAL → 開 Issue（dedup） | ✅ |
| SARIF 上傳 → Code Scanning alerts 顯示（兩個 category 分開） | ✅ |
| `.trivyignore` 條目皆附原因 + Review 日期 | ✅ |
| Plan / Security scan 互不阻塞 | ✅ |
| Trivy binary 與 trivy-action 皆為 post-incident 乾淨版本 | ✅ |

---

## 後續

- [x] Schedule scan 穩定後 enable cron（`security-scan.yml` 取消註解，03:00 UTC daily）— PR [#13](https://github.com/fengnux/tofu-terramate-lab/pull/13)
- [ ] Lab 04g：Terramate Cloud 整合
- [ ] Lab 04h：Dependabot 自動升級 action SHA pinning
- [ ] Dev/vm drift 定位後重新啟用 drift schedule trigger
- [ ] 評估是否把 `secret` scan（trivy `--scanners secret`）一起加入（會掃 git history，可能慢）
- [ ] 評估把 MEDIUM 也納入 fail（policy 討論；SSH 0.0.0.0/0 等規則 Trivy 為 MEDIUM）

---

## 實際執行紀錄（2026-05-17）

詳見 [logs/2026-05-17.md](../../logs/2026-05-17.md) 下半部「Lab 04e」段。重點 PR 與 commit：

| PR | 內容 | 狀態 |
|----|------|------|
| [#10](https://github.com/fengnux/tofu-terramate-lab/pull/10) | 主 PR：全 action SHA pin + security-scan-pr job + security-scan.yml + .trivyignore | merged [eff0975](https://github.com/fengnux/tofu-terramate-lab/commit/eff0975) |
| [#11](https://github.com/fengnux/tofu-terramate-lab/pull/11) | 修正：移除 `--ignore-unfixed`（trivy config 不支援）+ codeql v3→v4 | merged [9d115bc](https://github.com/fengnux/tofu-terramate-lab/commit/9d115bc) |
| [#12](https://github.com/fengnux/tofu-terramate-lab/pull/12) | 反向驗證：GCP-0001 public bucket HIGH 觸發 `security-scan-pr` fail | **closed, not merged**（驗證用） |
| [#13](https://github.com/fengnux/tofu-terramate-lab/pull/13) | 啟用 schedule cron `0 3 * * *` | merged [a33f183](https://github.com/fengnux/tofu-terramate-lab/commit/a33f183) |

### 主要 finding（schedule scan 首次乾淨跑）

5 個非 foundational stacks 全掃，**HIGH/CRITICAL = 0**，`.trivyignore` 不需 baseline。

### 反向驗證 finding（PR 12）

| 項目 | 值 |
|------|----|
| 規則 | GCP-0001 "Bucket allows public access" |
| 嚴重度 | HIGH |
| 觸發 | `google_storage_bucket_iam_member` member=`allUsers` |
| 結果 | `security-scan-pr` ❌、SARIF 上傳成功、Code Scanning alert open（PR ref） |

### 坑

1. **`--ignore-unfixed` 是 `trivy image` flag，不是 `trivy config` flag** — 第一次 schedule scan FATAL，fix PR 修
2. **CodeQL Action v3 Dec 2026 deprecation** — 順手升 v4.35.5
3. **`tofu fmt -check` 嚴格** — 違規測試時我 comment 多加空格，plan 即 fail
4. **第一次測試違規嚴重度不夠** — `iap_source_range = "0.0.0.0/0"` 被 Trivy 評 MEDIUM，沒觸發 HIGH gate；換 `google_storage_bucket_iam_member allUsers` 才成功
5. **Code Scanning UI 預設 `branch:main` filter** — PR-ref alert 看不到，要改 `pr:N` filter

### 設計回顧

- **拆 PR + Schedule 兩條路徑**：證明有用 — schedule 抓 baseline、PR 抓增量
- **PR scan 只掃 changed stacks**：本 lab 主 PR、fix PR、enable-schedule PR 都沒改 stack → scan skip，PR 反饋秒級
- **SARIF 合併再上傳**：解決多 stack 多 SARIF 的 Code Scanning category 衝突
- **install.sh + 雙層 SHA pin**：trivy binary 換版本只需改 `TRIVY_VERSION` 與 `TRIVY_INSTALL_COMMIT` 兩個 env var，無需動 workflow 結構
