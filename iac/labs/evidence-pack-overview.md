# evidence-pack — 可視化 與 稽核材料產出

> **代號 `evidence-pack`**。正式 lab 編號待此實驗排上日程時再決定（可能不會是 06）。

## 主題

把現有 IaC pipeline（Lab 01–05）產出的訊號（plan / apply / drift / Trivy / Dependabot / IAM / asset）整合成**可拿出去交給真實稽核員**的製品。

## 受眾與情境

模擬「準備迎接真實稽核員」：對 SOC2 / ISO27001 / 內部稽核常問的問題（變更管控、存取控制、資產清冊、異常偵測），準備可直接附在 evidence package 的 artifact。

## 路線

Lab 04 系列已建立的訊號 散在 GitHub Actions log 與 GCP console。本 phase 走兩條互補路線整合：

| 路線 | 證據類型 | 主工具 |
|------|---------|--------|
| **A. Terramate Cloud** | 變更管控（who/when/what/approval/plan/apply）| Terramate Cloud free tier |
| **C. GCP-native** | 資產與權限（inventory / IAM / audit logs）| Cloud Asset Inventory + Cloud Audit Logs |

A + C 為核心，最終由 capstone 整合輸出單一月度報告。

## Lab 排序

### evidence-pack-a — Terramate Cloud 接線 + 變更管控證據

**範圍**
- 註冊 Terramate Cloud free tier、安裝 GitHub App
- CI workflow 加 `terramate cloud` hooks（plan / apply / drift）
- 累積 deployment / drift 資料

**產出**
- `audit/changes/2026-MM.md`：dashboard 截圖索引 + 對應稽核問題說明
- 每張截圖標註：來源（哪個 dashboard）、時間範圍、回答的稽核問題

**回答的稽核問題**
- 「過去 30 天每個 production 變更：誰提的、誰 approve、plan 結果、apply 何時、是否 drift」

**free-tier 注意**：先驗 free tier 能否覆蓋全部需求；若有 paid-only 功能（如長期 retention），在 lab 結論寫實際限制。

---

### evidence-pack-b — GCP Asset Inventory + ownership label

**範圍**
- 啟用 Cloud Asset Inventory
- 每日 snapshot export → GCS（不上 BigQuery 省成本）
- 訂 ownership label 規範：補 `owner` / `cost_center` / `data_classification`（現有 `managed_by` 已有）
- 寫腳本從 snapshot 產出資產清冊 markdown 表

**產出**
- `audit/inventory/2026-MM-DD.md`（自動每日更新）
- 含 resource 種類 / count / ownership / 最後修改 timestamp

**回答的稽核問題**
- 「production 環境現在有哪些資產、誰負責、是否都有標準 label」

**成本注意**：snapshot 量 ~KB 級，GCS 月費接近 $0。

---

### evidence-pack-c — Cloud Audit Logs + IAM access audit

**範圍**
- 確認 Admin Activity audit log 啟用、retention 400 天（GCP 預設，免費）
- 不啟 Data Access logs（量大會收費）
- 用 `gcloud asset iam-policy-analyzer` 產 IAM 矩陣
- 寫腳本篩過去 30 天 IAM-related audit log

**產出**
- `audit/access/2026-MM.md`：
  - IAM 矩陣（who-has-what-on-what）
  - IAM 變更 log（role binding 改動、SA key 建立等）
  - 異常存取標記（如下班時間 admin operation）

**回答的稽核問題**
- 「誰能改 production、最近誰做了什麼 admin operation、有無異常」

---

### evidence-pack-d — 月度稽核報告 capstone

**範圍**
- GitHub Actions 月初排程整合：
  - evidence-pack-a artifact（變更管控 dashboard 截圖）
  - evidence-pack-b artifact（資產清冊）
  - evidence-pack-c artifact（IAM 矩陣 + access log）
  - GitHub PR API（merge 統計、approver 列表）
  - Trivy SARIF 趨勢、Dependabot SLA
- markdown → PDF（可直接交人）

**產出**
- `audit/monthly/2026-MM.md` + 對應 PDF
- 一份檔案、可送進真實稽核 evidence package

---

## 範圍 / 成本表

| 項目 | 風險 | 緩解策略 |
|------|------|---------|
| Terramate Cloud free tier | 是否吃到功能限制？ | evidence-pack-a 結論章節寫實際遇到的限制 |
| GCP Asset Inventory | 可能 query/storage 費用 | snapshot 量小、用 GCS 不用 BigQuery |
| Audit Logs Admin Activity | 永久免費保留 400 天 | 不啟 Data Access logs |
| IAM Recommender | 需 enable `recommender.googleapis.com` | 確認 free quota |
| 報告 PDF 化 | pandoc / weasyprint 等依賴 | evidence-pack-d 時再決定（markdown 也已夠用） |

## 設計原則

1. **每個 lab 都產出可獨立使用的 artifact**：不依賴後續 lab 完成
2. **artifact commit 進 repo**：版本控制 + 自動更新 vs 每次手生
3. **與既有 lab 解耦**：不改動已 apply 的 stack 結構，只新增 audit/ 目錄與 scripts
4. **稽核問題驅動**：每個產出明確標註「回答什麼稽核問題」，避免做了沒人用的 viz

## 不在 evidence-pack 範圍

- 成本管理（Infracost、GCP billing dashboard）— 另開代號（如 `cost-insight`）候選
- 即時告警 / oncall（PagerDuty 等）— 另開代號候選
- VPC Flow Logs / Firewall Logs 視覺化 — 範圍過大，必要時另立代號
- 第二個 GCP project / 真實 multi-env — evidence-pack 假設仍是 dev 單環境，多 env 來自 Lab 05a 範本

## 與其他 lab 的關係

- **依賴 Lab 04 系列**：04a approval gate / 04d drift / 04e Trivy / 04h Dependabot 都是訊號源
- **依賴 Lab 05a**：module 化讓 evidence-pack-b 的「per-module 資產清冊」分組更乾淨
- **不阻塞 Lab 05b**：05b（script block）獨立進行
