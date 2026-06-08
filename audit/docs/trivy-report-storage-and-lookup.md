# Trivy 報告：儲存方式與單筆 finding 查詢

> 給自己消化用的操作參考。evidence-pack foundation lab（2026-06）剛完工，這份把
> 「Trivy 報告存在哪、怎麼看某一筆掃描結果的細節」整理成一頁，避免日後重新摸索。
> 對應 runbook：[evidence-pack-foundation](../labs/evidence-pack-foundation.md)。

## 1. 三層儲存架構

`iac/`（即 `tofu-terramate-lab`）跟 `audit/` 是**生產 / 消費**關係：CI 端產出原始訊號，
evidence-runner 端消費成製品。Trivy 報告因此分三層存放：

```
tofu-terramate-lab CI（Trivy 掃描）
   │  上傳原始 SARIF
   ▼
gs://research-lab-495809-evidence/sarif/YYYY-MM/*.sarif.json   ← 正本（原始證據）
   │  evidence-runner VM 上 DuckDB pipeline 消費
   ▼
research/audit/artifacts/YYYY-MM/sarif_summary.md              ← 彙整製品（commit 進 repo）
```

| 層 | 位置 | 內容 | 用途 |
|----|------|------|------|
| **原始 SARIF** | `gs://…-evidence/sarif/YYYY-MM/` | Trivy 完整輸出，逐筆 finding（含 rule / level / file / line） | 不可竄改的原始證據；逐筆細節都在這 |
| **彙整報告** | `audit/artifacts/YYYY-MM/sarif_summary.md` | 月度統計：總數、by severity、by level、Top rules | 快速總覽，**不含每筆細節** |
| **查詢引擎** | `audit/sql/`（DuckDB view + queries） | 把巢狀 SARIF 展平成「一行一 finding」 | 想看單筆細節時用這個查正本 |

## 2. 跟 GitHub Code Scanning 的關係

GitHub Code Scanning（Security 分頁，category `trivy-iac-pr` / `trivy-iac-full`）**仍然存在**，
但它跟 evidence-pack 目的不同，不要搞混：

- **Code Scanning** = iac/ 端的**即時把關**。PR 掃 changed stacks、定期掃全庫，HIGH/CRITICAL 擋 merge。
- **evidence-pack** = 把訊號**長期固化成可交給稽核員的製品**。原始 SARIF 進 evidence bucket，
  DuckDB 彙整成 markdown artifact。

## 3. 查「某一筆掃描結果」的詳細資訊

`sarif_summary.md` 只給彙整數字。要看單筆 finding 細節，得透過 DuckDB 查 evidence bucket 裡的原始
SARIF。`sarif_findings` view 已把每筆展平成欄位：
`month, tool, rule_id, level, severity, message, file, line, source_object`。

> 需在能拿到 GCS token 的環境執行（evidence-runner VM 的 attached SA，或有 WIF token 的 runner）。
> `duckdb-wrap.sh` 會自動注入 token 並載入 `bootstrap.sql`。

**步驟 1 — 列舉當月 SARIF 物件**（plain HTTPS + bearer token 不支援 `*` glob，需先列舉）：

```bash
gsutil ls 'gs://research-lab-495809-evidence/sarif/2026-06/'
```

**步驟 2 — 進 DuckDB，設定來源 URL 並載 view：**

```bash
cd ~/research/audit/sql && ./duckdb-wrap.sh
```

```sql
SET VARIABLE sarif_urls = ['https://storage.googleapis.com/research-lab-495809-evidence/sarif/2026-06/test-20260603-152124.sarif.json'];
.read views/sarif_findings.sql
```

**步驟 3 — 查單筆細節。** 例如想看 summary 裡那筆 `GCP-0076`：

```sql
SELECT rule_id, severity, level, file, line, message
FROM sarif_findings
WHERE rule_id = 'GCP-0076';
```

或鎖定某個檔案 / 某行：

```sql
SELECT * FROM sarif_findings
WHERE file LIKE '%dev/vm/main.tf%'
ORDER BY line;
```

- `message` = Trivy 對該筆的完整描述（含 Severity 與說明）
- `file` + `line` = 指回 `tofu-terramate-lab` 的原始碼位置

## 4. 相關檔案索引

| 檔案 | 作用 |
|------|------|
| [`audit/sql/duckdb-wrap.sh`](../sql/duckdb-wrap.sh) | 注入 GCS token、載 bootstrap 後啟動 duckdb |
| [`audit/sql/bootstrap.sql`](../sql/bootstrap.sql) | 載入 httpfs + 設定 gcs_token secret |
| [`audit/sql/views/sarif_findings.sql`](../sql/views/sarif_findings.sql) | SARIF → 扁平 findings view（一行一筆） |
| [`audit/sql/queries/monthly_sarif_summary.sql`](../sql/queries/monthly_sarif_summary.sql) | 產出月度彙整（artifacts 的來源查詢） |
| [`audit/docs/sarif-schema-notes.md`](sarif-schema-notes.md) | SARIF schema 與 glob 限制等技術細節 |
| [`audit/labs/evidence-pack-foundation.md`](../labs/evidence-pack-foundation.md) | foundation lab 完整重現步驟 |

---
*建立於 2026-06-08，作為 evidence-pack foundation lab 後的消化筆記。*
