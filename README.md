# Debt Collection Analytics Platform

> **"Reliable metrics come from correct data modeling — not from dashboards."**

End-to-end analytical architecture for a debt collection operation, built on SQL Server and Power BI. The core challenge was not visualization — it was correcting structural KPI distortions caused by undefined granularity, many-to-many relationships, and business logic scattered across ad-hoc queries.

---

## Architecture

```
SQL Server (dtdi schema)
        │
        ▼
SQL Layer — T-SQL · CTEs · Window Functions
        │
        ▼
Power Query (M) — ETL · Cartesian joins · Type coercion
        │
        ▼
DAX — Semantic layer · KPI definitions · Star schema
        │
        ▼
Power BI — 5 dashboards · 25 relationships (all 1:N)
```

---

## The Problem

The operational system stores data across four independent event domains with no natural bridge between them:

| Domain | Key | Problem |
|--------|-----|---------|
| Dialer | `uniqueid` | No `case_id` — joined via temporal match |
| Contact (CRM) | `contact_id` | Links to case via `case_id`; to PTP via `contact_id` |
| PTP | `ref_number` | Multiple PTPs per case per month — dedup required |
| Payment | `ref_number` | Same financial key as PTP; separate domain |

Without explicit modeling, joining these domains directly produces metric inflation — the same payment counted multiple times, or PTP conversion rates distorted by duplicate rows.

---

## Key Engineering Decisions

### 1. Dialer has no `case_id` — solved with temporal join

`dtdi.dialer` records call attempts but does not carry `case_id`. The bridge table `dtdi.dialer_contact` links `unique_id → sip_account → users_id`, but associating a call to a CRM contact requires a time-window match:

```sql
-- Fact_contacts.sql
INNER JOIN dialer_calls d
    ON d.telecom_id = cb.telecom_id
   AND d.case_id    = cb.case_id
   AND d.call_date BETWEEN
        DATEADD(MINUTE, -15, cb.contact_date)
        AND DATEADD(MINUTE,  15, cb.contact_date)
```

A `ROW_NUMBER()` then keeps only the most recent dialer match per `contact_id`, eliminating fan-out.

---

### 2. PTP deduplication via `ROW_NUMBER`, not `DISTINCT`

`vw_ptp_ptpr_overview` returns multiple PTP rows per case per month (installment plans, renegotiations). `DISTINCT` would collapse rows arbitrarily. The deterministic approach:

```sql
-- Fact_ptp_enriched.sql
ROW_NUMBER() OVER (
    PARTITION BY ptp.case_id, YEAR(ptp.promise_date), MONTH(ptp.promise_date)
    ORDER BY
        CASE WHEN ptp.type = 'Installment' THEN 1 ELSE 2 END,
        ptp.promise_capital_total DESC,
        ptp.contact_date DESC
) AS rn
```

Priority: Installment type → highest value → most recent contact. Same input always produces same output.

---

### 3. Operator presence via cartesian join

There is no attendance system. Presence is inferred from daily contact activity:

1. Generate all business days from 2025-01-01 (UTC-3, Brazil)
2. Filter operators: `sip_account >= 200` = `is_operator`
3. **Cartesian join**: all operators × all workdays → one row per operator per day
4. Left join CC activity: `contact_count > 0` → `Presente`, else `Faltou`
5. Exception: 2-day training grace period after `insert_date`

```m
-- Fact_operator_presence.m
CrossJoin = Table.AddColumn(Operators, "AllDates", each CleanDates),
Expanded  = Table.ExpandTableColumn(CrossJoin, "AllDates", {"WorkDate"})
```

This defines a proper fact grain rather than relying on absence of data to infer absence of person.

---

### 4. NEW vs OLD money classification

```sql
-- Fact_ptp_enriched.sql
CASE
    WHEN has_previous_payment = 1 THEN 'OLD MONEY'
    ELSE 'NEW MONEY'
END AS money_type
```

`has_previous_payment` is a correlated subquery checking for any payment on the same `ref_number` in the previous 30 days. This classification drives commission rules per client and separates recovered dormant debt from active payment plans.

---

### 5. Geographic enrichment via inline `ddd_map` CTE

Phone numbers carry a Brazilian area code (DDD) in positions 3–4. All 67 DDDs are mapped to states inline — no separate lookup table required:

```sql
-- Fact_ptp.sql
SUBSTRING(o.phone_number, 3, 2) AS ddd
-- joined to ddd_map CTE → UF (27 states)
```

This enables Paid by UF analysis and the geographic bubble map without adding a dimension to the model.

---

### 6. Contact time reconstruction (two-source fallback)

PTP records store only `contact_date` (no time component). To enable hourly analysis:

```sql
-- Primary:  vw_cases_promises_information → MAX(contact_time) per case/date/operator
-- Fallback: dtdi.installment → MIN(insert_date) as time proxy
COALESCE(ct.contact_time, it.contact_time) AS contact_time
```

This recovers a contact timestamp for the vast majority of records.

---

## Star Schema

**Fact tables** — event-based grain:

