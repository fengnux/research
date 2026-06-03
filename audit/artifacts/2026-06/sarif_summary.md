# SARIF Summary — 2026-06

> Evidence artifact，由 `evidence-runner` VM 上的 DuckDB pipeline 產出。
> 資料源 SARIF 由 Trivy 掃 `tofu-terramate-lab` 產生並上傳 evidence bucket。

| 項目 | 值 |
|------|----|
| 產出時間 (UTC) | 2026-06-03T15:31:02Z |
| 執行身份 | `evidence-runner@research-lab-495809.iam.gserviceaccount.com`（VM attached SA via metadata server，per ADR-002）|
| Query engine | DuckDB v1.5.3 (Variegata) 14eca11bd9 |
| Scanner | Trivy v0.71.0 |
| 來源 bucket prefix | `gs://research-lab-495809-evidence/sarif/2026-06/` |
| 來源物件數 | 1 |

來源 SARIF 物件：

  - gs://research-lab-495809-evidence/sarif/2026-06/test-20260603-152124.sarif.json

## 當月 finding 總數

|  Month  | Findings |
|---------|---------:|
| 2026-06 | 21       |

## By severity

| Severity | Count |
|----------|------:|
| MEDIUM   | 14    |
| LOW      | 7     |

## By SARIF level

|  Level  | Count |
|---------|------:|
| warning | 14    |
| note    | 7     |

## Top rules（前 10）

|   Rule   | Severity | Count |                        Sample Files                         |
|----------|----------|------:|-------------------------------------------------------------|
| GCP-0033 | LOW      | 2     | [stacks/dev/vm/main.tf, stacks/evidence/runner/main.tf]     |
| GCP-0030 | MEDIUM   | 2     | [stacks/dev/vm/main.tf, stacks/evidence/runner/main.tf]     |
| GCP-0067 | MEDIUM   | 2     | [stacks/dev/vm/main.tf, stacks/evidence/runner/main.tf]     |
| GCP-0045 | MEDIUM   | 2     | [stacks/dev/vm/main.tf, stacks/evidence/runner/main.tf]     |
| GCP-0066 | LOW      | 2     | [stacks/bootstrap/main.tf, stacks/evidence/storage/main.tf] |
| GCP-0011 | MEDIUM   | 2     | [stacks/ci/github-actions-wif/main.tf]                      |
| GCP-0041 | MEDIUM   | 2     | [stacks/dev/vm/main.tf, stacks/evidence/runner/main.tf]     |
| GCP-0003 | MEDIUM   | 1     | [stacks/evidence/storage/main.tf]                           |
| GCP-0029 | LOW      | 1     | [_modules/network/main.tf]                                  |
| GCP-0076 | MEDIUM   | 1     | [_modules/network/main.tf]                                  |

---
*產生方式：`audit/sql/bootstrap.sql` + `views/sarif_findings.sql` + `queries/monthly_sarif_summary.sql`，透過 `duckdb-wrap.sh`（token 來自 metadata server）。重現步驟見 [evidence-pack-foundation](../../labs/evidence-pack-foundation.md)。*
