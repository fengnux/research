-- evidence-pack: SARIF → 扁平 findings view
--
-- 用途：把 Trivy SARIF（巢狀 JSON）展平成「一行一個 finding」，供月度 summary 與
--       未來跨來源 JOIN 使用。
-- 輸入：DuckDB 變數 sarif_urls — SARIF 物件的 https URL 清單。
--       orchestration 先 `SET VARIABLE sarif_urls = ['https://.../x.sarif.json', ...]`。
--       清單以 gsutil 列舉 evidence bucket 取得：因 TYPE HTTP + bearer token 走
--       plain HTTPS 不支援 glob（`*`），需先列舉再以明確 URL 讀取
--       （見 ../../docs/sarif-schema-notes.md）。
-- 輸出：view sarif_findings(month, tool, rule_id, level, severity, message,
--       file, line, source_object)。一個 result 的多個 location 會展成多列。
-- 前置：bootstrap.sql 已載入（httpfs + gcs_token secret）。

CREATE OR REPLACE VIEW sarif_findings AS
WITH src AS (
  SELECT filename, runs
  FROM read_json_auto(getvariable('sarif_urls'), filename = true, maximum_depth = -1)
)
SELECT
  regexp_extract(filename, 'sarif/([0-9]{4}-[0-9]{2})/', 1)  AS month,
  run.tool.driver.name                                       AS tool,
  result.ruleId                                              AS rule_id,
  result.level                                               AS level,
  regexp_extract(result.message.text, 'Severity: (\w+)', 1)  AS severity,
  result.message.text                                        AS message,
  loc.physicalLocation.artifactLocation.uri                  AS file,
  loc.physicalLocation.region.startLine                      AS line,
  filename                                                   AS source_object
FROM src,
     UNNEST(src.runs)         AS t(run),
     UNNEST(run.results)      AS r(result),
     UNNEST(result.locations) AS l(loc);
