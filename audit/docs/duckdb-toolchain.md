# evidence-runner 工具鏈

evidence-pack foundation 的 query pipeline 在專用 VM `evidence-runner` 上執行（見 [evidence-runner-instance](../labs/evidence-runner-instance.md)）。本文記錄 VM 上 pinned 工具版本、SHA256 與升版流程。

## 環境

| 項目 | 值 |
|------|----|
| VM | `evidence-runner`（e2-micro / Debian 12 / x86_64）|
| 安裝路徑 | `~/.local/bin/`（OS Login 使用者 home，無需 root）|
| token 來源 | attached SA `evidence-runner@…` via metadata server（`gcloud auth print-access-token`）|

## Pinned 版本

| 工具 | 版本 | 平台 | artifact SHA256 |
|------|------|------|-----------------|
| DuckDB | `v1.5.3` (Variegata) | `linux-amd64` | `35caef1fecbc8d7e2c07de4fd2cdefc5189ec9ba9e1cca228fb1a1c48cc52a8a`（`duckdb_cli-linux-amd64.zip`）|
| Trivy | `v0.71.0` | `Linux-64bit` | `30a3d22b23f88c233f1658f562fb477cae3b3e8b4761109d515b7698daf85814`（`trivy_0.71.0_Linux-64bit.tar.gz`）|

DuckDB binary（解壓後）SHA256：`03b7ca891c71d691f6f99ef5fafbc86480137471d271dddcfb46badaf4d2eb82`

> DuckDB ≥ 1.0 為 ADR-002 要求（`TYPE HTTP` + `EXTRA_HTTP_HEADERS` Secret）。

## 安裝（VM 內）

```bash
# unzip / git（apt，需 sudo；OS Login admin 才有）
sudo apt-get update -qq && sudo apt-get install -y unzip git

# DuckDB
mkdir -p ~/.local/bin
curl -fsSL -o /tmp/duckdb.zip \
  "https://github.com/duckdb/duckdb/releases/download/v1.5.3/duckdb_cli-linux-amd64.zip"
sha256sum /tmp/duckdb.zip   # 對 35caef1f...
unzip -o /tmp/duckdb.zip -d /tmp/duckdb-extract
mv /tmp/duckdb-extract/duckdb ~/.local/bin/duckdb && chmod +x ~/.local/bin/duckdb

# Trivy
curl -fsSL -o /tmp/trivy.tgz \
  "https://github.com/aquasecurity/trivy/releases/download/v0.71.0/trivy_0.71.0_Linux-64bit.tar.gz"
sha256sum /tmp/trivy.tgz    # 對 30a3d22b...
tar -xzf /tmp/trivy.tgz -C /tmp trivy
mv /tmp/trivy ~/.local/bin/trivy && chmod +x ~/.local/bin/trivy

export PATH="$HOME/.local/bin:$PATH"
```

## 升版流程

1. 查 GitHub release 最新 stable tag
2. 更新本文版本與 SHA256
3. VM 內重跑安裝、`duckdb --version` / `trivy --version` 驗證
4. 重跑 `audit/sql/` 全部 SQL 確認無破壞性變更（DuckDB major version 升級時尤其）
5. 變更記入當日 `logs/`

## 備註

- VM 為計費資源，lab 間隔 stop、系列完成後 destroy；重建後需重跑本安裝（未來可考慮 startup-script 自動化，見 foundation lab「不在本 lab 範圍」）。
- `~/.local/bin` 需在 `PATH`；非 login shell 可能要手動 `export PATH="$HOME/.local/bin:$PATH"`。
