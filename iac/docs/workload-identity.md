# GKE Workload Identity

> Pod 拿 GCP API token 的金鑰外洩問題解法：用 K8s service account 自動換成 GCP service account 短期 token，pod 內無任何長期憑證。

## 為什麼需要

K8s pod 要呼叫 GCP API（讀 GCS、寫 BigQuery、發 Pub/Sub）就需要 GCP 認證。傳統做法：

```
GCP SA → 下載 JSON key → 塞進 K8s Secret → mount 進 pod → 程式讀 file
```

問題：

- **長期憑證**：key 沒過期、外洩就完蛋
- **散播風險**：image / Secret / Volume / git history / log，每一處都是攻擊面
- **輪換難**：rotate key 要同步換每個 Secret + 重啟所有 pod
- **稽核弱**：誰用了這把 key、用了什麼，從 GCP 看不出 K8s 來源

Workload Identity 把這條鏈整個拆掉：pod 內**沒有 key**，每次需要 token 時由 GKE metadata server 即時換發短期 token。

## 機制：三段鏈路

```
┌─────────────┐    ┌────────────────────────┐    ┌────────────┐
│   Pod       │    │ Workload Identity Pool │    │  GCP SA    │
│ (KSA: demo) ├───▶│  PROJECT.svc.id.goog   ├───▶│   (GSA)    │
└─────────────┘    └────────────────────────┘    └────────────┘
   pod spec.        Autopilot 預設啟用             roles/iam.
   serviceAccount   每個 cluster 一個 pool          workloadIdentityUser
                                                   binding GSA←KSA
```

1. **Pod 用 KSA 跑**：pod spec 指定 `serviceAccount: demo`，namespace 內的 ServiceAccount object
2. **KSA → Pool**：cluster 啟用 Workload Identity 後，pool ID 固定為 `PROJECT_ID.svc.id.goog`
3. **Pool[NS/KSA] → GSA**：對某個 GSA 做 IAM binding：`role=roles/iam.workloadIdentityUser`、`member=serviceAccount:POOL[NS/KSA]` → 授權該 KSA 可以扮演該 GSA
4. **KSA annotation**：對 KSA 加 annotation `iam.gke.io/gcp-service-account=GSA_EMAIL` → 告訴 GKE 該 KSA 想扮演哪個 GSA
5. **執行時**：pod 內任何 GCP SDK 自動找 metadata server（`http://metadata.google.internal`），server 回的是 GSA 的短期 token

整條鏈 pod 內無任何金鑰檔案，token 由 GKE control plane 即時換發、自動續期。

## 對比：CI 用的 Workload Identity Federation（WIF）

`research` repo 有另一份 [workload-identity-federation.md](workload-identity-federation.md)，講的是 **GitHub Actions → GCP** 的身份代換。兩者底層機制不同：

| 主題 | GKE Workload Identity | GitHub Actions WIF |
|------|----------------------|---------------------|
| **代換來源** | K8s ServiceAccount（kSA） | GitHub OIDC token（repo / branch / env） |
| **代換目標** | GCP ServiceAccount | GCP ServiceAccount |
| **Pool 形式** | cluster-bound，自動產生 `PROJECT.svc.id.goog` | 手動建 `iam.workloadIdentityPools.create` |
| **Provider** | 內建（GKE metadata server） | OIDC provider object（`iam.workloadIdentityPoolProviders.create`） |
| **binding role** | `roles/iam.workloadIdentityUser` | `roles/iam.workloadIdentityUser` |
| **適用場景** | pod 拿 GCP API 權限 | CI runner / 任何外部 OIDC 端點 |

共通點：都遵循「**外部身份 → IAM binding → GSA token**」哲學，目的都是消除 key 檔案；都用 `roles/iam.workloadIdentityUser` 作為 binding role。

## 設定步驟

### 前提

- GKE cluster 啟用 Workload Identity（Autopilot 預設啟用，Standard 需顯式設 `workload_identity_config { workload_pool = "PROJECT.svc.id.goog" }`）
- 已有 GSA（目標身份）
- 知道 namespace + KSA 命名（先決定再 binding）

### 步驟（lab-05b 實際指令）

