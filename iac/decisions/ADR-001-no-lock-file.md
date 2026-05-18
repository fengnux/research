---
status: 已採用
date: 2026-05-10
---

# ADR-001 — 不 commit `.terraform.lock.hcl`

## 背景

CI 跑在 Linux runner（`linux_amd64`），本機開發在 macOS（`darwin_arm64`）。
`tofu init` 會依執行平台補對應的 provider binary hash 到 lock file，
導致 CI 跑完後 lock file 出現 `linux_amd64` hash diff，
觸發 Terramate 的 `git-uncommitted` safeguard，CI pipeline 中斷。

## 決策

`.terraform.lock.hcl` 加入 `.gitignore`，不 commit 進 repo。
Provider 版本可重現性僅靠 `config.tm.hcl` globals 的 `~> X.Y.Z` constraint。

## 考慮過的替代方案

- **多平台 lock**：CI 跑 `tofu providers lock -platform=linux_amd64 -platform=darwin_arm64`
  → 可行，但每個 stack 都要跑，CI 時間增加，且新增 stack 時容易遺漏
- **只 commit mac lock，CI 加 `-lockfile=readonly`**
  → lock file 缺 linux hash 會讓 readonly 模式報錯
- **CI 跑完後 commit lock file back**
  → 會觸發 push，造成 workflow loop，且 lock file 是 binary hash，diff 難以 review

## 參考

Terramate 官方 example repo 也採用同樣做法（不 commit lock file）。

## 後果

- 沒有 lock file 的 provider binary hash 驗證（供應鏈風險小幅提升，接受）
- CI 每次重新解析 version constraint（constraint 用 `~> X.Y.Z` 夠窄，可接受）
- 新成員不會拿到 lock file，`tofu init` 後本地產生的 lock file 不會被誤 commit
