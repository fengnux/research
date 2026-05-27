---
status: 已採用
date: 2026-05-27
---

# ADR-003 — Evidence Pack 用獨立 GCS Bucket，不重用 State Bucket

## 背景

Evidence pack 各個資料源都需要 GCS 落地：

- Trivy SARIF（per [ADR-002](ADR-002-duckdb-query-engine.md)）
- GCP Asset Inventory snapshot
- Cloud Audit Logs sink export
- 未來：Billing export、GitHub API 抓取的 PR/Actions metadata

最直觀做法是重用既有 `gs://research-lab-495809-tofu-state/`，加個 `evidence-pack/` prefix。但這違反 GCS bucket 設計常識：state bucket 應該只裝 state。

## 決策

新開 GCS bucket `research-lab-495809-evidence`，跟 state bucket 同 project / 同 region，用途獨立。

### 1. 為什麼不重用 state bucket

| 比較項 | state bucket | evidence bucket |
|--------|-------------|-----------------|
| 內容性質 | 小、靜態、critical | append-only、持續成長 |
| 誤刪風險 | 環境炸掉（state lost = 整個 IaC 失憶）| 重新 export 即可 |
| 寫入者 | 1 個 SA（`github-actions-tofu`）| 多源（scan workflow / CAI export / log sink）|
| 讀取者 | tofu only | DuckDB / 人 / 各種 query workload |
| Lifecycle | 永不刪 + versioning | 分類保留（SARIF 13 月、asset 36 月、audit log per 法遵）|
| IAM | 收斂到 1 SA | 寫多源、讀分析者多人 |

混在一起 IAM 切不乾淨：給 DuckDB read 等於給看 state 權限（state 可能含敏感 IAM binding / SA email）。最佳實踐上 state bucket 應該只裝 state。

### 2. Bucket 設計

```
gs://research-lab-495809-evidence/
  sarif/<YYYY-MM>/<workflow_run_id>.sarif.json
  asset-inventory/<YYYY-MM-DD>.json
  audit-logs/<YYYY-MM-DD>/...       # Cloud Audit Logs sink export
  billing/<YYYY-MM>/...             # 預留 D 主題
  reports/<YYYY-MM>/...             # 月報 markdown / PDF 備份
```

- **Versioning**：開（誤刪保護；小檔案版本成本可忽略）
- **Uniform bucket-level access**：開（拒絕 ACL，per [state bucket 慣例](../../iac/docs/state-backend.md)）
- **Public access prevention**：enforced
- **Lifecycle**：top-level prefix 各自一條：
  - `sarif/`：395 天後刪（保留 13 個月供年度趨勢）
  - `asset-inventory/`：1095 天（3 年）
  - `audit-logs/`：400 天（對齊 GCP 預設 Admin Activity log retention）
  - `billing/`、`reports/`：暫不設 lifecycle，accumulate
- **CMEK**：暫不啟（lab 範圍；production 場景再開）

### 3. IAM 設計

| 角色 | Role | 範圍 |
|------|------|------|
| Writer: security-scan workflow SA（暫用 `github-actions-tofu-plan`，未來考慮分割）| `roles/storage.objectCreator` on bucket | `sarif/*` prefix |
| Writer: CAI export | `roles/storage.objectCreator` | `asset-inventory/*` |
| Writer: Audit log sink | `roles/storage.objectCreator`（sink SA 自動建）| `audit-logs/*` |
| Reader: 個人 ADC | `roles/storage.objectViewer` on bucket | 全部 |
| Reader: 未來 GHA evidence-pack workflow / GKE pod | `roles/storage.objectViewer` via WIF/WI | 全部 |

注意：本表是設計目標，**foundation lab 只開「個人 reader」最小可運作集合**，writer 隨後續 lab 逐步加。

### 4. Bucket 由 IaC 管理、敘事在 audit/

Bucket 本身是 GCP resource → **`tofu-terramate-lab` repo 加新 stack 管理**。候選位置：

