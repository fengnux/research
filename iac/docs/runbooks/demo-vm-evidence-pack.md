# Runbook：evidence-pack 演示機（沿用 dev-vm）

## 目的與時機

近期要向同事演示 evidence-pack 系列實驗，需要一台與本機環境一致的 GCP 主機。

- **不另開 stack**：沿用 `tofu-terramate-lab` 的 `stacks/dev/vm`（規格見 [lab-03c](../../labs/lab-03c-dev-vm.md)）
- **生命週期例外**：近期會反覆使用，因此 demo 之間以 `gcloud compute instances stop / start` 切換，而非每次 `tofu destroy`
  - 這是 demo window 的暫時做法，與 [專案慣例「lab 結束即 destroy」](../../../logs/2026-05-20.md) 並行而非取代
  - demo 系列結束後仍要 destroy，回歸常態
- **計費**：stopped VM 不計 CPU/RAM，但 boot disk（10GB pd-standard）仍計費（~$0.40/月），可接受

## 前置確認

執行 apply 之前確認：

- [ ] ADC 帳號在 `research-lab-495809` 有 `roles/compute.instanceAdmin.v1` + `roles/iap.tunnelResourceAccessor` + `roles/compute.osLogin`
- [ ] `~/GitHub/tofu-terramate-lab` 在 `main` 且 working tree 乾淨（避免 Terramate git-untracked / git-uncommitted 卡住，見 [feedback_no_disable_safeguards](../../../../.claude/projects/-Users-fengnux-GitHub-research/memory/feedback_no_disable_safeguards.md)）
- [ ] `gcloud auth list` 顯示預期帳號、`gcloud config get-value project` = `research-lab-495809`

## 步驟

### 1. 首次拉回 VM（state 已存在，re-apply）

詳細指令引用 [lab-03c 第 6 步](../../labs/lab-03c-dev-vm.md#6-apply-vm-stack)：

```bash
cd ~/GitHub/tofu-terramate-lab
terramate run --tags vm -- tofu init
terramate run --tags vm -- tofu plan    # 預期：+1 google_compute_instance.dev_vm
terramate run --tags vm -- tofu apply
```

### 2. VM 工具對齊（與本機 evidence-pack 環境一致）

> TODO：等本機 evidence-pack 工具鏈（DuckDB / gcloud / 其他）穩定後，回來補一份 `apt install` / 安裝 one-liner。
>
> 目前做法：`gcloud compute ssh dev-vm --zone asia-east1-b` 進去後比對本機，逐項手動安裝。

### 3. 演示前 checklist

每次演示前在 VM 內乾跑一次：

- [ ] `gcloud auth list` 帳號正確（OS Login 帶入的身份）
- [ ] 預計 demo 的指令全部能跑（不卡 auth、不缺套件）
- [ ] 演示用檔案 / repo 已 clone

### 4. 兩次 demo 之間：stop（不 destroy）

```bash
gcloud compute instances stop dev-vm \
  --project research-lab-495809 \
  --zone asia-east1-b
```

下次要用：

```bash
gcloud compute instances start dev-vm \
  --project research-lab-495809 \
  --zone asia-east1-b
```

> start 後 external IP 不變（本來就沒有對外 IP，走 IAP）；internal IP 也保留。

### 5. Demo 系列全部結束：destroy

```bash
cd ~/GitHub/tofu-terramate-lab
terramate run --tags vm -- tofu destroy
gcloud compute instances list --project research-lab-495809   # 確認無 dev-vm
```

並在 `logs/YYYY-MM-DD.md` 補一行 destroy 紀錄。

## 風險與回退

沿用 [lab-03c 風險章節](../../labs/lab-03c-dev-vm.md#風險與回退)（IAP 權限、OS Login、忘記清理）。本 runbook 額外風險：

- **忘記 stop**：running VM 約 $0.007/hr（e2-micro）；若不確定狀態，`gcloud compute instances describe dev-vm --zone asia-east1-b --format='value(status)'` 查 `RUNNING` / `TERMINATED`
- **boot disk 持續計費**：long-stopped 期間 disk 仍會扣費；若 demo window 超出預期（>2 週未用），考慮直接 destroy，下次再 re-apply
