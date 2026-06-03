#!/usr/bin/env bash
# evidence-pack DuckDB wrapper
#
# 用途：注入短期 GCS token 後啟動 duckdb，自動載入 bootstrap.sql。
# token 來源：
#   - evidence-runner VM / GKE pod：attached SA via metadata server
#   - GHA runner：WIF 換來的短期 token
#   皆透過 `gcloud auth print-access-token`（非個人 ADC 的 application-default 變體）。
# 用法：
#   audit/sql/duckdb-wrap.sh                       # 互動 prompt
#   audit/sql/duckdb-wrap.sh -c "SELECT 1;"        # 單句
#   audit/sql/duckdb-wrap.sh < queries/foo.sql     # 由 stdin 讀 SQL
set -euo pipefail
export GCS_TOKEN=$(gcloud auth print-access-token)
exec duckdb -init "$(dirname "$0")/bootstrap.sql" "$@"