- (a) `stacks/evidence/storage/` — 新建 group，與 dev/ ci/ 同層；未來 evidence-pack 其他 GCP-side 資源（CAI feed、log sink）也歸這
- (b) 併入 `stacks/bootstrap/` — bootstrap 本就管 state bucket，性質類似
- (c) 併入 `stacks/ci/` — 算 CI infra 的延伸

我建議 **(a)**，理由：bootstrap 是 chicken-and-egg foundation（state bucket 必須先存在才能管自己），evidence bucket 並非；獨立 group 給後續 evidence-pack-b/c GCP 資源（CAI feed、log sink）留 home。

stack 是否標 `foundational` tag（per [iac ADR-003](../../iac/decisions/ADR-003-foundational-stacks-excluded-from-ci.md)）：**否**。evidence bucket 不在 CI 信任邊界上，CI 可以管它（plan/apply）。

### 5. 敘事 vs 資源分工

| 內容 | 位置 |
|------|------|
| Bucket terraform code | `tofu-terramate-lab` `stacks/evidence/storage/` |
| Bucket 設計理由 / IAM matrix / lifecycle 政策 | 本 ADR（research repo） |
| Bucket 建置 runbook | `audit/labs/evidence-bucket-bootstrap.md`（research repo） |
| 建置完當日日誌 | `logs/YYYY-MM-DD.md` |

「資源在 iac 管理、敘事在 audit 記錄」剛好示範 ADR-001「生產/消費」目錄分離的具體運作。

## 考慮過的替代方案

### A. 重用 state bucket + `evidence-pack/` prefix

- 優點：少一個 bucket、IAM 沿用既有 `github-actions-tofu`
- 拒絕原因：IAM 邊界混淆（read evidence = read state risk）、lifecycle 不能分、不符合「state bucket 只裝 state」最佳實踐

### B. 一資料源一 bucket

- 優點：權限收斂到極致
- 拒絕原因：過度切；evidence-pack 所有資料源屬同一個信任邊界（個人 lab 環境），切 4-5 個 bucket 增加 IAM/lifecycle 維護無價值

### C. BigQuery dataset 取代 GCS bucket

- 優點：分析 native（CAI export 直接到 BQ）
- 拒絕原因：per [ADR-002](ADR-002-duckdb-query-engine.md) 不選 BQ；evidence pack DuckDB-first

### D. 跨 project / multi-env 分 bucket

- 跟 [evidence-pack-overview](../../iac/labs/evidence-pack-overview.md) 範圍一致：v1 假設仍是 dev 單環境，multi-env 上線後再分

## 後果

- `tofu-terramate-lab` 多一個 stack：`stacks/evidence/storage/`
- `ci_project_roles`（per [iac ADR-005](../../iac/decisions/ADR-005-ci-tofu-sa-iam-evolution.md)）需要新增 `roles/storage.admin` 或 `roles/storage.bucketAdmin`？— foundation runbook 用 prereq matrix 確認
- DuckDB SQL 用 `https://storage.googleapis.com/research-lab-495809-evidence/...` 而非 state bucket
- 新增的 audit log sink / CAI feed 等 GCP resource 未來都歸 `stacks/evidence/`

## 觀察指標

重審本 ADR 的訊號：

- evidence bucket 內單一 prefix 超過 10 GB（lifecycle 是否太寬？）
- 月度 GCS 費用超過 $1（先預估接近 $0，超過代表 export 量設計失誤）
- 多 env 上線後是否需要 per-env bucket（拆 vs 統一 + label）

## 相關

- [ADR-001 目錄分離](ADR-001-audit-directory-separation.md)
- [ADR-002 DuckDB + Bearer token](ADR-002-duckdb-query-engine.md)
- [iac ADR-005 ci tofu SA IAM 演進](../../iac/decisions/ADR-005-ci-tofu-sa-iam-evolution.md)
- [iac/docs/state-backend.md](../../iac/docs/state-backend.md) — state bucket 安全基線
- 預計：`audit/labs/evidence-bucket-bootstrap.md`、`audit/labs/evidence-pack-foundation.md`
