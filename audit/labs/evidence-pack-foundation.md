# evidence-pack-foundation — DuckDB + GCS pipeline 建置

## 目標

建立 evidence pack 系列共用的 DuckDB query pipeline。以 Trivy SARIF 為第一個資料源，端到端驗證「GCS 上的 raw export → DuckDB SQL → markdown artifact」。

本 lab 不在本機執行 query pipeline；改用專用 Compute VM `evidence-runner`。本機只負責 repo 編輯、IaC apply 與結果 review，VM 透過 attached service account 取得短期 token，不使用個人 ADC 或 service account key。

驗收條件：
- `evidence-runner` VM 內的 `duckdb` 能透過 attached service account 的 short-lived Bearer token 讀 `gs://research-lab-495809-evidence/sarif/*.sarif.json`
- `audit/sql/views/sarif_findings.sql` 產出一個扁平 `findings` view，row count 跟 SARIF 內 results 數對得上
- `audit/sql/queries/monthly_sarif_summary.sql` 跑出當月 finding by severity / by rule_id 表
- 產出 `audit/artifacts/2026-MM/sarif_summary.md`，內容人工檢視合理

## 設計依據

- [ADR-002 DuckDB + Bearer token](../decisions/ADR-002-duckdb-query-engine.md)
- [ADR-003 Evidence bucket](../decisions/ADR-003-evidence-bucket-separation.md)
- 前置：[evidence-bucket-bootstrap](evidence-bucket-bootstrap.md) 已完成

## 變更檔案總覽

```
research/
├── audit/
│   ├── sql/
│   │   ├── bootstrap.sql                 # 新增：CREATE SECRET、INSTALL/LOAD extension
│   │   ├── views/
│   │   │   └── sarif_findings.sql        # 新增：SARIF → 扁平 findings view
│   │   └── queries/
│   │       └── monthly_sarif_summary.sql # 新增：當月 summary query
│   ├── artifacts/
│   │   └── 2026-06/
│   │       └── sarif_summary.md          # 新增：第一份產出
│   └── docs/
│       ├── duckdb-toolchain.md           # 新增：安裝、版本、wrapper script
│       └── sarif-schema-notes.md         # 新增：SARIF 巢狀結構踩坑筆記
└── evidence-runner VM
    └── ~/.local/bin/duckdb               # 新增（VM）：pinned binary
```

## Phases

### Phase 0：前置確認

- [ ] `evidence-bucket-bootstrap` 已完成、bucket 存在、個人 ADC reader 已設
- [ ] `tofu-terramate-lab/stacks/evidence/runner` 已 plan/apply
- [ ] `evidence-runner` VM 無 public IP，且可透過 IAP SSH 連入
- [ ] VM attached service account `evidence-runner@research-lab-495809.iam.gserviceaccount.com` 已有 evidence bucket `objectViewer` + `objectCreator`
- [ ] VM 內 `gcloud auth print-access-token` 能拿到 attached service account 的短期 token

### Phase 1：啟動並登入 evidence-runner

詳見 [evidence-runner-instance](evidence-runner-instance.md)。

```bash
cd ~/GitHub/tofu-terramate-lab
terramate run --tags evidence-runner -- tofu init
terramate run --tags evidence-runner -- tofu plan
terramate run --tags evidence-runner -- tofu apply

gcloud compute ssh evidence-runner \
  --project research-lab-495809 \
  --zone asia-east1-b \
  --tunnel-through-iap
```

VM 內確認身份：

```bash
gcloud auth list
gcloud auth print-access-token >/tmp/evidence-runner.token
```

預期 active account 是 `evidence-runner@research-lab-495809.iam.gserviceaccount.com`，或 `gcloud auth print-access-token` 能透過 metadata server 取得該 SA token。

### Phase 2：VM 內安裝 DuckDB（pinned）

依 [ADR-002](../decisions/ADR-002-duckdb-query-engine.md) — 從 GitHub releases 下載 pinned binary，不用 brew。

```bash
DUCKDB_VERSION="v1.5.3"   # 執行時最新 stable；版本/SHA 見 audit/docs/duckdb-toolchain.md
ARCH="linux-amd64"        # evidence-runner Debian VM（Trivy 同樣 pin，本次 v0.71.0）
curl -L -o /tmp/duckdb.zip \
  "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-${ARCH}.zip"
unzip /tmp/duckdb.zip -d /tmp/
mkdir -p ~/.local/bin
mv /tmp/duckdb ~/.local/bin/duckdb
chmod +x ~/.local/bin/duckdb
export PATH="$HOME/.local/bin:$PATH"

duckdb --version  # 應顯示 ${DUCKDB_VERSION}
```

寫入 `audit/docs/duckdb-toolchain.md` 記錄：版本、SHA256（從 GitHub release 抓）、安裝路徑、升版流程。

