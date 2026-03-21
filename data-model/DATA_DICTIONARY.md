# Data Dictionary — Debt Collection Analytics Platform

> **Source system:** Production ERP/CRM (`operational_db`, schemas `ops` and `rpt`) — no direct table access, analytical layer built entirely on views.
>
> **Core principle:** Reliable metrics come from correct data modeling — not from dashboards.

---

## Why This Dictionary Exists

The source system is a production debt collection platform with a complex operational model. It exposes data through views only — no raw tables. This creates specific challenges that this dictionary exists to document and control.

### 5 Domain Keys — The Core Complexity

These keys must never be mixed across domains:

| Domain | Key | Used for | Warning |
|---|---|---|---|
| Contract | `contract_id` | Contacts, attributes, operational hub | — |
| Financial | `ref_number` | Promises, payments, financial aggregations | — |
| Dialer | `debtor_id` | Dialer calls | **Has NO direct contract_id** |
| Identity | `person_id` | Natural person entity | — |
| Operator | `user_id` | Productivity, presence, operator dimension | — |

> **Critical anti-pattern:** Joining the dialer domain to the financial domain via `debtor_id` creates many-to-many distortions. One debtor can have multiple contracts — `debtor_id` is not a financial key and must never be used as one.

---

## Table of Contents

- [Source Views](#source-views)
- [Fact Tables](#fact-tables)
- [Dimension Tables](#dimension-tables)
- [KPI Definitions](#kpi-definitions)
- [Business Rules](#business-rules)
- [Anti-Patterns](#anti-patterns)
- [DAX Measures](#dax-measures)
- [Glossary](#glossary)

---

## Source Views

These are the raw sources — views only, no direct table access.

### `ops.contract`
The central contract entity. Every domain connects through `contract_id`.

| Column | Type | Description |
|---|---|---|
| `contract_id` | int (unique) | Contract identifier — primary hub key |
| `client_id` | int | FK to Client (not Company directly — two-hop join required) |
| `debtor_id` | int | FK to Debtor — dialer domain key only |
| `ref_number` | bigint | Financial reference — key for promises and payments |
| `contract_status_id` | int | Contract status (lookup table) |
| `original_capital` | money | Original debt value |
| `actual_capital` | money | Current outstanding value |
| `department_id` | int | Collection phase (lookup table) |

---

### `ops.contact`
All CRM interactions logged by operators or automated channels.

| Column | Type | Description |
|---|---|---|
| `contact_id` | int (unique) | Primary key |
| `contract_id` | int | FK to contract |
| `phone_id` | int | Phone identifier — bridge to dialer via temporal join |
| `status_type_id` | int | Contact status (lookup table) |
| `target_type_id` | int | Who was contacted — source for CPC and RPC flags |
| `contact_text` | nvarchar | Free text — channel flags extracted via LIKE patterns |
| `insert_user` | nvarchar | Operator login — join key to `ops.users.user_name` |

---

### `ops.dialer`
Automated/manual dialer call log. **Has no `contract_id`** — this is the critical design constraint of the source system.

| Column | Type | Description |
|---|---|---|
| `unique_id` | nvarchar | Unique call identifier — PK of `fact_dialer` |
| `debtor_id` | int | Debtor key — **not** a financial or contract key |
| `phone_id` | int | Bridge to contact via ±15min temporal join |
| `billsec` | int | Conversation duration in seconds — basis for all classification flags |
| `duration` | int | Total call duration including ringing |
| `campaign_id` | int | Dialer campaign identifier |
| `call_date` | datetime | Call timestamp — used in temporal join window |

> **Key constraint:** `ops.dialer` has no `contract_id`. To associate a dialer call with a contract, join via `phone_id + contract_id` with a ±15-minute temporal window on `contact_date`.

---

### `ops.dialer_contact`
Bridge between dialer calls and operator identity via SIP account.

| Column | Type | Description |
|---|---|---|
| `unique_id` | varchar | FK to `ops.dialer.unique_id` |
| `sip_account` | nvarchar | Operator SIP extension — join key to `ops.users.sip_account` |
| `contact_id` | int | FK to contact event |

---

### `rpt.vw_promise_overview`
Promise-to-pay source view. Requires deduplication before use in any aggregation.

| Column | Type | Description |
|---|---|---|
| `contact_id` | int | FK to contact events |
| `contract_id` | int | FK to contract |
| `ref_number` | bigint | Financial key — always use this for promise/payment joins |
| `promise_capital` | money | Promise amount for this installment |
| `promise_date` | date | Scheduled payment date |
| `state` | int | Promise state (lookup table) |
| `type` | varchar | `'Installment'` or other — used in deduplication priority |

> **Critical:** Multiple promises can exist per `ref_number` in the same month (renegotiations, partial agreements). Always deduplicate with `ROW_NUMBER()` before any aggregation. Never use `DISTINCT`.

---

### `rpt.vw_payment_info`
Payment view — level 2 reporting view with enriched case context.

| Column | Type | Description |
|---|---|---|
| `contract_id` | int | FK to contract |
| `payment_id` | int | Payment identifier |
| `client_id` | int | FK to client |
| `ref_number` | bigint | Financial reference |
| `payed_capital` | money | Principal paid |
| `payment_date` | date | Date of payment |
| `actual_capital` | money | Outstanding value at payment time |
| `dpd_original` | varchar | Days past due at case creation |

---

## Fact Tables

### `fact_contacts`
**Grain:** One row per CRM contact interaction
**Key:** `contact_id`
**Source:** `ops.contact` + temporal dialer match + promise dedup
**Window:** Rolling 60 days

| Column | Type | Description |
|---|---|---|
| `contact_id` | int | Primary key |
| `contract_id` | int | FK → `dim_contract` |
| `client_id` | int | FK → `dim_company` |
| `contact_day` | date | FK → `DateTable` |
| `user_id` | int | FK → `dim_operator` |
| `contact_channel` | varchar | Derived: WhatsApp / RCS / SMS / Email / BOT / Dialer / Manual |
| `derived_from_dialer_flag` | bit | 1 if matched to dialer via ±15min temporal window |
| `is_cpc` | bit | `target_type_id IN (1,2)` |
| `is_rpc` | bit | `target_type_id = 1` AND productive status code |
| `has_promise` | bit | 1 if a promise was generated in this contact |
| `contact_hour` | int | Hour of day (0–23) — enables hourly analysis |

**Channel attribution priority:**

| Priority | Channel | Detection method |
|---|---|---|
| 1 | WhatsApp | `contact_text LIKE '%whats%'` |
| 2 | RCS | `contact_text LIKE '%rcs%'` |
| 3 | SMS | `contact_text LIKE '%sms%'` |
| 4 | Email | `contact_text LIKE '%email%'` |
| 5 | BOT | `description LIKE '%VirtualAgent%'` |
| 6 | Dialer | `campaign_id IS NOT NULL` (±15min match confirmed) |
| 7 | Manual | Default — all remaining contacts |

---

### `fact_dialer`
**Grain:** One row per dialer call attempt
**Key:** `dialer_call_id` (= `unique_id` from source)
**Source:** `ops.dialer` + `ops.dialer_contact` + `ops.users`
**Window:** Rolling 60 days

| Column | Type | Description |
|---|---|---|
| `dialer_call_id` | nvarchar | Primary key |
| `contract_id` | int | FK → `dim_contract` |
| `call_date` | date | FK → `DateTable` |
| `client_id` | int | FK → `dim_company` |
| `user_id` | int | FK → `dim_operator` (resolved via sip_account bridge) |
| `billsec_sec` | int | Conversation duration — basis of all classification flags |
| `answered_flag` | bit | `billsec > 0` |
| `operator_not_connected_flag` | bit | `billsec > 3` AND `sip_account IS NULL` |
| `cpc_flag` | bit | `billsec >= 40` AND `sip_account IS NOT NULL` |

**Operator classification states:**

| State | Condition | Meaning |
|---|---|---|
| `NO_ANSWER` | `billsec = 0` | Debtor did not pick up |
| `NO_OPERATOR` | `billsec > 3` AND `sip = null` | Debtor answered, no operator connected |
| `HUMAN (CPC)` | `billsec >= 40` AND `sip ≠ null` | Full conversation with operator |
| `BOT` | Fixed rules by user + sip pattern | Automated bot interaction |

---

### `fact_promise`
**Grain:** One row per promise-to-pay event
**Key:** `contract_id` + `contact_date` + `operator_norm`
**Source:** `rpt.vw_promise_overview` + `rpt.vw_payment_info`

| Column | Type | Description |
|---|---|---|
| `contract_id` | int | FK → `dim_contract` |
| `client_id` | int | FK → `dim_company` |
| `user_id` | int | FK → `dim_operator` |
| `contact_date` | date | FK → `DateTable` |
| `promise_date` | date | FK → `DateTable` |
| `ref_number` | bigint | Financial domain key |
| `promise_capital` | decimal | Promise amount |
| `paid` | decimal | Actual amount paid |
| `was_paid` | varchar | `'paid'` / `'not paid'` |
| `area_code` | varchar | Extracted from phone number — 2 digits |
| `region` | varchar | State/region mapped from area code (27 regions via CTE) |
| `dpd` | int | Days past due at contact time |
| `dpd_range` | varchar | Banded DPD — 16 ranges defined in SQL layer |
| `contact_time` | time | Reconstructed from promise log → fallback installment insert_date |
| `contact_datetime` | datetime | `contact_date` + `contact_time` combined |
| `provider` | varchar | From `contract_attribute` type 303 via `MAX()` aggregation |

---

### `fact_promise_enriched`
**Grain:** One row per promise deduplicated per month
**Key:** `ref_number` per `YEAR(promise_date)` + `MONTH(promise_date)`
**Source:** `rpt.vw_promise_overview` + `rpt.vw_payment_info`

| Column | Type | Description |
|---|---|---|
| `client_id` | int | FK → `dim_company` |
| `payment_date` | date | FK → `DateTable` |
| `ref_number` | varchar | Deduplicated financial key — one record per ref per month |
| `money_type` | varchar | `'NEW MONEY'` / `'OLD MONEY'` — see business rules |
| `ptp_status` | varchar | `'PAID'` / `'OVERDUE'` / `'DUE'` |
| `payed_capital` | decimal | Amount paid (0.0 if unpaid) |
| `has_previous_payment` | bit | 1 if payment on same ref in prior 30 days |
| `provider` | varchar | From contract attribute |

**Deduplication priority — `ROW_NUMBER() ORDER BY`:**
1. `type = 'Installment'` first (explicit installment plans prioritized)
2. Highest `promise_capital_total`
3. Most recent `contact_date`

---

### `fact_payments`
**Grain:** One row per payment transaction
**Key:** `payment_id`
**Source:** `ops.payment` + `rpt.vw_payment_info`

| Column | Type | Description |
|---|---|---|
| `payment_id` | int | Primary key |
| `client_id` | int | FK → `dim_company` |
| `contract_id` | int | FK → `dim_contract` |
| `payment_date` | date | FK → `DateTable` |
| `payed_capital` | money | Principal paid |
| `payed_plus_money` | money | Overpayment / interest |
| `payed_administrative_assessment` | money | Administrative charges paid |
| `payed_delay_charge` | money | Penalty charges paid |
| `dpd_original` | varchar | DPD at time of original case creation |
| `actual_capital` | money | Outstanding value at payment time |

---

### `fact_operator_presence`
**Grain:** One row per operator per workday
**Key:** `user_name` + `WorkDate`
**Source:** Cartesian join `dim_operator × dim_date` LEFT JOIN `cc_activity`

| Column | Type | Description |
|---|---|---|
| `user_id` | int | FK → `dim_operator` |
| `WorkDate` | date | FK → `DateTable` |
| `contact_count` | int | Contacts logged on that day — `null` means absent |
| `attendance_status` | varchar | `present` / `absent` / `training` / `inactive` / `not_employed` |

**Attendance status logic:**

| Status | Condition |
|---|---|
| `not_employed` | `WorkDate < start_date` |
| `inactive` | `WorkDate >= end_date` AND `user_status ≠ 1` |
| `training` | Within 2 days of `start_date` — counted as present |
| `present` | `contact_count > 0` |
| `absent` | `contact_count = null OR 0` |

> **Design note:** Absence cannot be inferred from missing events alone. A new hire on their first day would appear absent without the cartesian join + training grace logic.

---

## Dimension Tables

### `dim_operator`
**Grain:** One row per system user · **Key:** `user_id`

| Column | Type | Description |
|---|---|---|
| `user_id` | int | Primary key |
| `user_name` | varchar | Login — join key to `contact.insert_user` |
| `full_name` | varchar | Display name |
| `sip_account` | int | SIP extension — links to `dialer_contact.sip_account` |
| `is_operator` | varchar | `'Yes'` if `sip_account >= 200` |
| `is_inactive` | varchar | `'Yes'` if `user_status ≠ 1` |
| `start_date` | date | Employment start — used in presence status logic |
| `end_date` | date | Last status change — proxy for termination date |

> `sip_account >= 200` = operator. Below 200 = system/admin accounts, excluded from presence tracking.

---

### `dim_company`
**Grain:** One row per client portfolio · **Key:** `client_id`

| Column | Type | Description |
|---|---|---|
| `client_id` | int | Primary key — FK used by all facts |
| `company_id` | int | Parent company identifier |
| `company_name` | varchar | Short display name |

> **Critical:** `client_id ≠ company_id`. Always join facts via `client_id`. Never join directly on `company_id`. The path `contract → client → company` is a two-hop join enforced by the source model.

---

### `dim_contract`
**Grain:** One row per contract · **Key:** `contract_id`

| Column | Type | Description |
|---|---|---|
| `contract_id` | int | Primary key |
| `client_id` | int | FK → `dim_company` |
| `debtor_id` | int | Debtor identifier — dialer domain only |
| `ref_number` | varchar | Financial reference key |
| `actual_capital` | decimal | Current outstanding value |
| `contract_status_id` | int | Status code |
| `provider` | varchar | `MAX(attribute_value)` where `attribute_type_id = 303` |

---

### `DateTable`
**Grain:** One row per calendar day · **Key:** `Date`
**Range:** 2025-01-01 to TODAY() + 365 · **Built in:** DAX

| Column | Type | Description |
|---|---|---|
| `Date` | date | Primary key |
| `Year` / `MonthNumber` / `Quarter` | int/varchar | Standard calendar attributes |
| `MonthYear` | varchar | Format `"yyyy-MM"` — slicer display |
| `YearMonthKey` | int | `YEAR * 100 + MONTH` — sortable integer key |
| `WeekDayNumber` | int | 1=Monday, 7=Sunday (ISO standard) |
| `IsWeekend` | bool | True if Saturday or Sunday |
| `IsHoliday` | bool | `FALSE()` — hook prepared for future holiday table |
| `IsBusinessDay` | bool | Weekday AND not holiday |
| `WeekNumber` | int | ISO week number |
| `WeekOfMonth` | int | 1–5 — position within month for pace analysis |
| `WeekOfMonthLabel` | varchar | e.g. `"Feb W1"` — used in commission dashboard |
| `WeekOfMonthKey` | date | First day of that week-of-month — sort key |

---

### `dim_commission_rules`
**Grain:** One row per client commission rule · **Key:** `client_id`

| Column | Type | Description |
|---|---|---|
| `client_id` | int | FK → `dim_company` |
| `commission_rate` | decimal | Commission percentage applied to paid amount |

---

## KPI Definitions

| KPI | Formula | Source | Notes |
|---|---|---|---|
| **Effectivity %** | Paid PTP / Total PTP | `fact_promise_enriched` | `ptp_status = 'PAID'` |
| **Dialer Score** | Dialer PTP / Answered calls | `fact_dialer` + `fact_promise` | `answered_flag = 1` |
| **Promise Index** | PTP count / CC contacts | `fact_contacts` + `fact_promise` | Operator productivity ratio |
| **Quality Score** | Composite operator metric | DAX | Combines Effectivity + Dialer Score |
| **Paid / RPC** | Sum(paid) / Count(RPC) | `fact_contacts` + `fact_payments` | `is_rpc = 1` |
| **Commission Value** | Paid × commission_rate | `fact_promise_enriched` + `dim_commission_rules` | Rate varies per `client_id` |
| **Forecast EOM** | Cumulative paid / workdays elapsed × total workdays | DAX + `DateTable` | Weekly pace projection |
| **Absence %** | Absent days / Total workdays | `fact_operator_presence` | Excludes inactive and not_employed |
| **Presence %** | Present days / Total workdays | `fact_operator_presence` | Training days counted as present |
| **CPC Rate** | CPC events / Total calls | `fact_dialer` | `cpc_flag = 1` |
| **Operator Not Connected %** | No-operator calls / Answered calls | `fact_dialer` | Dialer quality metric |
| **Recovery %** | Sum(payed_capital) / Sum(actual_capital) | `fact_payments` + `dim_contract` | Per client or portfolio |
| **Recovery Potential** | Sum(actual_capital) × avg recovery rate | `dim_contract` | Executive view estimate |
| **Promise By CC** | PTP count / CC contact count | `fact_contacts` | Efficiency ratio per operator |
| **High DPD Paid %** | Paid with DPD > 180 / Total paid | `fact_promise` | Difficult portfolio performance |

---

## Business Rules

### Channel Attribution
Contacts are attributed to exactly one channel using the following priority order. The first match wins.

1. WhatsApp — `contact_text LIKE '%whats%'`
2. RCS — `contact_text LIKE '%rcs%'`
3. SMS — `contact_text LIKE '%sms%'`
4. Email — `contact_text LIKE '%email%'`
5. BOT — `description LIKE '%VirtualAgent%'`
6. Dialer — `campaign_id IS NOT NULL` (confirmed via ±15min temporal match)
7. Manual — all remaining contacts

**Dialer promises are excluded from Manual PTP counts** to prevent double attribution across channels.

---

### Dialer → Contact Association
A contact is flagged as `derived_from_dialer = 1` when all conditions are met:
- `contact.phone_id = dialer.phone_id`
- `contact.contract_id = dialer.contract_id`
- `dialer.call_date` is within ±15 minutes of `contact.contact_date`
- Only the most recent matching dialer call is used (`ROW_NUMBER DESC` on `call_date`)

---

### Promise Deduplication
When multiple promises exist for the same `contract_id` in the same calendar month, the canonical record is selected by `ROW_NUMBER()` with this priority:

1. `type = 'Installment'` preferred over other promise types
2. Highest `promise_capital_total`
3. Most recent `contact_date`

> Using `DISTINCT` instead would produce non-deterministic results and lose business priority logic.

---

### NEW vs OLD Money
Payments are classified to identify genuinely new recovered capital vs continuation of existing agreements.

| Classification | Rule |
|---|---|
| `OLD MONEY` | A payment on the same `ref_number` exists within the prior 30 days |
| `NEW MONEY` | No previous payment found — represents newly recovered capital |

---

### Operator Presence
An operator is marked **present** on a given workday if:
- `contact_count > 0` on that day, **OR**
- The day falls within 2 days of `start_date` (training tolerance)

An operator is **excluded** from all presence calculations if:
- `WorkDate < start_date` → not yet employed
- `WorkDate >= end_date` AND `user_status ≠ 1` → terminated

---

### Client → Company Join
Always two-hop: `fact.client_id → Client.client_id → Company.company_id`.
Never join facts directly to `company_id` — they are not the same key.

---

## Anti-Patterns

Modeling errors this architecture was built to prevent:

| Anti-pattern | Why it is wrong | Correct approach |
|---|---|---|
| Join dialer to financial via `debtor_id` | One debtor → multiple contracts → many-to-many distortion | Temporal join via `phone_id` ±15min |
| Use `DISTINCT` to deduplicate promises | Non-deterministic — loses business priority | `ROW_NUMBER()` with explicit `ORDER BY` |
| Financial metrics grouped by `debtor_id` | Debtor ≠ contract — inflates aggregations | Always use `ref_number` for financial domain |
| Infer absence from missing contact events | New hires appear absent on their first day | Cartesian join operators × workdays |
| Count Dialer PTP in Manual PTP totals | Double attribution inflates conversion metrics | Channel priority hierarchy enforced in SQL |
| Mix `contract_id` and `ref_number` in same join chain | Different granularities — grain mismatch | One domain key per join chain |
| Join directly to `company_id` from facts | `client_id ≠ company_id` — wrong entity | Always go through `Client` intermediary |

---

## DAX Measures

> **Status: pending export** — use Tabular Editor (`External Tools → Tabular Editor → Export scripts to folder`) and add `.dax` files to `dax/measures/`.

| Measure | Table | Status |
|---|---|---|
| `Effectivity %` | Fact_Promise | ⏳ pending export |
| `Dialer Score` | Fact_Promise | ⏳ pending export |
| `Quality Score` | Fact_Promise | ⏳ pending export |
| `Promise Index` | Fact_Promise | ⏳ pending export |
| `Commission Value` | Fact_Promise | ⏳ pending export |
| `Forecast EOM` | Fact_Promise | ⏳ pending export |
| `Paid / RPC` | Fact_Promise | ⏳ pending export |
| `Absence %` | Fact_Presence | ⏳ pending export |
| `Presence %` | Fact_Presence | ⏳ pending export |
| `Operator Not Connected %` | Fact_Dialer | ⏳ pending export |
| `Recovery %` | Fact_Payments | ⏳ pending export |
| `DateTable` | DateTable | ✅ [dax/Dim_date.dax](../dax/Dim_date.dax) |

---

## Glossary

| Term | Definition |
|---|---|
| **contract_id** | Contract-level identifier — operational hub key connecting contacts, attributes and financial data |
| **ref_number** | Financial reference linking a contract to its promises and payments |
| **debtor_id** | Debtor identifier used only in the dialer domain — not a financial key |
| **sip_account** | SIP extension number identifying an operator in the dialer system |
| **unique_id** | Unique identifier for each dialer call attempt — primary key of `fact_dialer` |
| **CPC** | Contact Per Call — meaningful reach of debtor (`target_type_id IN (1,2)`) |
| **RPC** | Right Party Contact — confirmed contact with actual debtor + productive status code |
| **PTP** | Promise to Pay — commitment by debtor to pay on a specific date |
| **DPD** | Days Past Due — number of days the debt has been overdue |
| **provider** | Source or provider of the debt portfolio — stored as contract attribute |
| **NEW MONEY** | Recovered capital with no prior payment in the last 30 days |
| **OLD MONEY** | Payment continuation — debtor was already paying in the previous month |
| **Effectivity** | PTP-to-payment conversion rate — primary operator performance metric |
| **WeekOfMonth** | Week position within the current month (1–5) — used for weekly pace analysis |
| **Forecast EOM** | End-of-month projection based on current weekly pace and remaining workdays |
| **Grain** | The level of detail represented by one row in a fact table — must be explicitly defined |
| **Conformed dimension** | A dimension shared across multiple fact tables with consistent keys and definitions |
