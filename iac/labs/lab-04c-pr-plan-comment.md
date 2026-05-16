# Lab 04c - PR Plan Comment：把 `tofu plan` 結果回寫 PR

## 目標

PR workflow 跑完 `tofu plan` 後，把每個 changed stack 的 plan 結果整理成單一 sticky comment 貼到 PR，reviewer 不必再點進 Actions log 看輸出。

## 為什麼要做

目前 PR plan 結果只在 Actions log 裡，review 流程：
1. 開 PR → 等 CI 綠燈
2. 點 Actions → 找到 plan job → 展開 step → 找對應 stack 的輸出

每次都要切離 PR 頁面，且 plan 輸出散在多個 step 裡。把結果回寫 PR 後，review 體驗：
1. 開 PR → 看 conversation tab 最新 comment → 直接看 diff

業界做法：CI 把 plan 輸出貼成 sticky comment（同一個 PR 一直更新同一則 comment，不是每次推 commit 都新增一則）。

## 前置條件

- Lab 04 + Lab 04a 完成
- 對 `tofu-terramate-lab` 有 push 權限

## 設計重點

### 用哪個 action 貼 comment

候選：
| 選項 | 優點 | 缺點 |
|------|------|------|
| `marocchino/sticky-pull-request-comment@v2` | 專注 sticky comment、配置簡單、廣泛使用 | 第三方 action |
| `actions/github-script` + REST API | 第一方、無新依賴 | 需自己寫 JS 處理「找舊 comment → 更新 or 新增」 |
| Terramate Cloud | 官方整合、含 plan visualization | 外部 SaaS，留待 Lab 04g |

**選 `marocchino/sticky-pull-request-comment@v2`**。理由：sticky comment 的「找 marker → upsert」邏輯不值得自己寫，而且這是 Terramate 官方 GitHub Actions 範例同款。

### Plan 輸出處理

每個 stack 跑一次 `tofu plan`，輸出散落。最乾淨的做法：

```bash
terramate run --changed --no-tags foundational \
  --continue-on-error \
  -- sh -c 'echo "## Stack: $(pwd)" && tofu plan -no-color -input=false -lock-timeout=5m'
```

要點：
- `-no-color`：移除 ANSI escape，comment 才不會有亂碼
- `--continue-on-error`：單一 stack plan fail 不要中斷整批，讓所有 stack 結果都進 comment
- `sh -c '... && tofu plan ...'` 在每個 stack 目錄印 header，輸出有結構

把上面 output redirect 到檔案，後面 step 讀檔包裝成 Markdown code block 後送進 sticky comment。

### Comment 大小

GitHub PR comment 上限 65,536 字元。對單一 stack 通常沒事，但 changed stacks 多 + 變更大時可能爆。策略：

1. 整個輸出超過 60,000 字元時截斷
2. 截斷時附上「輸出過長，完整內容請看 [Actions log](url)」
3. 留 ~5,000 字元 buffer 給 Markdown 包裝 + 標題

### Workflow permissions

目前 workflow top-level `permissions` 是 `pull-requests: read`。為了能寫 comment，要改成 `write`。

考量：top-level 改 `write` 會影響所有 job。較安全的做法是 **只在 plan job 內 override** 為 `pull-requests: write`，其他 job 保持 read。

### Plan 結果與 job 成功狀態

要不要因為 plan 印出 changes 就 fail job？**不要**。plan 印出 diff 是預期行為（PR 的意義就是 propose change），fail 會誤導 reviewer。job 只在 `tofu plan` 真的執行失敗時才 fail。

### 沒有 changed stack 時

`terramate run --changed` 在沒 stack changed 時不會跑任何指令，輸出空白。comment 內容改為「No stacks changed in this PR.」避免空 code block。

---

## 步驟

### 1. 修改 workflow

編輯 `.github/workflows/opentofu.yml`，調整 `plan` job：

**1a. 加 `pull-requests: write` permission**

```yaml
plan:
  name: Plan changed stacks (PR)
  if: github.event_name == 'pull_request'
  needs: [generate-check]
  runs-on: ubuntu-24.04
  permissions:                # ← 新增整個 permissions 區塊
    contents: read
    id-token: write
    pull-requests: write
  steps:
    ...
```

**1b. 取代原本的 `tofu plan` step 為「跑 plan 並收集輸出」**

把原本的：

```yaml
- name: tofu plan
  run: terramate run --changed --no-tags foundational -- tofu plan -input=false -lock-timeout=5m
```

換成：

