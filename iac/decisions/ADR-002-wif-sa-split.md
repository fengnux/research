---
status: 已採用
date: 2026-05-16
---

# ADR-002 — WIF SA 拆分為 plan / apply / drift 三個

## 背景

CI pipeline 需要對 GCP 做三種操作，權限需求各不相同：
- **plan**：唯讀，只需要 `viewer` 類權限
- **apply**：讀寫，需要 `editor` 類權限，風險最高
- **drift detection**：唯讀，類似 plan 但由 schedule 觸發

最初考慮用單一 SA 跑所有操作，簡化 IAM 設定。

## 決策

建立三個獨立 SA，各自綁定對應的 WIF OIDC subject condition：

| SA | Subject condition | 權限 |
|---|---|---|
| `github-actions-tofu-plan` | `repo:.../pull_request` | 唯讀 |
| `github-actions-tofu` | `repo:.../environment:production` | 讀寫 |
| `github-actions-tofu-drift` | `repo:.../ref:refs/heads/main` | 唯讀 |

Apply SA 額外要求 GitHub Environment `production`（需人工 approve）才能取得憑證。

## 考慮過的替代方案

- **單一 SA**：設定簡單，但 PR plan job 拿到跟 apply 一樣的寫入權限，最小權限原則違反
- **plan / apply 兩個 SA**：drift 共用 plan SA 可行，但 subject condition 不同（schedule 無法用 `pull_request` trigger），需要額外開 condition 或放寬限制

## 後果

- IAM 設定較複雜，多三個 SA + 三組 WIF binding
- Apply 走 environment approval gate，多一道人工確認
- ⚠️ Apply workflow 若移除 `environment: production` 設定，subject 不符 WIF condition，apply 會失敗，需同步更新 WIF binding
