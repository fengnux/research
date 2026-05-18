---
status: 已採用
date: 2026-05-16
---

# ADR-003 — Foundational stacks 排除 CI 自動 apply

## 背景

Repo 中有兩個特殊 stack：
- `stacks/bootstrap`：管理 GCS state bucket（所有其他 stack 的 state 存放位置）
- `stacks/ci/github-actions-wif`：管理 CI 的 WIF pool、provider、SA、IAM binding

這兩個 stack 是整個 CI pipeline 的根基。若 CI 自動 apply 這兩個 stack，存在 chicken-and-egg 風險：
CI 修改了讓自己能運作的 WIF 設定 → apply 失敗 → CI 無法再跑。

## 決策

兩個 stack 加上 `tags = ["foundational"]`，所有 CI workflow 加 `--no-tags foundational` 跳過。
另外加 `detect-foundational-changes` job：偵測到這兩個 stack 有變更時發出警示，但不 fail pipeline。
Foundational stack 的變更一律在本地用個人帳號手動 apply。

## 考慮過的替代方案

- **完全不放進 IaC**：bootstrap 資源不用 IaC 管，直接 console 建。
  → 違反 IaC 原則，難以重建，不採用
- **獨立 pipeline 跑 foundational**：另開 workflow，只跑 foundational stacks，需更高權限 SA。
  → 過度複雜，lab 規模不值得，未來規模大了再考慮

## 後果

- Foundational stack 的變更需要人工本地 apply，不能完全自動化
- 警示 job 讓 PR reviewer 知道有 foundational 變更需要注意
- Bootstrap state bucket 本身的 state 存在 local（bootstrap 無法用自己管理的 bucket 存自己的 state）
