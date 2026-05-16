# Lab 04f - WIF Condition 收斂：限定 ref 到 main / PR

## 目標

把 WIF provider 的 `attribute_condition` 從只檢查 `repository` 收緊到同時限制 ref，確保只有以下情境可取得 GCP 憑證：

1. Push 到 `main` branch（`apply` job）
2. 針對 `main` 的 Pull Request（`plan` job）

其他 branch 的直接 workflow dispatch 或 cron 均無法通過 WIF 驗證。

## 為什麼要做

現況：`attribute_condition` 只驗證 `assertion.repository == 'fengnux/tofu-terramate-lab'`。這表示同一 repo 下任意 ref（包含任意 feature branch 的手動 workflow dispatch）都能拿到 SA impersonation token，攻擊面比實際需求大。

改善後：`main` push 與 PR event 才能通過條件，與 workflow `on:` trigger 形成雙層防線。

## 前置條件

- Lab 04、04a、04c 完成
- 本機 ADC 有修改 WIF pool provider 的權限（`roles/iam.workloadIdentityPoolAdmin` 或 `roles/owner`）
- `tofu-terramate-lab` 本地 repo 為最新狀態（`git pull`）

---

## 變更範圍

**唯一需要改的檔案：**
`stacks/ci/github-actions-wif/main.tf`

不需要改 workflow（`.github/workflows/opentofu.yml`），不需要改 Terramate 設定。

---

## 步驟

### 1. 修改 `main.tf`

將 `google_iam_workload_identity_pool_provider.github` 的 `attribute_condition` 從：

```hcl
attribute_condition = "assertion.repository == '${local.github_repo}'"
```

改為：

```hcl
attribute_condition = "assertion.repository == '${local.github_repo}' && (assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/pull/'))"
```

**條件說明：**

| 情境 | `assertion.ref` 值 | 通過？ |
|------|-------------------|--------|
| Push to `main` | `refs/heads/main` | ✅ |
| PR event（any PR to main） | `refs/pull/{n}/merge` | ✅ |
| Feature branch dispatch | `refs/heads/feat/xxx` | ❌ |
| Tag push | `refs/tags/v1.0` | ❌ |
| Cron / schedule（non-main） | `refs/heads/main` 或其他 | 依 ref |

> `assertion.ref` 來自 GitHub Actions OIDC token 的 `ref` claim，對應 `github.ref`。

### 2. commit + push（到 main）

```bash
cd ~/GitHub/tofu-terramate-lab
git add stacks/ci/github-actions-wif/main.tf
git commit -m "security(wif): tighten attribute_condition to main branch and PRs only"
git push
```

> 這個 commit 會觸發 main push workflow，但 `detect-foundational-changes` job 會印出 warning（WIF stack 變更需本機 apply），CI 不 fail。apply job 也會 skip（`--no-tags foundational`）。

### 3. 本機 re-apply WIF stack

```bash
cd ~/GitHub/tofu-terramate-lab
terramate run --tags wif -- tofu plan
```

確認 plan 輸出只有一個 resource change：
```
~ resource "google_iam_workload_identity_pool_provider" "github" {
    ~ attribute_condition = "assertion.repository == ..." -> "assertion.repository == ... && (...)"
}
```

確認無誤後：

```bash
terramate run --tags wif -- tofu apply
```

### 4. 驗證

#### 4a. 確認 WIF provider condition 已更新

```bash
gcloud iam workload-identity-pools providers describe github \
  --workload-identity-pool=github-actions \
  --location=global \
  --project=research-lab-495809 \
  --format="value(attributeCondition)"
```

預期輸出：
```
assertion.repository == 'fengnux/tofu-terramate-lab' && (assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/pull/'))
```

#### 4b. 確認 PR workflow 仍正常（plan job 可取得憑證）

開一個測試 PR（任意修改），確認 plan job 的 `google-github-actions/auth` step 成功。

#### 4c. 確認 main push apply 仍正常

PR merge 後 apply job 的 auth step 成功。

---

## 驗收清單（2026-05-16 驗證通過）

- [x] `main.tf` `attribute_condition` 包含 ref 限制
- [x] `tofu apply` 本機執行成功（1 resource changed）
- [x] `gcloud` 確認 provider condition 已更新
- [x] PR workflow plan job auth 成功（[PR #5](https://github.com/fengnux/tofu-terramate-lab/pull/5)）
- [ ] Main push apply job auth（下次有 non-foundational stack 改動時自動覆蓋驗證）

---

## 風險與回退

| 風險 | 處理方式 |
|------|---------|
| PR plan job auth 失敗（ref claim 格式不符） | 本機立刻 re-apply，把 condition 改回舊值；再查 PR event 實際 `assertion.ref` |
| Apply job auth 失敗 | 同上，rollback condition |
| WIF 傳播延遲 | apply 後等 5 分鐘再重跑 workflow |

**查 `assertion.ref` 實際值的方法：** 在 workflow 加一個暫時 step：
```yaml
- run: |
    curl -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.googleapis.com" \
      | jq -r '.value' | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```
（decode JWT payload，看 `ref` 欄位）

---

## 後續（Lab roadmap 不變）

04f 完成後：04d（drift detection，建議先做 04b）→ 04b（plan/apply SA 拆分）→ 04e → 04g