| Table | Grain | Primary Key |
|-------|-------|-------------|
| Cobrança (Fact_ptp) | PTP event | `case_id` + `contact_date` + `operator` |
| Fato_Dialer | Call attempt | `uniqueid` |
| Manual (Fact_contacts) | CRM contact | `contact_id` |
| Fact_ptp_enriched | PTP per case per month | `ref_number` + month |
| Payments | Payment transaction | `payment_id` |
| Falta (Fact_presence) | Operator × workday | `users_id` + `WorkDate` |

**Dimension tables** — conformed and shared:

| Table | Purpose |
|-------|---------|
| Query1_Ref | Operators, sip_account, active/inactive flags |
| Company | Company → client mapping |
| Case | Contract attributes, DPD, provider (attr 303) |
| DateTable | Calendar, workdays, WeekOfMonth (UTC-3) |
| Dim_CommissionRules | Commission rates per client |

**25 relationships — all 1:N. Zero many-to-many.**

---

## Power BI Relationship Map

```
DateTable ──── Cobrança   [contact_date · payment_date · promise_date]
DateTable ──── Dialer     [call_date]
DateTable ──── Manual     [contact_day]
DateTable ──── Falta      [WorkDate]
DateTable ──── Payments   [payment_date]
DateTable ──── Old Vs New [payment_date]
DateTable ──── Operadores [Date]

Query1_Ref ─── Cobrança   [operator_id]
Query1_Ref ─── Dialer     [operator_id]
Query1_Ref ─── Manual     [operator_id]
Query1_Ref ─── Falta      [users_id]
Query1_Ref ─── CC         [users_id]
Query1_Ref ─── Operadores [Operator ID]

Company ─────  Cobrança   [client_id]
Company ─────  Dialer     [client_id]
Company ─────  Manual     [client_id]
Company ─────  Payments   [client_id]
Company ─────  Old Vs New [client_id]
Company ─────  Dim_CommissionRules [client_id]

Case ────────  Cobrança   [case_id]
Case ────────  Dialer     [case_id]
Case ────────  Manual     [case_id]
```

---

## Key Metrics

| Metric | Definition |
|--------|-----------|
| Effectivity % | Paid PTP / Total PTP promises |
| Score Dialer | Dialer PTPs / Answered calls |
| Índice PTP | PTP / CC contacts per operator |
| Score Final | Composite weighted PTP quality score |
| Paid / RPC | Revenue generated per Right Party Contact |
| Commission Value | Paid × rate from `Dim_CommissionRules` |
| Forecast EOM | Daily pace × remaining workdays in month |
| % Faltas | Absent days / total workdays per operator |
| CPC rate | Calls with billsec ≥ 40s + sip ≠ null / total |
| Recovery % | Paid capital / Actual capital in portfolio |

All metrics trace back to a source event row. No metric is computed from another measure inside a FILTER context.

---

## Dashboards

| Dashboard | Audience | Key Visuals |
|-----------|----------|-------------|
| Operational | Supervisors | Dialer KPIs, Score ranking, answered/failed/no-answer % by date |
| Commission | Management | Paid by client, Forecast EOM, weekly pace, PTP by RCP |
| Attendance | HR / Ops | Presente/Faltou matrix per operator × day, % Faltas by week |
| Geographic | Strategy | Paid by UF, bubble map Brazil, Was Paid % by state |
| Executive | Directors | DPD analysis, recovery potential, portfolio composition |

---

## Performance Design

- **Rolling windows**: Dialer and contacts filtered to last 60 days at SQL layer — not in Power Query
- **Dynamic date parameters**: `@startDate / @endDate` computed at query time via `DATEFROMPARTS` and `GETDATE()`
- **Pre-aggregation**: CC table aggregates `COUNT_BIG(*) GROUP BY user, date` before joining in Power Query
- **`COUNT_BIG`**: Used instead of `COUNT` for stability on high-volume contact tables
- **Pushed predicates**: Every fact table has date range filters at the `WHERE` clause — no full scans

---

## Repository Structure

```
.
├── dax/
│   └── Dim_date.dax
├── powerquery/
│   ├── Cc_operator_activity.m
│   ├── Dim_operators_powerquery.m
│   └── Fact_operator_presence.m
├── sql/
│   ├── Dim_cases.sql
│   ├── Dim_client.sql
│   ├── Dim_company.sql
│   ├── Fact_contacts.sql
│   ├── Fact_dialer.sql
│   ├── Fact_payments.sql
│   ├── Fact_ptp.sql
│   └── Fact_ptp_enriched.sql
├── data-model/
│   ├── star_schema.png
│   ├── event_flow.svg
│   └── architecture.png
└── README.md
```

---

## Technologies

- **SQL Server** — source system, T-SQL, CTEs, Window Functions
- **Power Query (M)** — ETL, cartesian joins, type coercion, dynamic date tables
- **DAX** — semantic layer, time intelligence, row-level FILTER logic
- **Power BI** — star schema model, 5 dashboards, 25 1:N relationships
- **Dimensional Modeling** — Star Schema, event-driven fact grain

---

## Next Steps

- Cloud migration (AWS Redshift or Azure Synapse)
- Orchestration with Apache Airflow (incremental loads)
- Partitioning strategy for high-volume fact tables
- Real-time pipeline via Change Data Capture (CDC)
- PTP conversion probability model by DPD band

---

## Author

**Paulo Potter Marchi** — Data Analyst → Data Engineer

Special thanks to **Victor Silveira** for technical mentorship throughout this project.
