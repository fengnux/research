-- evidence-pack: 當月 SARIF summary（markdown）
--
-- 用途：產出當月 finding 的 by-severity / by-level / top-rule 統計，markdown 格式，
--       供 audit/artifacts/<month>/sarif_summary.md。
-- 輸入：view sarif_findings（先 .read views/sarif_findings.sql）+ 變數 sarif_urls。
-- 輸出：markdown 表格（stdout）。
-- 前置：bootstrap.sql 已載入；sarif_urls 已 SET VARIABLE。
-- 回答的稽核問題：本月 IaC misconfiguration 有多少、嚴重度分布、最常觸發哪些規則。

.mode markdown

.print ''
.print '## 當月 finding 總數'
.print ''
SELECT month AS Month, count(*) AS Findings
FROM sarif_findings
WHERE month = (SELECT max(month) FROM sarif_findings)
GROUP BY month;

.print ''
.print '## By severity'
.print ''
SELECT
  severity AS Severity,
  count(*)  AS Count
FROM sarif_findings
WHERE month = (SELECT max(month) FROM sarif_findings)
GROUP BY severity
ORDER BY CASE severity
  WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1
  WHEN 'MEDIUM'   THEN 2 WHEN 'LOW'  THEN 3 ELSE 4 END;

.print ''
.print '## By SARIF level'
.print ''
SELECT level AS Level, count(*) AS Count
FROM sarif_findings
WHERE month = (SELECT max(month) FROM sarif_findings)
GROUP BY level
ORDER BY count(*) DESC;

.print ''
.print '## Top rules（前 10）'
.print ''
SELECT
  rule_id             AS Rule,
  any_value(severity) AS Severity,
  count(*)            AS Count,
  list_distinct(list(file))[1:3] AS "Sample Files"
FROM sarif_findings
WHERE month = (SELECT max(month) FROM sarif_findings)
GROUP BY rule_id
ORDER BY count(*) DESC
LIMIT 10;