```bash
PROJECT=research-lab-495809
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
GSA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"  # lab 簡化，用 default compute SA
POOL="${PROJECT}.svc.id.goog"
NS=wi-demo
KSA=demo

# 1. K8s 端：建 namespace + KSA
kubectl create namespace $NS
kubectl create serviceaccount $KSA -n $NS

# 2. GCP 端：GSA 加 workloadIdentityUser binding（給 POOL[NS/KSA]）
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --project="$PROJECT" \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:${POOL}[${NS}/${KSA}]"

# 3. K8s 端：KSA 加 annotation 標記目標 GSA
kubectl annotate serviceaccount $KSA -n $NS \
  iam.gke.io/gcp-service-account="$GSA"

# 4. 驗證：跑 pod 用該 KSA，看內部 gcloud auth list
kubectl run wi-test \
  --image=google/cloud-sdk:slim \
  --restart=Never \
  --overrides="{\"spec\":{\"serviceAccount\":\"$KSA\"}}" \
  -n $NS \
  --command -- gcloud auth list
```

**預期 output**（lab-05b 2026-05-20 實測）：

```
                   Credentialed Accounts
ACTIVE  ACCOUNT
*       1074394836652-compute@developer.gserviceaccount.com
```

ACTIVE 顯示 **GSA** 而非 KSA、無任何 key 檔案 → 鏈通。

### 角色與權限分工

| 步驟 | 操作端 | 所需權限 |
|------|--------|---------|
| 1 建 NS/KSA | K8s | `roles/container.developer` 或 `clusterAdmin` |
| 2 GSA binding | GCP | 對該 GSA 的 `iam.serviceAccountAdmin`（或更廣的 `resourcemanager.projectIamAdmin`） |
| 3 annotate KSA | K8s | `container.developer` 可改自家 NS 的 SA annotation |
| 4 跑 pod | K8s | `container.developer` 即可 |

⚠️ **lab-05b 踩坑**：dev-vm SA 只有 `container.developer` + `container.clusterViewer`，所以 step 2 的 `gcloud add-iam-policy-binding` 不能在 dev-vm 跑（缺 IAM admin），要回本地用 user creds 執行。production 場景應由 IaC（Terraform）管 binding，不該人工跑。

## Production 進階：每 workload 專屬 GSA

lab 用 default compute SA 是 ❌ 反例：它在 GCP 預設掛了 broad 權限，且全 project 共用 → 違反最小權限。

production 模式：

```hcl
# 每個 workload 自己的 GSA
resource "google_service_account" "app_a" {
  account_id   = "app-a-runtime"
  display_name = "App A runtime"
}

# 只給該 workload 需要的 role
resource "google_project_iam_member" "app_a_gcs" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.app_a.email}"
}

# binding workloadIdentityUser
resource "google_service_account_iam_member" "app_a_wi" {
  service_account_id = google_service_account.app_a.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[app-a/app-a]"
}
```

KSA 在 K8s YAML（或 Helm chart）內，annotation 也宣告式管理。

## 失敗排查

### 症狀 1：pod 內 `gcloud auth list` 顯示 `No credentialed accounts`

可能原因：
- KSA 沒 annotation → 補 `kubectl annotate`
- annotation key 拼錯（應該是 `iam.gke.io/gcp-service-account`）
- pod spec 沒指定 `serviceAccount` → 跑成 `default` KSA

### 症狀 2：pod 內 token 拿到了但 GCP API 回 403

可能原因：
- GSA 沒對應 API 的 IAM role（補 `roles/storage.objectViewer` 等）
- GSA 拿到 binding 對應的 namespace/KSA **拼錯**（看 `iam.serviceAccounts.getIamPolicy` 確認 member 字串）

### 症狀 3：annotation 加了、binding 也對，pod 跑出來還是 KSA 沒 GSA

可能原因：
- **cluster 沒啟用 Workload Identity**（Autopilot 預設啟用；Standard cluster 要顯式設）→ `gcloud container clusters describe X --format='value(workloadIdentityConfig)'` 確認
- node pool 沒啟用 `GKE_METADATA`（Standard 需要 per node pool 啟用；Autopilot 不用管）

### 症狀 4：pod 直接 CrashLoop 拿不到 metadata server

可能原因：
- NetworkPolicy 擋了 pod 連 `169.254.169.254`（metadata server）→ 放行
- 用了 `hostNetwork: true`（Autopilot 不允許）

## 參考

- [GKE Workload Identity 官方文件](https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity)
- [Workload Identity Federation（CI 端）](workload-identity-federation.md)
- 案例：[Lab 05b GKE module + WI demo](../labs/lab-05b-gke-module.md)
- 實測紀錄：[2026-05-20 log](../../logs/2026-05-20.md)
