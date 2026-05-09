# Lab 01 - 環境準備：OpenTofu + Terramate + GCP

## 目標

安裝並設定 OpenTofu、Terramate，以及 GCP 本機認證環境，為後續實驗做好準備。

## 環境資訊

| 項目 | 值 |
|------|----|
| GCP 實驗 Project | `research-lab` |
| 預設 Region | `asia-east1` |
| State Backend Bucket | `research-lab-tofu-state` |
| 本機認證方式 | 個人帳號 ADC |

---

## 步驟

### 1. 安裝 tenv（OpenTofu 版本管理）

tenv 是 OpenTofu / Terraform / Terragrunt 的版本管理工具，類似 tfenv。

```bash
# macOS (Homebrew)
brew install tenv

# 驗證安裝
tenv --version
```

### 2. 安裝 OpenTofu

```bash
# 安裝最新版
tenv tofu install latest

# 設定全域預設版本
tenv tofu use latest

# 驗證安裝
tofu version
```

### 3. 安裝 Terramate

```bash
# 安裝最新版
tenv tm install latest

# 設定全域預設版本
tenv tm use latest

# 驗證安裝
terramate version
```

專案目錄內可用版本鎖定檔讓 tenv 自動切換版本：

```bash
# 在 opentofu/ 目錄下建立版本鎖定檔
echo "1.9.0" > research/iac/opentofu/.opentofu-version
echo "0.12.0" > research/iac/opentofu/.terramate-version
```

### 4. 安裝 Google Cloud SDK

```bash
# macOS (Homebrew)
brew install --cask google-cloud-sdk

# 驗證安裝
gcloud version
```

### 5. GCP 認證設定

```bash
# 登入個人帳號
gcloud auth login

# 設定 Application Default Credentials（OpenTofu 使用）
gcloud auth application-default login

# 確認目前使用的帳號
gcloud auth list

# 設定預設 project 為實驗 project
gcloud config set project research-lab
```

### 6. 確認實驗 Project 存在

```bash
gcloud projects describe research-lab
```

### 7. 啟用所需的 GCP API

```bash
gcloud services enable storage.googleapis.com \
  --project=research-lab
```

---

## 驗證清單

- [ ] `tenv version` 輸出版本號
- [ ] `tofu version` 輸出版本號
- [ ] `terramate version` 輸出版本號
- [ ] `gcloud auth list` 顯示已登入帳號
- [ ] `gcloud auth application-default print-access-token` 成功輸出 token
- [ ] `gcloud projects describe research-lab` 顯示 project 資訊

---

## 下一步

[Lab 02 - Bootstrap：建立 GCS State Bucket](lab-02-bootstrap.md)
