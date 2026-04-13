# Power BI Relationship Map

> **25 relationships · all 1:N · zero many-to-many**
>
> Data model documentation for the Debt Collection Analytics Platform — SQL Server · Power Query · DAX · Power BI

---

## Table of Contents

1. [Overview](#1-overview)
2. [Conformed Dimensions](#2-conformed-dimensions)
3. [Full Map of All 25 Relationships](#3-full-map-of-all-25-relationships)
4. [Table-by-Table Breakdown](#4-table-by-table-breakdown)
   - [Cobrança](#cobrança)
   - [Dialer](#dialer)
   - [Manual](#manual)
   - [Payments](#payments)
   - [Old Vs New](#old-vs-new)
   - [Falta](#falta)
   - [Operadores](#operadores)
   - [CC](#cc)
   - [Case](#case)
   - [Dim_CommissionRules](#dim_commissionrules)
5. [Modeling Rules](#5-modeling-rules)
   - [Why all relationships are 1:N](#51-why-all-relationships-are-1n)
   - [DateTable with multiple roles in Cobrança](#52-datetable-with-multiple-roles-in-cobrança)
   - [client_id ≠ company_id](#53-client_id--company_id)
   - [Dialer has no case_id in the source](#54-dialer-has-no-case_id-in-the-source)
   - [Anti-patterns avoided](#55-anti-patterns-avoided)

---

## 1. Overview

The Power BI model follows the **Star Schema** pattern: fact tables connected to conformed dimensions via 1:N keys — no many-to-many relationships.

```
DateTable ────────────────────────────────────── temporal dimension
Query1_Ref (Dim_Operator) ──────────────────────── operator dimension
Company ────────────────────────────────────────── company / portfolio dimension
Case ───────────────────────────────────────────── contract dimension
       │              │              │              │
    Cobrança       Dialer         Manual         Payments
    Old Vs New     Falta          Operadores     CC
    Dim_CommissionRules
```

> **Core rule:** every cross-domain join must go through one of the four conformed dimensions. Direct joins between two fact tables are never allowed.

---

## 2. Conformed Dimensions

| Dimension | PK | Description |
|---|---|---|
| `DateTable` | `Date` | Brazilian calendar (UTC-3). DAX calculated columns: `WeekOfMonth`, `IsBusinessDay`. Used by 7 fact tables via role-playing dimensions. |
| `Query1_Ref` | `users_id` | Dim_Operator. Contains `user_id`, `user_name`, `sip_account`, and derived flags `is_operator` / `is_inactive`. |
| `Company` | `client_id` | Companies and debt portfolios. Note: `client_id ≠ company_id` in the operational source. |
| `Case` | `case_id` | Individual debt contracts. Always referenced alongside `Company` to avoid joining directly on `debtor_id`. |

---

## 3. Full Map of All 25 Relationships

| # | Fact / Bridge Table | FK Column | Dimension | PK Column | Type |
|---|---|---|---|---|---|
| 1 | `Case` | `client_id` | `Company` | `client_id` | 1:N |
| 2 | `CC` | `users_id` | `Query1_Ref` | `users_id` | 1:N |
| 3 | `Cobrança` | `case_id` | `Case` | `case_id` | 1:N |
| 4 | `Cobrança` | `client_id` | `Company` | `client_id` | 1:N |
| 5 | `Cobrança` | `contact_date` | `DateTable` | `Date` | 1:N |
| 6 | `Cobrança` | `operator_id` | `Query1_Ref` | `users_id` | 1:N |
| 7 | `Cobrança` | `payment_date` | `DateTable` | `Date` | 1:N |
| 8 | `Cobrança` | `promise_date` | `DateTable` | `Date` | 1:N |
| 9 | `Dialer` | `call_date` | `DateTable` | `Date` | 1:N |
| 10 | `Dialer` | `case_id` | `Case` | `case_id` | 1:N |
| 11 | `Dialer` | `client_id` | `Company` | `client_id` | 1:N |
| 12 | `Dialer` | `operator_id` | `Query1_Ref` | `users_id` | 1:N |
| 13 | `Dim_CommissionRules` | `client_id` | `Company` | `client_id` | 1:N |
| 14 | `Falta` | `users_id` | `Query1_Ref` | `users_id` | 1:N |
| 15 | `Falta` | `WorkDate` | `DateTable` | `Date` | 1:N |
| 16 | `Manual` | `case_id` | `Case` | `case_id` | 1:N |
| 17 | `Manual` | `client_id` | `Company` | `client_id` | 1:N |
| 18 | `Manual` | `contact_day` | `DateTable` | `Date` | 1:N |
| 19 | `Manual` | `operator_id` | `Query1_Ref` | `users_id` | 1:N |
| 20 | `Old Vs New` | `client_id` | `Company` | `client_id` | 1:N |
| 21 | `Old Vs New` | `payment_date` | `DateTable` | `Date` | 1:N |
| 22 | `Operadores` | `Date` | `DateTable` | `Date` | 1:N |
| 23 | `Operadores` | `Operator ID` | `Query1_Ref` | `users_id` | 1:N |
| 24 | `Payments` | `client_id` | `Company` | `client_id` | 1:N |
| 25 | `Payments` | `payment_date` | `DateTable` | `Date` | 1:N |

---

## 4. Table-by-Table Breakdown

---

### Cobrança

The main fact table. Records contacts, promises, and payments. It holds **three date FKs** pointing to `DateTable` (multi-date granularity), plus links to the operator, company, and contract dimensions.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `case_id` | `Case` | `case_id` | Links the fact to the individual debt contract |
| `client_id` | `Company` | `client_id` | Links the fact to the company / portfolio |
| `contact_date` | `DateTable` | `Date` | Temporal filter on the contact date |
| `operator_id` | `Query1_Ref` | `users_id` | Identifies the operator responsible for the contact |
| `payment_date` | `DateTable` | `Date` | Temporal filter on the payment date |
| `promise_date` | `DateTable` | `Date` | Temporal filter on the promise-to-pay date |

> ⚠️ The three date columns create **role-playing dimensions** on `DateTable`. Only one relationship can be active at a time. The active one is `contact_date → DateTable[Date]`; the others are accessed via `USERELATIONSHIP()` inside specific DAX measures.

---

### Dialer

Fact table for automated dialer call attempts. Links each call to an operator, company, and contract.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `call_date` | `DateTable` | `Date` | Temporal filter on the call date |
| `case_id` | `Case` | `case_id` | Links the call to the contract |
| `client_id` | `Company` | `client_id` | Links the call to the company / portfolio |
| `operator_id` | `Query1_Ref` | `users_id` | Identifies the operator who made the call |

> ℹ️ The source table (`dtdi.dialer`) does not contain `case_id`. The contract link is built at the SQL layer via a ±15-minute temporal join. See [section 5.4](#54-dialer-has-no-case_id-in-the-source).

---

### Manual

Fact table for manual contacts (WhatsApp, direct calls, etc.). Parallel structure to Dialer.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `case_id` | `Case` | `case_id` | Links the contact to the contract |
| `client_id` | `Company` | `client_id` | Links the contact to the company / portfolio |
| `contact_day` | `DateTable` | `Date` | Temporal filter on the contact date |
| `operator_id` | `Query1_Ref` | `users_id` | Identifies the operator responsible |

---

### Payments

Fact table for received payments.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `client_id` | `Company` | `client_id` | Links the payment to the company / portfolio |
| `payment_date` | `DateTable` | `Date` | Temporal filter on the payment date |

---

### Old Vs New

Fact table that classifies payments as new money (NEW) or old money (OLD) within a 30-day window.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `client_id` | `Company` | `client_id` | Links the classification to the company / portfolio |
| `payment_date` | `DateTable` | `Date` | Temporal filter on the payment date |

---

### Falta

Fact table for operator attendance. Built from a cartesian join of operators × business days, then LEFT JOINed against actual activity records.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `users_id` | `Query1_Ref` | `users_id` | Identifies the operator |
| `WorkDate` | `DateTable` | `Date` | Links the attendance record to the business day |

---

### Operadores

Auxiliary table for daily operator metrics (productivity, attendance scores).

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `Date` | `DateTable` | `Date` | Links to the calendar |
| `Operator ID` | `Query1_Ref` | `users_id` | Links to the operator register |

---

### CC

CRM operator activity table. Aggregates contact counts per user per day.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `users_id` | `Query1_Ref` | `users_id` | Identifies the operator in the CRM |

---

### Case

Contract dimension. Also relates to `Company` to link each contract to its portfolio owner.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `client_id` | `Company` | `client_id` | Links the contract to the company / portfolio |

---

### Dim_CommissionRules

Commission rules table per company. Used to compute the commission value on each received payment.

| FK Column | Dimension | PK Column | Purpose |
|---|---|---|---|
| `client_id` | `Company` | `client_id` | Links the commission rule to the company / portfolio |

---

## 5. Modeling Rules

### 5.1 Why all relationships are 1:N

Power BI propagates filters from the dimension side (`1`) to the fact side (`N`). Many-to-many relationships would require additional bridge tables and introduce ambiguity in DAX filter contexts. The entire architecture was designed to eliminate that pattern — every fact foreign key points to exactly one dimension primary key.

---

### 5.2 DateTable with multiple roles in Cobrança

`Cobrança` connects three different date columns (`contact_date`, `payment_date`, `promise_date`) to the same `DateTable`. This creates **role-playing dimensions**:

- Only **one** relationship can be active in the model at a time
- The active relationship is `contact_date → DateTable[Date]`
- The inactive ones are queried with `USERELATIONSHIP()` inside DAX measures:

```dax
Paid Capital =
CALCULATE(
    SUM(Cobrança[payed_capital]),
    USERELATIONSHIP(Cobrança[payment_date], DateTable[Date])
)
```

---

### 5.3 client_id ≠ company_id

> ⚠️ In the operational source (`dtdi` schema), `client_id` and `company_id` are different fields.

The correct join between contracts (`Case`) and companies (`Company`) **always uses `client_id`** on both sides. Using `company_id` as the join key produces incorrect results.

```sql
-- ✅ Correct
JOIN company ON case.client_id = company.client_id

-- ❌ Incorrect
JOIN company ON case.company_id = company.company_id
```

---

### 5.4 Dialer has no case_id in the source

The source table `dtdi.dialer` does not contain `case_id`. The contract link is built at the SQL layer via a **±15-minute temporal join**:

```sql
-- Fact_contacts.sql
INNER JOIN dialer_calls d
    ON d.telecom_id = cb.telecom_id
   AND d.case_id    = cb.case_id
   AND d.call_date BETWEEN
        DATEADD(MINUTE, -15, cb.contact_date)
        AND DATEADD(MINUTE,  15, cb.contact_date)
```

A subsequent `ROW_NUMBER()` keeps only the most recent match per `contact_id`, eliminating fan-out. After this SQL-layer join, `Dialer` in Power BI can relate normally to `Case` and `Company`.

---

### 5.5 Anti-patterns avoided

| Anti-pattern | Why it is problematic |
|---|---|
| Join `Dialer → financial` on `debtor_id` | `debtor_id` is a person-level key. One person can have multiple contracts — produces M:M. |
| `DISTINCT` to deduplicate promises | Non-deterministic: results vary between executions depending on internal row order. |
| Financial metrics grouped by `debtor_id` | A debtor with multiple contracts would have payments summed incorrectly. |
| Inferring absence from missing events | On an operator's first working day, the absence of an event would be read as an absence — false positive. |
| Counting Dialer promises in Manual totals | Double attribution: the same promise would appear in two separate domains. |
| Direct join between two fact tables | Without routing through a conformed dimension, the DAX filter context becomes ambiguous. |

---

*Debt Collection Analytics Platform · Paulo Potter Marchi · SQL Server · Power Query · DAX · Power BI*
