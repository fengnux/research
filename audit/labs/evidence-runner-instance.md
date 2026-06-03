# evidence-runner-instance — 專用 Evidence Pack 執行 VM

`evidence-runner` 是 evidence-pack **系列共用**的 Compute VM，用來執行 DuckDB / Trivy / GCS evidence pipeline。本文是這台 VM 的**生命週期維運 runbook**（建立 / 連線 / stop-start / destroy / troubleshooting），foundation 與後續 b/c/d 各 lab 都重啟同一台、回頭參照本文。

> 工具鏈（DuckDB / Trivy 版本、SHA、安裝/升版）見 [duckdb-toolchain](../docs/duckdb-toolchain.md)。
> 第一個消費者：[evidence-pack-foundation](evidence-pack-foundation.md)。

## 設計原則

- 不沿用 `dev-vm`，避免 K8s bastion / demo 工具與 evidence pipeline 權限混在一起
- 不使用個人 ADC、不建立 service account key
- VM 綁定 `evidence-runner` service account，透過 metadata server 取得短期 token（per [ADR-002](../decisions/ADR-002-duckdb-query-engine.md)）
- lab/demo 期間 stop/start；系列完成後 destroy（per 專案「運算資源實驗完即拆」慣例）

## IaC 資源

位置：`tofu-terramate-lab/stacks/evidence/runner/`（tag `evidence-runner`，非 foundational → CI 自動 apply）。

| 項目 | 值 |
|------|----|
| name | `evidence-runner` |
| machine type | `e2-micro` |
| zone | `asia-east1-b` |
| image | `debian-cloud/debian-12` |
| boot disk | 10GB `pd-standard` |
| network | `dev-subnet-asia-east1`，無 public IP，SSH 走 IAP（tag `iap-ssh`）|
| service account | `evidence-runner@research-lab-495809.iam.gserviceaccount.com`（bucket objectViewer + objectCreator）|

資源：`google_service_account.evidence_runner`、`google_storage_bucket_iam_member.evidence_runner_{reader,writer}`、`google_compute_instance.evidence_runner`。

## 建立（PR-first）

stack 變更走 PR → CI plan/scan → merge 後 CI 自動 apply（首次建立見 [tofu-terramate-lab#31](https://github.com/fengnux/tofu-terramate-lab/pull/31)）。本機僅在需要時 `terramate run --tags evidence-runner -- tofu plan` 預覽。

## 連線

```bash
gcloud compute ssh evidence-runner \
  --project research-lab-495809 --zone asia-east1-b --tunnel-through-iap
```

進 VM 後確認身份（應為 attached SA，**不要**在 VM 內做個人登入）：

```bash
gcloud auth list                      # active 應為 evidence-runner@…
gcloud auth print-access-token        # metadata server 取得短期 token
```

## Stop / Start

lab 間隔期間 stop（不計 CPU/RAM，boot disk 仍計費）：

```bash
gcloud compute instances stop  evidence-runner --project research-lab-495809 --zone asia-east1-b
gcloud compute instances start evidence-runner --project research-lab-495809 --zone asia-east1-b
```

> start 後 internal IP 保留；工具鏈仍在 disk 上，無需重裝。

## Destroy（系列完成後）

```bash
cd ~/GitHub/tofu-terramate-lab
terramate run --tags evidence-runner -- tofu destroy
gcloud compute instances list --project research-lab-495809   # 確認無 evidence-runner
```

destroy 後 disk 一併刪除，下次重建（CI apply）需依 [duckdb-toolchain](../docs/duckdb-toolchain.md) 重裝工具鏈。並在 `logs/YYYY-MM-DD.md` 記錄。

## Troubleshooting

| 問題 | 檢查 |
|------|------|
| IAP SSH 失敗 | 使用者是否有 `roles/iap.tunnelResourceAccessor` 與 `roles/compute.osLogin` |
| VM 無法出網下載工具 | `dev-vpc` Cloud NAT 是否仍存在 |
| `gsutil cp` 403 | bucket IAM 是否有 `evidence-runner` 的 `roles/storage.objectCreator` |
| DuckDB 讀 GCS 403 | bucket IAM 是否有 `evidence-runner` 的 `roles/storage.objectViewer` |
| DuckDB 讀 GCS 401 | token 過期，重跑 `duckdb-wrap.sh`（每次重取 token）|
| `gcloud auth list` 不是 VM SA | 不要在 VM 內個人登入；清掉 user auth 改用 attached SA |
| `Globs (*) ... not supported` | bearer token 走 HTTPS 不支援 glob；先 gsutil 列舉再注入 `sarif_urls`（見 [sarif-schema-notes](../docs/sarif-schema-notes.md)）|
