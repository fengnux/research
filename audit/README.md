# audit/ — Evidence Pack 研究主軸

本資料夾收斂 **evidence-pack 系列**：把 [iac/](../iac/) 與 GCP 環境產出的訊號（plan/apply/drift/Trivy/Dependabot/asset/audit log）整合成可拿出去交給真實稽核員的製品。

## 跟 iac/ 的關係

`iac/` 跟 `audit/` 是**生產/消費**關係，並列而非從屬：

```
iac/        ← 蓋 GCP infra + CI pipeline，產出原始訊號
  ↓ 訊號（SARIF / state / audit log / asset inventory ...）
audit/      ← 消費訊號，產出 evidence artifact
```

工具鏈也不同：iac/ 用 OpenTofu + Terramate，audit/ 用 DuckDB + SQL + markdown。

兩邊以 cross-link 互引：audit 文件指回 iac runbook 用相對路徑（如 `../iac/labs/lab-04e-security-scan.md`）。

## 目錄結構

| 路徑 | 用途 |
|------|------|
| `docs/` | 工具鏈、SARIF schema、SQL view 設計等技術參考 |
| `labs/` | 實驗 runbook（`evidence-pack-*.md`）|
| `decisions/` | ADR — 編號獨立於 `iac/decisions/`，從 ADR-001 重起 |
| `sql/` | 可重用的 SQL view / 查詢模板 |
| `artifacts/` | 自動產出的 evidence 製品（`YYYY-MM/...`）|

## ADR 軸

`audit/decisions/` 跟 `iac/decisions/` **編號各自獨立**。`audit/decisions/ADR-001` 不是 `iac/decisions/ADR-005` 的延續，因為決策上下文不同（一個是 IaC infra，一個是 evidence pipeline）。

## 入口文件

- [evidence-pack-overview](../iac/labs/evidence-pack-overview.md) — 系列總覽（暫留 iac/labs/，待 foundation lab 完成後搬入 audit/labs/）
- [ADR-001 目錄分離決策](decisions/ADR-001-audit-directory-separation.md)
- [ADR-002 DuckDB + Bearer token 認證選型](decisions/ADR-002-duckdb-query-engine.md)
- [ADR-003 Evidence bucket 分離](decisions/ADR-003-evidence-bucket-separation.md)

## 進度

- [ ] evidence-pack-foundation — DuckDB + GCS pipeline 建置 + 第一份 SARIF artifact
- [ ] evidence-pack-b — Asset Inventory + ownership label
- [ ] evidence-pack-c — Cloud Audit Logs + IAM access audit
- [ ] evidence-pack-d — 月度稽核報告 capstone
- [ ] HTML 站（DuckDB-Wasm 互動）— 由 Claude chat 另行產出

## 已 scope out

- **evidence-pack-a Terramate Cloud**：free tier 只支援 OAuth 登入，與身份/隱私偏好不合
- **GKE pod / 即時告警 / VPC Flow Logs 視覺化**：詳見 evidence-pack-overview「不在範圍」section
