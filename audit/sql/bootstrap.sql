-- evidence-pack DuckDB session bootstrap
--
-- 用途：每個 DuckDB session 起始時跑，安裝 httpfs extension 並以短期
--       Bearer token 建立讀 GCS 的 HTTP secret（per audit ADR-002）。
-- 輸入：環境變數 GCS_TOKEN（短期 access token）。
--       evidence-runner VM 上：export GCS_TOKEN=$(gcloud auth print-access-token)
--       （token 來自 VM attached SA via metadata server）
-- 輸出：無（建立 session 狀態）。由 duckdb-wrap.sh 以 -init 載入。

INSTALL httpfs;
LOAD httpfs;

CREATE OR REPLACE SECRET gcs_token (
  TYPE HTTP,
  EXTRA_HTTP_HEADERS MAP {
    'Authorization': 'Bearer ' || getenv('GCS_TOKEN')
  }
);
