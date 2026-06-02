# evidence-bucket-bootstrap — 建立 evidence GCS bucket

## 目標

在 `tofu-terramate-lab` repo 新增 stack `stacks/evidence/storage/`，建立 evidence pack 系列共用的 GCS bucket `research-lab-495809-evidence`。

驗收條件：
- `gsutil ls -L gs://research-lab-495809-evidence` 顯示 versioning enabled、UBLA enabled、PAP enforced
- 個人 ADC 帳號能 `gsutil cp` 寫測試檔案、能 `gsutil cat` 讀
- bucket lifecycle 顯示三條規則（sarif / asset-inventory / audit-logs）

## 設計依據

- [audit ADR-003 — Evidence bucket 分離](../decisions/ADR-003-evidence-bucket-separation.md)（bucket 設計、IAM、lifecycle）
- [iac ADR-005 — CI tofu SA IAM 演進](../../iac/decisions/ADR-005-ci-tofu-sa-iam-evolution.md)（prereq matrix 規範）

## 變更檔案總覽

```
tofu-terramate-lab/
├── stacks/evidence/
│   ├── globals.tm.hcl          # 新增：evidence 群組 globals（如有）
│   └── storage/
│       ├── stack.tm.hcl        # 新增：stack 宣告
│       ├── main.tf             # 新增：google_storage_bucket
│       ├── outputs.tf          # 新增：bucket name / url
│       └── locals.tm.hcl       # 新增：globals 橋接
└── config.tm.hcl                # 不動（沿用 globals）
```

generated 檔（`_terramate_*.tf` / `backend.tf` / `providers.tf`）由 `terramate generate` 自動產出，不手寫。

## CI apply 權限 prereq matrix

依 [iac ADR-005](../../iac/decisions/ADR-005-ci-tofu-sa-iam-evolution.md) 規範，逐 resource 對照：

| 新資源 / 動作 | 必要 IAM role（`github-actions-tofu`）| 必啟 GCP API | 現狀 |
|---|---|---|---|
| `google_storage_bucket`（建 bucket）| `roles/storage.admin` 或 `roles/storage.objectAdmin` + `storage.buckets.create` | `storage.googleapis.com`（已啟）| ⚠️ 現有 `storage.objectAdmin` **不含** `storage.buckets.create`，需新加 |
| `google_storage_bucket_iam_member`（給個人讀權限）| `roles/storage.admin`（含 setIamPolicy on bucket）| 同上 | 待補 |
| `google_storage_bucket` versioning / lifecycle 設定 | 同上 `storage.admin` | 同上 | 同上 |

**結論**：CI tofu SA 需新增 `roles/storage.admin`（或更窄的 custom role；lab 規模先用 predefined）。

按 [iac ADR-005](../../iac/decisions/ADR-005-ci-tofu-sa-iam-evolution.md) 規定：**先開 WIF stack PR 加 role、本地 manual apply、merge → 才能進到本 lab application stack PR**。

## Phases

### Phase 0：WIF stack 加 `roles/storage.admin`（前置）

1. feature branch（如 `evidence-bucket-bootstrap`）改 `stacks/ci/github-actions-wif/main.tf`
2. 在 `ci_project_roles` 加 `roles/storage.admin`，註解寫 `# evidence-pack: bucket create + lifecycle + IAM`
3. 本機 `terramate run --tags ci -- tofu plan` → 確認只動 IAM binding
4. 本機 `tofu apply`（foundational stack，per [iac ADR-003](../../iac/decisions/ADR-003-foundational-stacks-excluded-from-ci.md) 不走 CI）
5. 開 PR 留稽核軌跡 + merge（CI 自動跳過 foundational）

驗收：
- [ ] `gcloud projects get-iam-policy research-lab-495809 --flatten='bindings[].members' --filter='bindings.members:github-actions-tofu@*'` 列出 `roles/storage.admin`

### Phase 1：建 `stacks/evidence/` 群組 globals

決定 `stacks/evidence/globals.tm.hcl` 是否需要（與 dev/ ci/ 同層次的群組 globals）：

- 若 evidence 系列未來會多 stack（log sink / CAI feed），加 `globals "evidence" { bucket_name = "..." }`
- v1 只有一個 stack，可以省略，bucket name 直接寫 stack 內 locals

**決策**：先省略，需要時再加。

### Phase 2：寫 stack

`stacks/evidence/storage/stack.tm.hcl`：

```hcl
stack {
  name        = "storage"
  description = "Evidence pack shared GCS bucket"
  id          = "evidence-storage"
  tags        = ["evidence"]
}
```

注意：**不**加 `foundational` tag，evidence bucket 不在 CI 信任邊界上，per ADR-003。

`stacks/evidence/storage/main.tf`：

