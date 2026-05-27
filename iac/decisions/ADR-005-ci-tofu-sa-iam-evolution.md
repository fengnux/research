---
status: 已採用
date: 2026-05-20
---

# ADR-005 — CI tofu (apply) SA IAM 權限演進策略

## 背景

`github-actions-tofu`（apply SA，per [ADR-002](ADR-002-wif-sa-split.md)）跑所有 application stack 的 CI apply。
每加一類新 GCP resource 就可能需要新 IAM role。Lab 05a/05b 兩次連續踩到同模式：

| Lab | 新增 resource | 缺的 role | 後果 |
|---|---|---|---|
| 05a | `google_compute_network` / `subnetwork` | `roles/compute.networkAdmin`、`compute.securityAdmin` | CI apply 卡 403，回頭補 WIF stack 再 apply |
| 05b | `google_service_account`、`google_project_iam_member` | `roles/iam.serviceAccountAdmin`、`resourcemanager.projectIamAdmin`、`iam.serviceAccountUser` | 同上 |

兩次 lab runbook 設計階段都沒 cover IAM prereq → 「跑下去撞 403 → 補 WIF → 重 apply」反覆。風險表也漏列。

每次踩坑後的修補都是反應式，但兩次後已足夠形成 pattern。需要把「下次怎麼避免」沉澱成決策，否則 lab 06、07 還會撞同樣的事。

## 決策

採「**事前 prereq matrix + 反應式擴張**」混合策略。

### 1. Runbook 設計階段必須產出 prereq matrix

每份 lab runbook 在「變更檔案總覽」之後新增 section：

```
## CI apply 權限 prereq matrix

| 新資源 / 動作 | 必要 IAM role（ci SA） | 必啟 GCP API |
|---|---|---|
| google_container_cluster | roles/container.admin | container.googleapis.com |
| google_service_account | roles/iam.serviceAccountAdmin | iam.googleapis.com（預啟） |
| google_project_iam_member | roles/resourcemanager.projectIamAdmin | （無） |
```

寫 runbook 時逐 resource 對照 GCP doc 的「Required permissions」section，先列再進入後續設計。

### 2. 加 role 只能透過修 WIF stack PR

WIF stack 是 foundational（per [ADR-003](ADR-003-foundational-stacks-excluded-from-ci.md)），新增 role 流程：

1. 在當前 lab feature branch 修 `stacks/ci/github-actions-wif/main.tf` 的 `ci_project_roles`
2. 本地 manual apply（foundational）
3. 開 PR 留稽核軌跡 + merge（PR 本身 CI 跳過 foundational stack）
4. 才能進到後續使用該 role 的 application stack PR

⚠️ 順序倒過來（先 application PR、apply 撞 403 才補 WIF）即為「踩坑模式」。

### 3. 拒絕為了 future-proof 先給大權

明確禁用：

- `roles/editor` / `roles/owner`
- `roles/iam.securityAdmin`（含 setIamPolicy 在 org-level）
- 任何「以後可能會用到」的 role

每個被加進 `ci_project_roles` 的 role 都必須在 ADR 或對應 lab log 留動機 + 第一個觸發它的 resource。

### 4. 偏好「更窄的 role」優於「更寬的 role」

加 role 前必須評估：

- **能否用 SA-level binding 取代 project-level？**（如 `google_service_account_iam_member` vs `google_project_iam_member`）
- **能否用 predefined custom role 切更窄？**（GCP 一些 admin role 含 100+ permissions，custom role 可只給用到的）

lab 規模傾向用 predefined role 不開 custom role，但要在 ADR 留紀錄「考慮過 X、選 Y 因為 Z」。

## 當前 ci_project_roles snapshot（2026-05-20）

| Role | 第一個觸發 lab / 動機 |
|---|---|
| `roles/storage.objectAdmin` | bootstrap：寫 tofu state 到 GCS bucket |
| `roles/serviceusage.serviceUsageAdmin` | dev/apis：啟用 google_project_service |
| `roles/compute.networkAdmin` | Lab 05a：建 VPC / subnet / route / firewall |
| `roles/compute.securityAdmin` | Lab 05a：建 firewall rules |
| `roles/compute.instanceAdmin.v1` | dev/vm：建 google_compute_instance |
| `roles/iap.tunnelResourceAccessor` | dev/vm + dev/gke：IAP tunnel binding（讓 SA 能管 IAP firewall） |
| `roles/iam.serviceAccountTokenCreator` | WIF impersonation 預設需要 |
| `roles/container.admin` | Lab 05b：建 GKE cluster |
| `roles/iam.serviceAccountAdmin` | Lab 05b：建 dev-vm SA |
| `roles/resourcemanager.projectIamAdmin` | Lab 05b：對 SA 加 project-level IAM binding |
| `roles/iam.serviceAccountUser` | Lab 05b：掛 SA 到 VM `service_account` block 需要 `actAs` |

## 考慮過的替代方案

### A. 一次給 `roles/editor`

- **優點**：設定簡單，未來 lab 不用再動 WIF stack
- **拒絕原因**：違反最小權限；ci SA 是高價值攻擊目標（compromise → 整個 project 失守）；無稽核軌跡（看不出某 role 是給誰用的）

### B. 完全 project owner

- 同 A 但更嚴重，連 IAM policy 都能改 → CI SA 能自己給自己加權 → 整個 ADR-002 plan/apply 分離破功

### C. 純反應式（不做 prereq matrix，撞了才補）

- Lab 05a/05b 兩次驗證痛點：lab 設計被 IAM 中斷打斷、需臨時開 WIF PR、重 trigger 才能繼續
- 兩次後已足夠形成 pattern，繼續純反應式是浪費已學到的教訓

### D. 純預測式（一次列齊全所有未來 lab 的 role）

- 過度設計；GCP role 邊界會變（new role / deprecation）；預測失準成本高
- lab 範圍未定的部分硬猜，違反「v1 跟現狀 1:1」哲學（參 lab 05a 設計討論）

## 後果

- Lab runbook 設計時多花 15-30 分鐘做 prereq matrix（值得，比撞坑省 1-2 小時）
- 每個新 role 都帶動機留在 ADR / log，半年後 review 時看得出來
- 後續 lab 寫 runbook 時，[ci-apply-recovery runbook](../docs/runbooks/ci-apply-recovery.md) 的「Code 沒問題、外部條件不足」路徑（B）會更少觸發

## 觀察指標（觸發本 ADR 重審或新 ADR）

開新 ADR 或補充本 ADR 的訊號：

- `ci_project_roles` 超過 20 個
- 某個 admin role 半年內未被任何 stack 實際用到 → 該移除
- 出現新一類資源時 prereq matrix **仍頻繁失準**（如三次 lab 中兩次撞 403）→ 表示流程沒落地
- ci SA 在 GCP Recommender 出現「over-granted permission」警示

## 相關

- [ADR-002 WIF SA 拆分](ADR-002-wif-sa-split.md)
- [ADR-003 Foundational stacks 排除 CI](ADR-003-foundational-stacks-excluded-from-ci.md)
- [CI apply recovery runbook](../docs/runbooks/ci-apply-recovery.md)
- 案例：[2026-05-19 log 踩坑二](../../logs/2026-05-19.md)、[2026-05-20 log 踩坑二](../../logs/2026-05-20.md)
