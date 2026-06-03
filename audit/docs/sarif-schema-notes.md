# SARIF schema 與 DuckDB 踩坑筆記

evidence-pack foundation（[evidence-pack-foundation](../labs/evidence-pack-foundation.md)）建 `sarif_findings` view 過程記錄。資料源：Trivy `v0.71.0` `config` 子命令的 SARIF 輸出。

## 1. Trivy SARIF 巢狀結構（實測）

```
<root>
├── runs[]
│   ├── tool.driver.name            → "Trivy"
│   ├── tool.driver.rules[]         → 規則定義（id、help、properties…）
│   └── results[]                   → 一個 finding
│       ├── ruleId                  → 如 "GCP-0067"
│       ├── level                   → note / warning / error（見 §3）
│       ├── message.text            → 多行文字，含 "Severity: MEDIUM" 等
│       └── locations[]
│           └── physicalLocation
│               ├── artifactLocation.uri    → 檔案相對路徑
│               └── region.startLine         → 行號
```

- 一個 `result` 可有多個 `locations`，view 用 `UNNEST(result.locations)` 展開 → 一個 location 一列。本次資料每個 result 皆單一 location，故 finding 數 = result 數 = 21。
- `read_json_auto` 需要 `maximum_depth = -1`，否則深層巢狀會被當成 JSON 字串而非 struct，後續 `.` 取值失敗。

## 2. ⚠️ 最大的坑：`TYPE HTTP` + bearer token 不支援 glob

DuckDB httpfs 走 **plain HTTPS**（`https://storage.googleapis.com/...`，配 ADR-002 的 `TYPE HTTP` + bearer token secret）時：

```
Invalid Input Error: Globs (`*`) for generic HTTP file is are not supported.
Consider `SET allow_asterisks_in_http_paths = true;` to allow this behaviour
```

原因：plain HTTPS 端點無法列舉 bucket 物件，所以 `*` 無從展開。`allow_asterisks_in_http_paths` 也救不了（它只是允許字面 `*`，仍不會去列舉）。glob 要能用得改走 S3-compat（`TYPE GCS` + HMAC），但那違反 ADR-002「不用 long-lived credential」。

### 採用解法：先列舉，再以明確 URL 清單讀取

orchestration（shell）用 **gsutil**（已用 attached SA token 認證）列舉物件，轉成 https URL 清單，注入 DuckDB 變數：

```bash
mapfile -t GS < <(gsutil ls 'gs://<bucket>/sarif/2026-06/*.sarif.json')
URLS=""; for g in "${GS[@]}"; do URLS+="'${g/gs:\/\//https://storage.googleapis.com/}', "; done
URLS="[ ${URLS%, } ]"
```

```sql
SET VARIABLE sarif_urls = [ 'https://.../a.sarif.json', 'https://.../b.sarif.json' ];
-- view 內以 getvariable('sarif_urls') 當 read_json_auto 路徑參數
```

`read_json_auto(getvariable('sarif_urls'), ...)` 接受 list 並逐一 GET（每個都帶 bearer token），驗證可行。這個「列舉與讀取分離」反而貼近真實 orchestration 架構（一個 lister + DuckDB reader），且未來換 GHA/GKE 只要換 token 來源與 lister，SQL 不動。

## 3. `level` vs 真實 severity

SARIF `result.level` 只有 `note / warning / error`。Trivy 的 severity→level 映射（實測）：

| Trivy severity | SARIF level |
|----------------|-------------|
| LOW | note |
| MEDIUM | warning |
| HIGH / CRITICAL | error（本次資料未出現）|

真實 severity（LOW/MEDIUM/HIGH/CRITICAL）字串在 `message.text` 內（`Severity: XXX`）。view 用 `regexp_extract(message.text, 'Severity: (\w+)', 1)` 取出 `severity` 欄位，比 `level` 更貼稽核語彙。summary 同時保留 `level` 與 `severity` 兩種統計。

> 更穩健的來源是 `runs[].tool.driver.rules[].properties.security-severity`（CVSS 數值）或 rule `defaultConfiguration.level`，但需先把 rules 攤平再 join ruleId；本階段用 message 解析已足夠，留待跨來源 JOIN lab 再評估。

## 4. schema fingerprint（升版前驗）

- Trivy `v0.71.0`、SARIF schema 2.1.0
- 欄位路徑如 §1。Trivy 升版若改 `message.text` 格式（"Severity: " 字樣），§3 的 regexp 會失效 → severity 變空字串，需同步更新 view。