### Phase 3：smoke test — DuckDB 讀公開 HTTPS

驗證 httpfs extension 通：

```sql
INSTALL httpfs;
LOAD httpfs;
SELECT count(*) FROM read_json_auto(
  'https://raw.githubusercontent.com/duckdb/duckdb/main/data/json/example_n.ndjson'
);
```

預期：回傳一個整數。

### Phase 4：VM 內取測試 SARIF 並上 bucket

VM 內安裝 Trivy（版本 pin 寫入 toolchain doc），並 clone 需要掃描的 repo：

```bash
mkdir -p ~/GitHub
cd ~/GitHub
git clone https://github.com/fengnux/tofu-terramate-lab.git
git clone https://github.com/fengnux/research.git

# VM 內重跑一次 trivy 產 SARIF
trivy config --format sarif --output /tmp/test.sarif.json \
  ~/GitHub/tofu-terramate-lab

# 上 bucket（用「測試」前綴避免污染 production prefix）
gsutil cp /tmp/test.sarif.json \
  gs://research-lab-495809-evidence/sarif/2026-06/test-$(date +%Y%m%d-%H%M%S).sarif.json
```

### Phase 5：寫 bootstrap.sql

`audit/sql/bootstrap.sql`：

```sql
-- evidence-pack DuckDB session bootstrap
-- 使用前：export GCS_TOKEN=$(gcloud auth print-access-token)

INSTALL httpfs;
LOAD httpfs;

CREATE OR REPLACE SECRET gcs_token (
  TYPE HTTP,
  EXTRA_HTTP_HEADERS MAP {
    'Authorization': 'Bearer ' || getenv('GCS_TOKEN')
  }
);
```

寫一個 shell wrapper `audit/sql/duckdb-wrap.sh`（chmod +x）：

```bash
#!/usr/bin/env bash
set -euo pipefail
export GCS_TOKEN=$(gcloud auth print-access-token)
exec duckdb -init "$(dirname "$0")/bootstrap.sql" "$@"
```

在 `evidence-runner` 上，`gcloud auth print-access-token` 會透過 metadata server 取得 attached service account 的短期 token。

### Phase 6：smoke test — 讀 bucket SARIF

```bash
audit/sql/duckdb-wrap.sh
```

> ⚠️ **執行修正**：`TYPE HTTP` + bearer token 走 plain HTTPS **不支援 glob（`*`）**——
> 純 HTTPS 無法列舉 bucket。改成「先用 gsutil（SA token）列舉物件 → 把明確 URL 清單
> 注入 DuckDB 變數 `sarif_urls`」。詳見 [sarif-schema-notes](../docs/sarif-schema-notes.md) §2。

先用單一明確 URL 驗證 bearer token 通：

```sql
SELECT count(*) FROM read_json_auto(
  'https://storage.googleapis.com/research-lab-495809-evidence/sarif/2026-06/<物件名>.sarif.json',
  maximum_depth = -1
);
```

預期：1（SARIF 是 single-object JSON，count = 1，不是 result 數）。

如果 401：token 過期，重跑 wrapper。
如果 403：`evidence-runner` service account 缺 `roles/storage.objectViewer` on bucket → 回 `stacks/evidence/runner` IAM binding。

### Phase 7：寫 `findings` view

SARIF schema 巢狀結構：

```
sarif.json
├── runs[]
│   ├── tool.driver.name        ← tool name (trivy)
│   └── results[]
│       ├── ruleId              ← rule_id
│       ├── level               ← severity (error/warning/note/none)
│       ├── message.text
│       └── locations[]
│           └── physicalLocation
│               ├── artifactLocation.uri    ← file path
│               └── region.startLine        ← line number
```

定稿見 [`audit/sql/views/sarif_findings.sql`](../sql/views/sarif_findings.sql)。關鍵：path 不用 glob，改吃變數 `getvariable('sarif_urls')`（清單由 orchestration 先 `SET VARIABLE`，見上方 Phase 6 修正與 [sarif-schema-notes](../docs/sarif-schema-notes.md)）。另解析出 `severity`（從 `message.text` 的 `Severity: XXX`），比 SARIF `level` 更貼稽核語彙。

執行前先注入清單：

```sql
SET VARIABLE sarif_urls = [ 'https://storage.googleapis.com/.../a.sarif.json', ... ];
.read audit/sql/views/sarif_findings.sql
```

驗收：

```sql
SELECT count(*) FROM sarif_findings;  -- 應 = trivy 報告的 finding 數（本次 21）
SELECT * FROM sarif_findings LIMIT 5;
```

### Phase 8：寫 monthly summary query

`audit/sql/queries/monthly_sarif_summary.sql`：