```hcl
resource "google_storage_bucket" "evidence" {
  name     = local.bucket_name
  location = local.region
  project  = local.project_id

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { age = 395; matches_prefix = ["sarif/"] }
    action    { type = "Delete" }
  }
  lifecycle_rule {
    condition { age = 1095; matches_prefix = ["asset-inventory/"] }
    action    { type = "Delete" }
  }
  lifecycle_rule {
    condition { age = 400; matches_prefix = ["audit-logs/"] }
    action    { type = "Delete" }
  }

  labels = {
    managed_by = "terramate"
    purpose    = "evidence-pack"
  }
}

resource "google_storage_bucket_iam_member" "personal_reader" {
  bucket = google_storage_bucket.evidence.name
  role   = "roles/storage.objectViewer"
  member = "user:${local.personal_email}"
}
```

`stacks/evidence/storage/locals.tm.hcl`：generate_hcl 從 globals 橋接 `project_id` / `region` / `bucket_name` / `personal_email`。

`bucket_name` 慣例：`${project_id}-evidence`，跟 state bucket `${project_id}-tofu-state` 同模式。

`personal_email`：需在 root globals 加，或直接寫死在 locals.tm.hcl（lab 環境可接受）。

### Phase 3：generate + plan

```bash
terramate generate
git status   # 確認只新增 stacks/evidence/storage/ 下檔案
git add -A && git commit -m "feat(evidence): bootstrap evidence GCS bucket"

terramate run --tags evidence -- tofu init
terramate run --tags evidence -- tofu plan
```

預期 plan 輸出：`1 to add (google_storage_bucket) + 1 to add (google_storage_bucket_iam_member)`。

### Phase 4：開 PR + CI plan

依 [PR-first 慣例](../../iac/decisions/) push branch 開 PR，等 CI plan workflow 完成、scan 過、人工 review 後 merge。

CI apply workflow 觸發後：
- approval gate（per Lab 04a）需要手動 approve
- apply 後輸出 `bucket_name` / `bucket_url`

### Phase 5：驗收

```bash
gsutil ls -L gs://research-lab-495809-evidence  # 確認 versioning / UBLA / PAP / labels
gsutil lifecycle get gs://research-lab-495809-evidence  # 三條 rule

# smoke test 寫入
# 注意：寫入靠 project Owner 隱含權限；stack 明寫的 binding 只有 read
# （objectViewer）。若未來收掉 Owner，此步驟需先補 objectCreator binding
# 或改用 CI SA 做寫測。詳見 audit ADR-003 §3.1。
echo "hello" | gsutil cp - gs://research-lab-495809-evidence/_test/hello.txt
gsutil cat gs://research-lab-495809-evidence/_test/hello.txt
gsutil rm gs://research-lab-495809-evidence/_test/hello.txt
```

驗收清單：
- [ ] bucket 存在、versioning on、UBLA on、PAP enforced
- [ ] 三條 lifecycle rule 顯示正確（395 / 1095 / 400 天 + prefix match）
- [ ] 個人 ADC 帳號 read/write 通過
- [ ] CI tofu SA 在 bucket-level 有 `objectViewer` 以上權限（隱含 from `storage.admin`）
- [ ] 當日 log 補 `logs/YYYY-MM-DD.md` 記錄

## 不在本 lab 範圍

- 把 security-scan workflow 改成自動 `gsutil cp` SARIF 上 bucket — 留給 evidence-pack-foundation 後續 / 獨立子 lab
- CAI feed / Audit log sink 設定 — evidence-pack-b/c
- 多 env bucket 拆分

## 風險與回退

| 風險 | 預警 | 緩解 / 回退 |
|------|------|-------------|
| Phase 0 漏掉、Phase 3 plan 撞 403 | plan 時 `Error 403: storage.buckets.create` | 回 Phase 0 補 role 再重 plan |
| bucket name 撞名（GCS 全球唯一） | apply 時 `name not available` | 改用 `${project_id}-evidence-v2` 或 hash suffix |
| lifecycle prefix match 寫錯（如 `sarif/*` 而非 `sarif/`）| 試刪時保留錯誤 | google provider 接 prefix string，`sarif/` 即可；若不確定，apply 後手動 `gsutil ls` 驗證 |
| 誤把 `foundational` tag 標進去 | CI 跳過該 stack | 拿掉 tag，重 generate + commit |

## 相關

- [audit ADR-003](../decisions/ADR-003-evidence-bucket-separation.md)
- [iac ADR-005 prereq matrix](../../iac/decisions/ADR-005-ci-tofu-sa-iam-evolution.md)
- [iac/docs/state-backend.md](../../iac/docs/state-backend.md) — bucket 安全基線同源
- 後續 lab：[evidence-pack-foundation](evidence-pack-foundation.md)
