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
  - Production 啟用路徑：(1) 新 stack `stacks/evidence/kms/` 建 KeyRing + CryptoKey；(2) 給 GCS service agent (`service-${project_number}@gs-project-accounts.iam.gserviceaccount.com`) 綁 `roles/cloudkms.cryptoKeyEncrypterDecrypter`；(3) bucket spec 加 `encryption { default_kms_key_name = ... }`
  - 觸發時機：見「觀察指標」

### 3. IAM 設計

| 角色 | Role | 範圍 |
|------|------|------|
| Writer: security-scan workflow SA（暫用 `github-actions-tofu-plan`，未來考慮分割）| `roles/storage.objectCreator` on bucket | `sarif/*` prefix |
| Writer: evidence-runner VM SA | `roles/storage.objectCreator` on bucket | foundation lab 測試 SARIF |
| Writer: CAI export | `roles/storage.objectCreator` | `asset-inventory/*` |
| Writer: Audit log sink | `roles/storage.objectCreator`（sink SA 自動建）| `audit-logs/*` |
| Reader: 個人 ADC | `roles/storage.objectViewer` on bucket | 全部 |
| Reader: evidence-runner VM SA | `roles/storage.objectViewer` on bucket | DuckDB 讀 GCS evidence |
| Reader: 未來 GHA evidence-pack workflow / GKE pod | `roles/storage.objectViewer` via WIF/WI | 全部 |

注意：本表是設計目標。`evidence-bucket-bootstrap` 先開「個人 reader」最小可運作集合；`evidence-pack-foundation` 改由專用 `evidence-runner` VM 執行後，新增 VM SA reader/writer binding，writer 仍隨後續 lab 逐步拆分。

#### 3.1 為什麼明知冗餘還要寫個人 reader binding

個人 ADC 目前在 `research-lab-495809` 持有 `roles/owner`，已隱含 `storage.objects.get` / `storage.objects.list`。技術上拿掉 `personal_reader` binding 也能讀。仍然明寫的理由：

1. **顯化讀取者意圖**：bucket IAM policy 上直接列出「誰被預期讀 evidence」，不是從 project-level Owner 推導 —— 對演示與 audit trail 都更清楚
2. **對齊 production pattern**：真實環境不會給人 Owner；本 lab 給人 Owner 是便宜行事，IaC code 應該長得像「未來會把 Owner 收掉」的樣子
3. **降耦合**：若日後把個人帳號從 Owner 改為窄 role（如 custom auditor），bucket-level binding 仍生效，foundation lab 不會壞

也就是說 —— 這條 binding 在 lab 階段是「未來自我」的保險，而非「現在能不能讀」的開關。

注意：binding role 是 `objectViewer`，**只解決讀**；evidence-bucket-bootstrap Phase 5 的 `gsutil cp` 寫測試仍依賴 project Owner 隱含權限。若日後把個人帳號從 Owner 收掉，需要另加 `objectCreator` binding 給個人（或改由 CI SA 做 write 路徑驗證）。Codex review @ PR #30 提醒此點。

### 4. Bucket 由 IaC 管理、敘事在 audit/

Bucket 本身是 GCP resource → **`tofu-terramate-lab` repo 加新 stack 管理**。候選位置：

- (a) `stacks/evidence/storage/` — 新建 group，與 dev/ ci/ 同層；未來 evidence-pack 其他 GCP-side 資源（CAI feed、log sink）也歸這
- (b) 併入 `stacks/bootstrap/` — bootstrap 本就管 state bucket，性質類似
- (c) 併入 `stacks/ci/` — 算 CI infra 的延伸

我建議 **(a)**，理由：bootstrap 是 chicken-and-egg foundation（state bucket 必須先存在才能管自己），evidence bucket 並非；獨立 group 給後續 evidence-pack-b/c GCP 資源（CAI feed、log sink）留 home。

stack 是否標 `foundational` tag（per [iac ADR-003](../../iac/decisions/ADR-003-foundational-stacks-excluded-from-ci.md)）：**否**。evidence bucket 不在 CI 信任邊界上，CI 可以管它（plan/apply）。

#### 4.1 為什麼不是 `stacks/dev/evidence/`

訊號來源（VPC / VM / GKE / security-scan workflow）目前確實多在 `stacks/dev/` 與 `stacks/ci/` 底下，命名上會讓人懷疑「為什麼觀察 dev 的 bucket 不放 dev 下」。但 evidence 跟 dev workload 的**生命週期與信任邊界都不同**：

| 面向 | `stacks/dev/`（workload） | `stacks/evidence/` |
|---|---|---|
| 生命週期 | lab 結束 destroy（per [teardown-after-lab 慣例](../../logs/)）| 長期保留（SARIF 395 天、Audit Log 400 天、CAI 1095 天）|
| Destroy 連動 | dev/ 整組 destroy 是常態 | 跟 dev/ 一起 destroy = 證據資料遺失，違反 evidence-pack 存在意義 |
| 信任邊界 | CI tofu SA 完全控制 | 寫多源（scan SA / sink SA / CAI export）、讀分析者多人，per 上節 IAM matrix 刻意切分 |
| 觀察對象 | 只看自己 | dev workload **+ ci pipeline + GCP project 層**（Audit Logs、CAI feed）|

因此 `stacks/` 形成三軸並列：

```
stacks/
├── dev/        ← workload（apis, network, vm, ...）→ 跟著 lab 拆
├── ci/         ← pipeline（WIF, SAs）→ foundational、長存
└── evidence/   ← 觀察平面（bucket、後續的 log sink、CAI feed）→ 長存
```

這跟 [ADR-001 在 repo 根做的 `iac/` vs `audit/` 分離](ADR-001-audit-directory-separation.md)是同一個邏輯下放到 stack 層。

多 env 時的擴張方式：**bucket 不分裂**，用內部 prefix 區分（`sarif/dev/...` / `sarif/prod/...`），維持 evidence 平面的單一性。

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
- **CI tofu SA 持有 `roles/storage.admin`（project-wide）**：lab 階段為 evidence bucket bootstrap 接受此寬度（Codex review @ PR #29 已指出）。當其他 stack 也要建 bucket、或 evidence bucket 需要更嚴限縮時，重審：custom role 限縮到 `research-lab-495809-evidence` / `*-tofu-state` 兩個 bucket，或拆 plan/apply SA 讓 apply SA 才有 bucket-create
- **轉 production 的金鑰治理**：若 evidence bucket 內容開始包含個資、secrets 或受監管資料；或法遵框架（ISO 27001 / SOC 2 / 金融監管）要求金鑰客戶自管 → 啟 CMEK（路徑見 §3 bucket 設計）

## 相關

- [ADR-001 目錄分離](ADR-001-audit-directory-separation.md)
- [ADR-002 DuckDB + Bearer token](ADR-002-duckdb-query-engine.md)
- [iac ADR-005 ci tofu SA IAM 演進](../../iac/decisions/ADR-005-ci-tofu-sa-iam-evolution.md)
- [iac/docs/state-backend.md](../../iac/docs/state-backend.md) — state bucket 安全基線
- 預計：`audit/labs/evidence-bucket-bootstrap.md`、`audit/labs/evidence-pack-foundation.md`
