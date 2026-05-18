---
status: 草稿（對應 lab-scc-custom-findings.md，尚未執行）
date: 2026-05-18
---

# ADR-004 — SCC 使用 Standard tier，不啟用 Premium

## 背景

GCP Security Command Center（SCC）有三個 tier：
- **Standard**：免費，支援 Custom Findings API、基本安全發現
- **Premium**：付費，依 org 整體 GCP 月支出計費，支援 forward 到外部 SIEM（Splunk、Chronicle 等）
- **Enterprise**：付費，含 SOAR、case management

Lab 需要把 unmanaged resource 寫成 SCC Custom Finding，讓 SOC 在既有平台看到。

## 決策

使用 **Standard tier，project 層級啟用**。Custom Findings API 在 Standard 就能用，
不需要 Premium 的 SIEM forward 功能（SOC 整合可走 Cloud Logging sink，不依賴 SCC Premium）。

## 考慮過的替代方案

- **Premium tier**：原生支援 forward 到 Splunk / Chronicle，SOC 整合更省事。
  但 Premium 是 org 層級計費（依整體 GCP 月支出的百分比），lab 規模划不來，且有 annual commitment 難退出
- **Enterprise tier**：含 SOAR，對 lab 規模完全 over-engineering

## 風險

- Console 操作時容易誤點 Premium trial → **啟用前務必確認選 Standard + project 層級**
- SOC 若未來需要原生 SIEM forward，需重新評估 tier 升級成本

## 後果

- Custom Findings 正常運作，SOC 可在 SCC Console 看到 finding
- SIEM forward 需另走 Cloud Logging → Log Sink → Pub/Sub → SIEM 路線（多一層，但費用可控）
- Standard tier 可隨時在 Console 停用，無 commitment
