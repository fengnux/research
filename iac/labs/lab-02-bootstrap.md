# Lab 02 - Bootstrap：建立 GCS State Bucket

## 目標

使用 OpenTofu 在 `research-lab` project 建立 GCS bucket，作為後續所有 stack 的 remote state backend。
Bootstrap stack 本身使用 local state（雞生蛋問題）。

## 前置條件

- 完成 [Lab 01 - 環境準備](lab-01-environment-setup.md)

---

## 步驟

### 1. 初始化 Terramate 專案

在 `opentofu/` 根目錄執行：

```bash
cd research/iac/opentofu

terramate create --all-terraform
```

這會掃描現有目錄並初始化 Terramate 專案（若 `terramate.tm.hcl` 尚未存在）。

### 2. 建立 bootstrap stack 的 OpenTofu 設定

`stacks/bootstrap/` 目錄內已有設定檔，直接初始化並 apply：

```bash
cd stacks/bootstrap

tofu init
tofu plan
tofu apply
```

Apply 完成後確認 bucket 已建立：

```bash
gcloud storage buckets describe gs://research-lab-tofu-state
```

---

## 驗證清單

- [ ] `tofu apply` 執行成功，無錯誤
- [ ] GCS bucket `research-lab-tofu-state` 存在於 `research-lab` project
- [ ] Bucket 位於 `asia-east1` region
- [ ] Versioning 已啟用

---

## 下一步

[Lab 03 - Terramate 專案初始化與第一個 Stack](lab-03-first-stack.md)
