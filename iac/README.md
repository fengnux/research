# iac 導覽

GCP + OpenTofu + Terramate 實驗環境的知識文件。

## 目錄結構

```
iac/
├── decisions/   架構決策紀錄（為什麼這樣設計）
├── docs/        技術參考（是什麼、怎麼運作）
├── labs/        實驗 runbook（怎麼操作、步驟順序）
├── logs/        每日執行日誌（什麼時候做了什麼）
└── opentofu/    ← 已移至 tofu-terramate-lab repo（僅留 _modules/）
```

## 各層定位

| 目錄 | 回答的問題 | 適合查閱時機 |
|---|---|---|
| `decisions/` | 為什麼這樣決定？考慮了哪些替代方案？ | 對某個設計感到疑惑時 |
| `docs/` | 這個工具/概念是什麼？怎麼運作？ | 需要技術背景知識時 |
| `labs/` | 這件事怎麼一步步做？ | 要執行或重現某個實驗時 |
| `logs/` | 那天實際發生了什麼？ | 回溯問題或查執行紀錄時 |

## decisions/ — 架構決策紀錄

| 文件 | 決策 |
|---|---|
| [ADR-001 不 commit lock file](decisions/ADR-001-no-lock-file.md) | `.terraform.lock.hcl` 不進 git，避免跨平台 hash diff 觸發 Terramate safeguard |
| [ADR-002 WIF SA 拆分](decisions/ADR-002-wif-sa-split.md) | plan / apply / drift 三個獨立 SA，最小權限原則 |
| [ADR-003 Foundational stacks 排除 CI](decisions/ADR-003-foundational-stacks-excluded-from-ci.md) | bootstrap / WIF stack 不讓 CI 自動 apply，避免 chicken-and-egg |
| [ADR-004 SCC Standard tier](decisions/ADR-004-scc-standard-tier.md) | 不啟用 Premium，Custom Findings 在 Standard 就夠用 |

## docs/ — 技術參考

| 文件 | 內容 |
|---|---|
| [toolchain.md](docs/toolchain.md) | 工具選型、三層版本鎖定機制 |
| [state-backend.md](docs/state-backend.md) | GCS state bucket 安全基線、state 路徑慣例 |
| [terramate-patterns.md](docs/terramate-patterns.md) | repo 結構、generate_hcl、tm_ 函式用法 |
| [terramate-change-detection.md](docs/terramate-change-detection.md) | change detection 機制、main-only 盲點 |
| [gcp-auth.md](docs/gcp-auth.md) | ADC vs SA、API 啟用 |
| [iap.md](docs/iap.md) | IAP TCP forwarding 原理與流量路徑 |
| [workload-identity-federation.md](docs/workload-identity-federation.md) | GitHub Actions OIDC → GCP WIF 身份模型 |
| [turbot-toolchain.md](docs/turbot-toolchain.md) | Steampipe / Powerpipe / Flowpipe / Tailpipe 調研筆記 |

## labs/ — 實驗 Runbook

| 文件 | 狀態 |
|---|---|
| [lab-01 環境準備](labs/lab-01-environment-setup.md) | ✅ 完成 |
| [lab-02 Bootstrap](labs/lab-02-bootstrap.md) | ✅ 完成 |
| [lab-03a State 遷移](labs/lab-03a-state-migration.md) | ✅ 完成 |
| [lab-03b 第一個 dev stack](labs/lab-03b-first-dev-stack.md) | ✅ 完成 |
| [lab-03c Dev VM](labs/lab-03c-dev-vm.md) | ✅ 完成（VM 已 destroy） |
| [lab-04 CI Pipeline](labs/lab-04-ci-pipeline.md) | ✅ 完成 |
| [lab-04a Apply Approval Gate](labs/lab-04a-apply-approval-gate.md) | ✅ 完成 |
| [lab-04b Plan/Apply SA 拆分](labs/lab-04b-plan-apply-sa-split.md) | ✅ 完成 |
| [lab-04c PR Plan Comment](labs/lab-04c-pr-plan-comment.md) | ✅ 完成 |
| [lab-04d Drift Detection](labs/lab-04d-drift-detection.md) | ✅ 完成（schedule 暫停） |
| [lab-04e Security Scan](labs/lab-04e-security-scan.md) | ✅ 完成 |
| [lab-04f WIF Condition 收斂](labs/lab-04f-wif-condition.md) | ✅ 完成 |
| [lab-04h Dependabot](labs/lab-04h-dependabot.md) | ✅ 完成 |
| [lab-05a VPC Module + 階層化 globals](labs/lab-05a-vpc-module-hierarchical-globals.md) | ✅ 完成 |
| [lab-05b GKE Autopilot Module + IAP bastion](labs/lab-05b-gke-module.md) | 📝 規劃中 |
| [lab-scc-custom-findings](labs/lab-scc-custom-findings.md) | 草稿／評估中 |
| [evidence-pack-overview](labs/evidence-pack-overview.md) | 進行中 |

## logs/ — 執行日誌

每日紀錄：`logs/YYYY-MM-DD.md`

最新：[2026-05-19](logs/2026-05-19.md)
