---
status: 已採用
date: 2026-05-27
---

# ADR-001 — Evidence Pack 系列獨立目錄 `audit/`、與 `iac/` 並列

## 背景

evidence-pack 系列（原規劃放在 `iac/labs/evidence-pack-*.md`）的本質是**消費** IaC 與 GCP 環境產出的訊號（SARIF、Asset Inventory、Audit Logs、PR 統計），輸出稽核製品（markdown 報表、SQL artifact、可視化）。

跟 `iac/` 對比：

| 面向 | iac/ | evidence-pack |
|------|------|---------------|
| 主題 | 蓋 GCP infra | 消費訊號產出稽核製品 |
| 工具鏈 | OpenTofu / Terramate / gcloud | DuckDB / SQL / markdown / HTML |
| 產出 | GCP 資源 + state | markdown report + SQL view + artifact |
| 依賴 | GCP API | iac/ 的 CI 訊號 + GCP export |

兩者是**生產/消費**關係，不是 IaC 的子主題。同時，未來若擴出 FinOps / SLO / Cost 等子題，也都會落在「消費 infra 訊號」這條軸，跟 IaC 主軸越離越遠。

如果繼續放 `iac/labs/evidence-pack-*.md`：
- 對未來讀者語意混淆（「這是 IaC lab 嗎？」其實不是）
- ADR 軸混在一條，IaC 跟 evidence 決策互相干擾
- 工具鏈差異（OpenTofu vs DuckDB）會讓 `iac/docs/` 變雜物倉

## 決策

新增 `audit/` 目錄，跟 `iac/` 並列，承接 evidence-pack 系列。

### 1. 目錄結構

```
research/
  iac/       ← 既有，OpenTofu/Terramate 系列
  audit/     ← 新增
    docs/
    labs/
    decisions/
    sql/
    artifacts/
  logs/      ← 從 iac/logs/ 提升到 repo 根（per 本 ADR 同時生效）
```

### 2. ADR 軸獨立

`audit/decisions/` 從 `ADR-001` 重新編號。**不** 接續 `iac/decisions/ADR-005`。
理由：決策上下文不同，獨立編號軸比共用編號軸清楚；半年後 review 兩邊不會搞混。

### 3. logs/ 提升到 repo 根

原 `iac/logs/` 內容是每日跨專案日誌（per [研究 repo 慣例](../../iac/README.md)），實際內容不限於 IaC。順勢提升到 `logs/`，未來 evidence-pack 系列的日誌也記在同一處，不再二分。

文件內既有相對路徑（如 `../logs/2026-05-20.md`）統一修正。

### 4. Cross-link 慣例

- audit/ 指回 iac/：相對路徑 `../iac/labs/lab-04e-security-scan.md`
- iac/ 指向 audit/：同樣相對路徑（少見，但有時 ADR 會反向引）
- ADR 在 `## Related` section 列關聯文件
- 同 repo 內**不用** GitHub URL，保持 markdown 可移植

### 5. 命名

選用 `audit/` 而非 `evidence/`、`governance/`：
- 跟 `evidence-pack-overview.md` 內既有 path（`audit/inventory/`、`audit/access/`、`audit/monthly/`）一致，無命名摩擦
- 「audit」比「evidence」窄但更具體；未來若加 FinOps 主題，可在 `audit/` 內加 `cost/` subdir，或視擴張幅度再決定要不要分新 top-level dir
- `governance/` 過於官腔，且範圍涵蓋 IaC + audit 兩邊，反而模糊邊界

## 考慮過的替代方案

### A. 繼續放 `iac/labs/evidence-pack-*.md`

- 優點：最小改動
- 拒絕原因：語意混淆、ADR 軸難切、未來擴張會更痛

### B. 用 `evidence/` 命名

- 優點：中性、未來放 cost report 也合理
- 拒絕原因：跟 evidence-pack-overview.md 既有 path 不一致，要連帶改變數命名

### C. 把 `iac/` 跟 `audit/` 都收進 `platform/` 或 `research-topic/` 一層

- 優點：結構整齊
- 拒絕原因：過度抽象；目前只有兩個主題，多一層折疊看不出價值；CLAUDE.md 慣例「v1 跟現狀 1:1」反對提前抽象

### D. 開獨立 repo

- 優點：完全隔離
- 拒絕原因：cross-link 變 GitHub URL 太脆弱；evidence-pack 仍緊密依賴 iac/ 的訊號與環境，分 repo 增加摩擦

## 後果

- 所有 evidence-pack 相關文件路徑變更：原 `iac/labs/evidence-pack-overview.md` 後續搬入 `audit/labs/`（v1 暫留原地避免一次太多移動，foundation lab 完成後再搬）
- 日誌路徑變更：`iac/logs/` → `logs/`，現有引用一次修補
- 多一個目錄要維護，但結構價值 > 維護成本

## 觀察指標

開新 ADR 或調整本 ADR 的訊號：

- `audit/` 子目錄變多到需要再分（如出現 `audit/cost/`、`audit/slo/` 且互不相干）
- iac ↔ audit cross-link 失效率（mv/rename 沒同步）超過月度 1 次 → 寫一個 link-check 腳本進 CI

## 相關

- [audit/README.md](../README.md)
- [ADR-002 DuckDB + Bearer token 認證選型](ADR-002-duckdb-query-engine.md)
- [ADR-003 Evidence bucket 分離](ADR-003-evidence-bucket-separation.md)
- [iac/labs/evidence-pack-overview.md](../../iac/labs/evidence-pack-overview.md)
