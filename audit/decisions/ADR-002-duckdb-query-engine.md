---
status: 已採用
date: 2026-05-27
---

# ADR-002 — DuckDB 為 Evidence Pack Query Engine + Bearer Token 認證

## 背景

Evidence pack 的資料源都是 semi-structured exports：

| 資料源 | 格式 | 位置 |
|--------|------|------|
| Trivy SARIF | JSON（巢狀深）| GitHub Code Scanning + 預計 export GCS |
| GCP Asset Inventory | JSON / Parquet | GCS |
| Cloud Audit Logs sink | JSON（NDJSON）| GCS |
| GitHub PR / Actions / Dependabot | JSON | API on demand |
| Trivy SARIF / Dependabot 趨勢 | JSON | 上述累積 |

需要：

1. **跨來源 JOIN**（SARIF × Asset × Audit Log）做月報
2. **趨勢分析**（過去 N 月 finding 變化、MTTR）— GitHub Code Scanning UI 弱項
3. **可重現性**（同樣 SQL 重跑 = 同樣結果）
4. **低 ops 成本**（單人研究 lab，不想養 BigQuery）
5. **未來搬到 GHA runner / GKE pod 不用改 SQL**

同時跟 Lab 04 系列的「往 WIF / 短期憑證」方向一致 — 不要因為加 query engine 就引入 long-lived credential。

## 決策

### 1. Query Engine：DuckDB

- **角色**：evidence-pack 系列共用的 query engine，獨立 lab `evidence-pack-foundation` 建置
- **版本 pin**：≥ 1.0（`TYPE HTTP` + `EXTRA_HTTP_HEADERS` 需要），實際版本在 foundation lab 決定後寫入
- **安裝**：從 GitHub releases 下載指定版本 binary 放 `~/.local/bin/`，跟 Lab 04e trivy 同套路；不用 `brew install duckdb`（版本飄）
- **extension**：`httpfs`（讀 HTTPS / GCS）、`json`（內建）

### 2. 認證：Bearer Token via `TYPE HTTP` Secret

DuckDB 對 GCS 三種 auth path：

| Path | 適用 | 拒絕原因 |
|------|------|---------|
| `TYPE GCS` + HMAC key | S3-compat 模式 | long-lived HMAC，反 WIF 方向 |
| `TYPE GCS` + SA JSON | 經典模式 | long-lived SA key file，最嚴重的反方向 |
| **`TYPE HTTP` + Bearer token** | 任何短期 token | **採用** |

具體 SQL pattern：

```sql
CREATE SECRET gcs_token (
  TYPE HTTP,
  EXTRA_HTTP_HEADERS MAP {
    'Authorization': 'Bearer ' || getenv('GCS_TOKEN')
  }
);

SELECT * FROM read_json_auto(
  'https://storage.googleapis.com/<bucket>/<prefix>/*.json'
);
```

Token 取得：

| 場景 | 取 token 方法 | 性質 |
|------|---------------|------|
| Local mac | `gcloud auth application-default print-access-token` | ADC 短期 token (~1h) |
| GKE pod（WI 啟用後）| 同上 / metadata server | WI 換來的短期 token |
| GHA runner（Lab 04 WIF）| `gcloud auth print-access-token`（WIF 換完後）| WIF 短期 token |

**三場景 SQL 完全一致，差別只在 `$GCS_TOKEN` 怎麼來。** 這是這個 pattern 最大的價值 — foundation lab 在 local 驗證的東西，未來搬 GHA runner（evidence-pack-d 月報）或 GKE CronJob 通通不用改 SQL。

### 3. SQL artifact 結構

```
audit/
  sql/
    views/        # 共用 view（SARIF normalized、IAM events normalized 等）
    queries/      # 一次性查詢（月報、ad-hoc）
    bootstrap.sql # CREATE SECRET、安裝 extension（每次 session 跑）
```

