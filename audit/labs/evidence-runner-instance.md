# evidence-runner-instance — 專用 Evidence Pack 執行 VM

## 目的

`evidence-runner` 是 evidence-pack foundation 的專用 Compute VM，用來執行 DuckDB / Trivy / GCS evidence pipeline。它取代原本「在本機裝 DuckDB、用個人 ADC 讀 bucket」的做法。

原則：

- 不沿用 `dev-vm`，避免 K8s bastion / demo 工具與 evidence pipeline 權限混在一起
- 不使用個人 ADC，不建立 service account key
- VM 綁定 `evidence-runner` service account，透過 metadata server 取得短期 token
- lab/demo 期間 stop/start；系列完成後 destroy

## IaC 資源

位置：`tofu-terramate-lab/stacks/evidence/runner/`

資源：

- `google_service_account.evidence_runner`
- `google_storage_bucket_iam_member.evidence_runner_reader`
- `google_storage_bucket_iam_member.evidence_runner_writer`
- `google_compute_instance.evidence_runner`

VM 規格：

| 項目 | 值 |
|------|----|
| name | `evidence-runner` |
| machine type | `e2-micro` |
| zone | `asia-east1-b` |
| image | `debian-cloud/debian-12` |
| boot disk | 10GB `pd-standard` |
| network | `dev-subnet-asia-east1` |
| public IP | 無 |
| SSH | IAP TCP forwarding，tag `iap-ssh` |
| service account | `evidence-runner@research-lab-495809.iam.gserviceaccount.com` |

## 建立 / 更新

```bash
cd ~/GitHub/tofu-terramate-lab
terramate run --tags evidence-runner -- tofu init
terramate run --tags evidence-runner -- tofu plan
terramate run --tags evidence-runner -- tofu apply
```

Plan 預期包含：

- 新增或維持 `evidence-runner` service account
- 新增或維持 evidence bucket `objectViewer` / `objectCreator` binding
- 新增或維持 `evidence-runner` VM

## 連線

```bash
gcloud compute ssh evidence-runner \
  --project research-lab-495809 \
  --zone asia-east1-b \
  --tunnel-through-iap
```

進 VM 後確認身份與 token：

```bash
gcloud auth list
gcloud auth print-access-token >/tmp/evidence-runner.token
```

預期 token 來自 VM attached service account；不要執行 `gcloud auth application-default login`。

## 工具鏈安裝

VM 內安裝 foundation lab 需要的工具：

```bash
sudo apt-get update
sudo apt-get install -y curl unzip git
```

DuckDB 與 Trivy 版本 pin 寫入 [duckdb-toolchain](../docs/duckdb-toolchain.md) 或 foundation lab 的工具鏈章節。DuckDB 安裝範例見 [evidence-pack-foundation](evidence-pack-foundation.md) Phase 2。

## Evidence Bucket Smoke Test

```bash
echo "hello from evidence-runner $(date -Is)" > /tmp/evidence-runner-smoke.txt
gsutil cp /tmp/evidence-runner-smoke.txt \
  gs://research-lab-495809-evidence/sarif/2026-06/_smoke/evidence-runner.txt

gsutil cat \
  gs://research-lab-495809-evidence/sarif/2026-06/_smoke/evidence-runner.txt
```

注意：`roles/storage.objectCreator` 可以建立物件，但不能覆寫或刪除既有物件。smoke test 檔名若重複，改用 timestamp。

## Stop / Start

lab 間隔期間 stop VM：

```bash
gcloud compute instances stop evidence-runner \
  --project research-lab-495809 \
  --zone asia-east1-b
```

下次繼續：

```bash
gcloud compute instances start evidence-runner \
  --project research-lab-495809 \
  --zone asia-east1-b
```

Stopped VM 不計 CPU/RAM，但 boot disk 仍計費。若超過兩週不使用，優先 destroy。

## Destroy

foundation 系列完成後：

```bash
cd ~/GitHub/tofu-terramate-lab
terramate run --tags evidence-runner -- tofu destroy
gcloud compute instances list --project research-lab-495809
```

destroy 後在 `logs/YYYY-MM-DD.md` 記錄清理完成。

## Troubleshooting

| 問題 | 檢查 |
|------|------|
| IAP SSH 失敗 | 使用者是否有 `roles/iap.tunnelResourceAccessor` 與 `roles/compute.osLogin` |
| VM 無法出網下載工具 | `dev-vpc` Cloud NAT 是否仍存在 |
| `gsutil cp` 403 | bucket IAM 是否有 `evidence-runner` 的 `roles/storage.objectCreator` |
| DuckDB 讀 GCS 403 | bucket IAM 是否有 `evidence-runner` 的 `roles/storage.objectViewer` |
| `gcloud auth list` 不是 VM SA | 不要在 VM 內做個人登入；清掉 user auth 後改用 attached SA |