```sql
.mode markdown

SELECT
  '## SARIF Summary — ' || month AS section
FROM sarif_findings
GROUP BY month
ORDER BY month DESC
LIMIT 1;

-- by severity
SELECT
  level AS Severity,
  count(*) AS Count
FROM sarif_findings
WHERE month = (SELECT max(month) FROM sarif_findings)
GROUP BY level
ORDER BY count(*) DESC;

-- by rule_id (top 10)
SELECT
  rule_id AS Rule,
  count(*) AS Count,
  list_distinct(list(file))[1:3] AS "Sample Files"
FROM sarif_findings
WHERE month = (SELECT max(month) FROM sarif_findings)
GROUP BY rule_id
ORDER BY count(*) DESC
LIMIT 10;
```

執行：

```bash
audit/sql/duckdb-wrap.sh \
  -c ".read audit/sql/views/sarif_findings.sql" \
  < audit/sql/queries/monthly_sarif_summary.sql \
  > audit/artifacts/2026-06/sarif_summary.md
```

（實際命令在 lab 內依 DuckDB CLI 行為調整；目標是 markdown table 輸出進 artifacts。）

### Phase 9：驗收 + 收尾

- [x] `audit/artifacts/2026-06/sarif_summary.md` 內容看起來合理（21 findings；MEDIUM 14 / LOW 7，數字自洽）
- [x] `audit/docs/duckdb-toolchain.md` 完成（DuckDB v1.5.3 / Trivy v0.71.0、SHA、安裝/升版）
- [x] `audit/docs/sarif-schema-notes.md` 記錄踩坑（HTTP glob 限制、level vs severity、UNNEST）
- [x] 三個 SQL 檔加 file header 註解（用途、輸入、輸出）
- [x] 當日 log 補 `logs/2026-06-03.md`
- [ ] ADR-004（view schema）— 暫不需；getvariable/列舉解法已記在 sarif-schema-notes，未達 ADR 門檻
- [x] VM stop（2026-06-03 收尾後）；foundation 系列完成後再 destroy `evidence-runner`

## 不在本 lab 範圍

- 把 security-scan workflow 改成自動 `gsutil cp` SARIF（先手動）
- CI 自動跑 SQL 產 artifact（本 lab 只在 `evidence-runner` 手動跑）
- DuckDB-Wasm in HTML 站
- Asset Inventory / Audit Logs（evidence-pack-b/c）
- 月報整合（evidence-pack-d）

## 風險與回退

| 風險 | 預警 | 緩解 / 回退 |
|------|------|-------------|
| DuckDB version `TYPE HTTP` 不支援 `EXTRA_HTTP_HEADERS` | `CREATE SECRET` 報錯 | 升 DuckDB 到 1.0+ stable；無法升則退回 HMAC key（記在 ADR-002 觀察指標） |
| Token 1 小時過期、session 中斷 | 第二次 query 突然 401 | 重跑 wrapper；長 session 時 wrapper 加 token refresh loop |
| SARIF schema 變動（trivy 升版改欄位）| view query 報缺欄位 | sarif-schema-notes.md 記錄當前 schema fingerprint；trivy 升版前先驗 |
| `read_json_auto` 推測 schema 失敗（深層 nullable）| 欄位變 NULL | 手動指定 `columns = {...}` schema |
| VM SA 權限不足 | 403 即使 token 對 | 確認 bucket IAM 有 `serviceAccount:evidence-runner@...` 的 reader/writer binding |
| 一個 month 內混入測試與正式 SARIF | summary 數字虛胖 | 測試 SARIF 用 `_test/` prefix 隔離；view query 加 `WHERE NOT starts_with(filename, '..._test/')` |
| 忘記 stop VM | GCE 持續計費 | 每次 lab 結束執行 `gcloud compute instances stop evidence-runner --zone asia-east1-b` |

## 後續 lab 銜接

| 後續 lab | 從 foundation 繼承 |
|---|---|
| evidence-pack-b（Asset Inventory）| bootstrap.sql、Bearer token pattern、view 結構慣例 |
| evidence-pack-c（Audit Logs）| 同上 |
| evidence-pack-d（月報）| 三邊 view JOIN，產出單一 markdown |
| 自動化（CI 跑 SQL）| 把 wrapper 改成 WIF token，SQL 不變 |
| HTML 站（DuckDB-Wasm）| view SQL 直接複用，token 改 browser-side 取 |

## 相關

- [ADR-002 DuckDB + Bearer token](../decisions/ADR-002-duckdb-query-engine.md)
- [ADR-003 Evidence bucket](../decisions/ADR-003-evidence-bucket-separation.md)
- [evidence-bucket-bootstrap](evidence-bucket-bootstrap.md)（前置）
- [iac/labs/lab-04e-security-scan.md](../../iac/labs/lab-04e-security-scan.md)（SARIF 訊號源）
- [iac/labs/evidence-pack-overview.md](../../iac/labs/evidence-pack-overview.md)（系列總覽）