每個 view / query 配一份 README 註明：輸入（資料源 prefix）、輸出（schema）、回答的稽核問題。

### 4. Trivy SARIF：Hybrid 不替換 GitHub Code Scanning

| 場景 | Code Scanning | DuckDB |
|------|--------------|--------|
| PR diff annotation | ✅ 保留 | ❌ |
| Alert state（open/closed/dismissed）| ✅ 保留 | ❌ |
| 趨勢分析（MTTR、月度新增）| ❌ | ✅ 主路徑 |
| 跨工具 JOIN | ❌ | ✅ |

實作：security-scan workflow 在原本 upload-to-code-scanning 之外，加一步 `gsutil cp` 上 evidence bucket（per [ADR-003](ADR-003-evidence-bucket-separation.md)）。foundation lab 先手動 `gsutil cp` 一份測試資料，workflow 整合在後續 lab 做。

### 5. 同時 drop Terramate Cloud（原 evidence-pack-a）

evidence-pack 原 A 路線（Terramate Cloud）取消，理由：
- Terramate Cloud free tier 只支援 OAuth 登入，跟 lab 身份偏好不合
- A 原本的能力（變更管控 audit）可用 GitHub PR API + Actions API 自行透過 DuckDB 拼出

evidence-pack 系列重排：foundation → b → c → d，原 A 從 overview 移除。

## 考慮過的替代方案

### A. BigQuery 取代 DuckDB

- 優點：原生跟 GCP 整合（CAI / audit log sink 都可直接到 BQ）、無 token 過期問題
- 拒絕原因：on-demand query 按掃描量計費，研究階段不可預測；要學 BQ dialect 跟管 dataset；scale 過大（單人研究月度幾百 MB 用 BQ 是大砲打蚊子）；CI 整合要設 BQ SA、多一條安全邊界
- 未來如果 evidence 量爬到 GB 級或要組織內共享，重新評估

### B. 純 Python pandas / jq 腳本

- 優點：無新工具
- 拒絕原因：跨資料源 JOIN 要自己寫 join logic；累積到一定規模後維護成本高；不能下 SQL 對 query 重用性差

### C. DuckDB + HMAC key

- 優點：DuckDB 原生 `TYPE GCS`，設定簡單
- 拒絕原因：long-lived credential，反 Lab 04 WIF 方向；跟未來 GKE pod / GHA runner 共用 pattern 不一致

### D. DuckDB + SA JSON key

- 同 C，且 SA key 比 HMAC 更敏感（compromise → SA 全部權限）

### E. ClickHouse / Trino / Druid

- 過度工程：要架 server / cluster，evidence-pack 單機就夠

## 後果

- 加一個工具到 toolchain（DuckDB），維護成本低（單檔 binary）
- SQL 變成 evidence-pack 主要 artifact 類型，需要在 audit/sql/ 累積慣例
- Token 過期（~1h）需要 wrapper 腳本（foundation lab 處理）
- 未來 GKE pod 跑 evidence query 已預先 enable（共用 SQL）

## 觀察指標

重審本 ADR 的訊號：

- DuckDB 1.x → 2.x major version 出現破壞性變更
- evidence 月度資料量超過 10 GB（本機 query 開始吃力）
- 出現多人協作需求（多人共用一份 query result 要 cache）→ 考慮加 BigQuery 或 dbt-duckdb
- Bearer token wrapper 變成痛點（如多人共用、權限切細）

## 相關

- [ADR-001 目錄分離](ADR-001-audit-directory-separation.md)
- [ADR-003 Evidence bucket 分離](ADR-003-evidence-bucket-separation.md)
- [iac/decisions/ADR-002 WIF SA 拆分](../../iac/decisions/ADR-002-wif-sa-split.md) — 同樣的短期憑證哲學
- [iac/docs/workload-identity-federation.md](../../iac/docs/workload-identity-federation.md)
- 預計：`audit/labs/evidence-pack-foundation.md`