```yaml
- name: tofu plan (capture output)
  id: plan
  run: |
    set -o pipefail
    {
      echo "## Tofu Plan Results"
      echo ""
      changed=$(terramate list --changed --no-tags foundational)
      if [ -z "$changed" ]; then
        echo "_No stacks changed in this PR._"
        exit 0
      fi
      echo "Changed stacks:"
      echo '```'
      echo "$changed"
      echo '```'
      echo ""
      terramate run --changed --no-tags foundational --continue-on-error -- \
        sh -c 'printf "\n### Stack: %s\n\`\`\`hcl\n" "$(realpath --relative-to="$GITHUB_WORKSPACE" .)" && tofu plan -no-color -input=false -lock-timeout=5m; printf "\n\`\`\`\n"'
    } > ${{ runner.temp }}/plan-output.md
    # 截斷至 60000 字元（留 buffer 給 sticky-comment 包裝）
    if [ "$(wc -c < ${{ runner.temp }}/plan-output.md)" -gt 60000 ]; then
      head -c 60000 ${{ runner.temp }}/plan-output.md > ${{ runner.temp }}/plan-output.trunc.md
      {
        echo ""
        echo "---"
        echo "_Output truncated. See full log: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}_"
      } >> ${{ runner.temp }}/plan-output.trunc.md
      mv ${{ runner.temp }}/plan-output.trunc.md ${{ runner.temp }}/plan-output.md
    fi
```

**1c. 加 sticky comment step**

```yaml
- name: Post plan to PR
  if: always()                # plan fail 也要貼 comment
  uses: marocchino/sticky-pull-request-comment@v2
  with:
    header: tofu-plan         # 用 header 區分 sticky；之後若 04d 加 drift comment 用不同 header
    path: ${{ runner.temp }}/plan-output.md
```

### 2. 開測試 PR

複製 Lab 04a 的測試模式：

```bash
cd ~/GitHub/tofu-terramate-lab
git checkout -b lab04c/pr-plan-comment
# 改一個 dev stack 觸發 plan diff，例：在 stacks/dev/network/main.tf 加一行 comment
git add . && git commit -m "test: lab04c trigger plan diff" && git push -u origin lab04c/pr-plan-comment
gh pr create --title "test: lab04c pr plan comment" --body "驗證 plan 結果是否回寫 PR comment"
```

### 3. 驗證

PR 出現後檢查：

- [ ] PR conversation tab 有一則 bot comment，標題為 `## Tofu Plan Results`
- [ ] Comment 含每個 changed stack 的 `### Stack: stacks/...` 區塊與 plan 輸出
- [ ] Plan 輸出格式正常（無 ANSI escape 亂碼）
- [ ] 推第二個 commit 後 comment 被**更新**（同一則），不是新增一則

### 4. 邊界測試

#### 4a. Plan fail 時仍貼 comment

故意改 `stacks/dev/network/main.tf` 寫一段會讓 `tofu plan` fail 的內容（例：引用不存在的 resource），推 commit。預期：

- plan job 顯示 fail
- comment 仍更新，內容包含錯誤訊息

#### 4b. 無 changed stack

直接改 `.github/workflows/opentofu.yml` 內某 comment（不動 stack），推 commit。預期：

- comment 內容為 `_No stacks changed in this PR._`

### 5. 清理

驗證完關 PR、刪 branch、本地 prune。

---

## 驗證清單

- [ ] PR 出現 sticky comment（header `tofu-plan`）
- [ ] 多個 changed stack 各自有 `### Stack:` 區塊
- [ ] 無 ANSI 亂碼
- [ ] 第二次 push 更新同一則 comment
- [ ] Plan fail 時仍貼 comment，內含錯誤
- [ ] 無 changed stack 時 comment 顯示 fallback 文字
- [ ] 大型輸出觸發截斷（可選，難在實驗環境造出）

---

## 風險與回退

- **Plan-output 檔案位置**：⚠️ **必須寫到 `${{ runner.temp }}` 而非 workspace**。`terramate run` 有 git-untracked safeguard，workspace 內出現 untracked 檔案會 fail（`Error: repository has untracked files`）。runbook 內所有 `${{ runner.temp }}/plan-output.md` 路徑都用 `${{ runner.temp }}` 前綴。
- **Comment 超過 65,536 字元**：本 runbook 已做 60,000 字元截斷 + 連結回 Actions log。
- **`marocchino/sticky-pull-request-comment` 第三方信任**：pin 到 v2 major tag；若有疑慮可改 commit SHA pin。
- **PR 從 fork 提交**：本實驗 repo 無 fork PR 場景。若未來有，`pull-requests: write` 不會給 fork PR 的 token，sticky comment 會 fail（可接受）。
- **回退**：移除 sticky comment step、恢復原本 `tofu plan` 命令、移除 `pull-requests: write`。

---

## 下一步

- Lab 04f：WIF condition 收斂
- Lab 04d：scheduled drift detection（drift comment 用不同 sticky header，與 plan comment 共存）
