# Debt Collection Analytics — Data Engineering Pipeline

> **"Reliable metrics come from correct data modeling — not from dashboards."**

End-to-end Data Engineering pipeline for a debt collection operation.
Built on **Databricks + Delta Lake**, translating production T-SQL into PySpark — CTE by CTE.

---

## Architecture

```
Synthetic Data (Python · Faker)
simulating debthor_dbs_interface.dtdi
        │
        ▼
┌──────────────────────────────────────────┐
│        Databricks Community Edition      │
│                                          │
│  Bronze          Silver          Gold    │
│  ───────         ──────          ────    │
│  11 tables  →   5 facts    →   3 dims   │
│  (raw dtdi)     (T-SQL→Spark)  + quality │
└──────────────────────────────────────────┘
        │
        ▼
Delta Lake (DBFS)
```

---

## Notebooks

| # | File | Source SQL | What it does |
|---|------|-----------|--------------|
| 01 | `01_bronze_ingest.py` | — | 11 synthetic tables mirroring dtdi schema |
| 02 | `02_silver_fact_dialer.py` | `Fact_dialer.sql` | dialer_contact_dedup → dialer_base → dialer_final |
| 03 | `03_silver_fact_ptp.py` | `Fact_ptp.sql` | ddd_map · contact_time · installment_time · promise_base · promise_enriched |
| 04 | `04_silver_remaining_facts.py` | `Fact_ptp_enriched.sql` · `Fact_contacts.sql` · `Fact_payments.sql` | NEW/OLD MONEY · ±15min dialer join · payment enrichment |
| 05 | `05_gold_dims_quality.py` | `Dim_cases.sql` · `Dim_client.sql` · `Dim_company.sql` | Dimensions + 15 data quality checks |

---

## Key Business Rules Implemented

| Rule | Source SQL | Implementation |
|------|-----------|----------------|
| Dialer contact dedup | `Fact_dialer` | ROW_NUMBER PARTITION BY unique_id ORDER BY call_date DESC |
| CPC flag | `Fact_dialer` | billsec >= 40 AND sip_account IS NOT NULL |
| Operator not connected | `Fact_dialer` | billsec > 3 AND sip_account IS NULL |
| DDD → State (67 DDDs) | `Fact_ptp` | SUBSTRING(phone,3,2) → UF map |
| Contact time fallback | `Fact_ptp` | COALESCE(contact_time, MIN(installment.insert_date)) |
| PTP dedup per case/month | `Fact_ptp_enriched` | Installment priority → capital desc → contact_date desc |
| NEW vs OLD MONEY | `Fact_ptp_enriched` | EXISTS on prior 30-day payments → left_anti join |
| ±15 min dialer match | `Fact_contacts` | Temporal join + fan-out guard |
| Channel detection | `Fact_contacts` | LIKE whats/rcs/sms/email/bot |
| Dim_company filter | `Dim_company` | client_id > 1 AND client_id <> 999 |

---

## Stack

- **Databricks Community Edition** — free
- **Apache Spark (PySpark)** — Window functions, temporal joins, anti-joins
- **Delta Lake** — ACID, schema enforcement
- **Python / Faker** — synthetic data (pt_BR)
