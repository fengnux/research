# Turbot 工具鏈調研筆記

> 調研日期：2026-05-18　狀態：評估中

## 工具概覽

Turbot 開源的四個工具形成完整的雲端資源可觀測性 + 自動化工具鏈：

| 工具 | 定位 | 核心技術 |
|---|---|---|
| **Steampipe** | Live 雲端資源查詢 | PostgreSQL + plugin（GCP/AWS/Azure...） |
| **Powerpipe** | 合規 benchmark + dashboard | 跑在 Steampipe 之上，HCL mod 定義 |
| **Flowpipe** | Pipeline 自動化 / 輕量 SOAR | HCL 定義 pipeline，可呼叫 API、送通知 |
| **Tailpipe** | Log 時序分析 | DuckDB + Parquet（本地 / GCS） |

全部開源免費，可本地跑，不需要 SaaS 訂閱。

## 各工具對應的 Use Case

### Steampipe — 查詢當前 GCP 資源狀態

- GCP plugin 將 GCP API 包成 PostgreSQL table（`gcp_storage_bucket`、`gcp_compute_instance`、`gcp_iam_binding` 等）
- 直接 SQL 查詢，不用自己呼叫 `gcloud` 再解 JSON
- 與 Terraform state 做 diff → 找出 unmanaged resource

```sql
-- 範例：列出所有 GCS bucket（含建立時間、public access 設定）
select name, location, public_access_prevention, time_created
from gcp_storage_bucket
where project = 'research-lab-495809';
```

### Powerpipe — 合規報告 / Evidence Pack

- 現成 mod：`gcp_compliance`（支援 CIS GCP 1.3、NIST 800-53、PCI-DSS）
- `powerpipe benchmark run gcp_compliance.benchmark.cis_v130` 直接輸出 HTML / JSON 報告
- 報告可直接作為稽核材料（evidence pack 的一部分）

### Flowpipe — 自動化 / SOC 整合

- HCL 定義 pipeline：query Steampipe → 判斷條件 → 觸發動作
- 對應場景：發現 unmanaged resource → POST 到 SCC Custom Findings → 通知 Slack
- 可取代手寫 Python/bash webhook script

```hcl
# 概念示意（非完整語法）
pipeline "notify_unmanaged" {
  step "query" "find_unmanaged" {
    sql = "select name from gcp_storage_bucket where ..."
  }
  step "http" "post_to_scc" {
    url    = "https://securitycenter.googleapis.com/..."
    method = "POST"
  }
}
```

### Tailpipe — Log 時序快照 / 歷史稽核

- 從 GCP Audit Log 等來源抓 log，存成 Parquet（本地或 GCS），查詢層用 DuckDB
- 回答「這個資源什麼時候出現的？」「上週新增了哪些 unmanaged？」
- 與先前討論的「Asset Inventory 每次快照 → Parquet → DuckDB」架構一致，Tailpipe 原生就是這樣設計的
- Steampipe = live 狀態；Tailpipe = 歷史時序

## 與現有方案的對比

| 需求 | 自寫方案 | Turbot 工具鏈 |
|---|---|---|
| Unmanaged resource diff | `gcloud asset` + shell script | Steampipe SQL |
| 合規報告 | 手動整理 evidence pack | Powerpipe benchmark output |
| 推 SCC findings / 通知 | Python script + HTTP | Flowpipe pipeline |
| Log 時序 / 歷史稽核 | DuckDB + Parquet（自建） | Tailpipe（原生支援） |

自寫方案彈性最高；Turbot 工具鏈降低初始開發成本，但多一層外部依賴。

## 待評估項目

- [ ] GCP plugin 對 Asset Inventory / custom resource type 的涵蓋率
- [ ] Tailpipe GCP Audit Log source 是否支援直接串 Cloud Logging sink
- [ ] Flowpipe 呼叫 GCP SCC API 的認證方式（能否沿用 WIF？）
- [ ] Powerpipe CIS GCP 1.3 mod 的覆蓋範圍 vs 我們實際用的 GCP 服務
- [ ] 本地跑 vs CI 跑的操作模式差異

## 相關文件

- [lab-scc-custom-findings.md](../labs/lab-scc-custom-findings.md) — SCC Custom Findings PoC（Flowpipe 可取代其中的 script 部分）
- [toolchain.md](toolchain.md) — 現有 IaC 工具選型
