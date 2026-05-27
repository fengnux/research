# research

SRE / DevOps / Security 技術研究文件庫。

記錄 GCP 實驗環境的架構決策、實驗步驟與執行日誌。當前兩條主軸：

- **iac/** — GCP + OpenTofu + Terramate 基礎建設（Lab 01–05b 已完成）
- **audit/** — Evidence Pack：消費 IaC 與 GCP 訊號產出稽核製品（DuckDB + SQL；2026-05-27 啟動）

兩者是**生產/消費**關係並列，不是從屬：iac/ 蓋 infra 產訊號，audit/ 消費訊號產 evidence。

## 結構

```
research/
├── iac/         OpenTofu + Terramate 主軸（decisions/ docs/ labs/）
├── audit/       Evidence Pack 主軸（decisions/ docs/ labs/ sql/ artifacts/）
└── logs/        每日執行日誌（跨主軸共用，YYYY-MM-DD.md）
```

詳細導覽：

| 路徑 | 內容 |
|------|------|
| [iac/README.md](iac/README.md) | IaC 系列：ADR、技術參考、Lab 01–05b runbook |
| [audit/README.md](audit/README.md) | Evidence Pack 系列：ADR、Lab runbook、SQL artifact |
| [logs/](logs/) | 每日執行日誌 |

## 相關 Repo

- [tofu-terramate-lab](https://github.com/fengnux/tofu-terramate-lab) — 實際的 IaC 設定檔（stacks、modules、config）
