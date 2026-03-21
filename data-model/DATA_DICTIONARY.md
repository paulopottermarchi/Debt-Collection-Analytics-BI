# Data Dictionary — Debt Collection Analytics Platform

> **Source system:** MBA/Ant DTDI (`debthor_dbs_interface`, schema `dtdi` · `reports`) — no direct table access, analytical layer built entirely on views.
>
> **Core principle:** Reliable metrics come from correct data modeling — not from dashboards.

---

## Context: Why This Dictionary Exists

The MBA/Ant system is a production debt collection platform with a complex operational model. It exposes data through DTDI views — not raw tables. This creates specific challenges:

**5 domain keys** that must never be mixed across domains:

| Domain | Key | Used for |
|---|---|---|
| Contract | `case_id` | Contacts, case attributes, operational hub |
| Financial | `ref_number` | PTPs, payments, financial aggregations |
| Dialer | `debtor_id` | Dialer calls — has NO direct `case_id` |
| Identity | `persons_id` | Natural person entity |
| Operator | `users_id` | Productivity, presence, operator dimension |

**Critical anti-pattern:** Joining the dialer domain to the financial domain via `debtor_id` creates many-to-many distortions. One debtor can have multiple contracts — `debtor_id` is not a financial key.

---

## Table of Contents

- [Source Views (MBA/Ant DTDI)](#source-views)
- [Fact Tables (Analytical Layer)](#fact-tables)
- [Dimension Tables](#dimension-tables)
- [KPI Definitions](#kpi-definitions)
- [Business Rules](#business-rules)
- [Anti-Patterns](#anti-patterns)
- [DAX Measures](#dax-measures)
- [Glossary](#glossary)

---

## Source Views (MBA/Ant DTDI)

These are the raw sources — no table access, views only.

### `dtdi.case`
The central contract entity. Everything connects through `case_id`.

| Column | Type | Description |
|---|---|---|
| `case_id` | int (unique) | Contract identifier — primary hub key |
| `client_id` | int | FK to Client (not Company — two-hop join required) |
| `debtor_id` | int | FK to Debtor — dialer domain key |
| `ref_number` | bigint | Financial reference — key for PTPs and payments |
| `case_statute_id` | tinyint | Case status (LIBS_ID 20) |
| `original_capital` | money | Original debt value |
| `actual_capital` | money | Current outstanding value |
| `department_id` | tinyint | Collection phase (LIBS_ID 66) |

### `dtdi.contact`
All CRM interactions logged by operators or automated channels.

| Column | Type | Description |
|---|---|---|
| `contact_id` | int (unique) | Primary key |
| `case_id` | int | FK to case |
| `telecom_id` | int | Phone identifier — bridge to dialer |
| `status_type_id` | int | Contact status (LIBS_ID 14) |
| `target_type_id` | int | Who was contacted (LIBS_ID 172) — CPC/RPC source |
| `contact_text` | nvarchar | Free text — channel flags extracted via LIKE |
| `insert_user` | nvarchar | Operator login — join key to `dtdi.users.user_name` |

### `dtdi.dialer`
Automated/manual dialer call log. **Has no `case_id`** — critical design constraint.

| Column | Type | Description |
|---|---|---|
| `uniqueid` | nvarchar | Unique call identifier — PK of `fact_dialer` |
| `debtor_id` | int | Debtor key — **NOT** a financial key |
| `telecom_id` | int | Bridge to contact via temporal join |
| `billsec` | int | Conversation duration in seconds — basis for all flags |
| `duration` | int | Total call duration including ringing |
| `campagn_id` | int | Campaign identifier |
| `call_date` | datetime | Call timestamp — used in ±15min join |

> **Key constraint:** `dtdi.dialer` has no `case_id`. To associate a dialer call with a case, join via `telecom_id + case_id` with a ±15-minute temporal window on `contact_date`.

### `dtdi.dialer_contact`
Bridge between dialer calls and operator identity via SIP account.

| Column | Type | Description |
|---|---|---|
| `unique_id` | varchar | FK to `dtdi.dialer.uniqueid` |
| `sip_account` | nvarchar | Operator SIP extension — join to `dtdi.users` |
| `contact_id` | int | FK to contact event |

### `reports.vw_ptp_ptpr_overview`
Promise-to-pay source view. Requires deduplication before use.

| Column | Type | Description |
|---|---|---|
| `contact_id` | int | FK to contact (join to contact events) |
| `case_id` | int | FK to case |
| `ref_number` | bigint | Financial key — use this for PTP/payment joins |
| `promise_capital` | money | Promise amount |
| `promise_date` | date | Scheduled payment date |
| `state` | int | Promise state (LIBS_ID 170) |
| `type` | varchar | `'Installment'` or other — used in dedup priority |

> **Critical:** Multiple PTPs can exist per `ref_number` in the same month. Always deduplicate with `ROW_NUMBER()` before aggregating.

---

## Fact Tables (Analytical Layer)

### `fact_contacts` (Manual)
**Grain:** One row per CRM contact interaction
**Key:** `contact_id`
**Source:** `dtdi.contact` + temporal dialer match + PTP dedup
**Window:** Rolling 60 days

| Column | Type | Description |
|---|---|---|
| `contact_id` | int | Primary key |
| `case_id` | int | FK → `dim_cases` |
| `client_id` | int | FK → `dim_company` |
| `contact_day` | date | FK → `DateTable` |
| `operator_id` | int | FK → `dim_operator` |
| `contact_channel` | varchar | Derived: WhatsApp / RCS / SMS / Email / BOT / Dialer / Manual |
| `derived_from_dialer_flag` | bit | 1 if matched to dialer via ±15min window |
| `is_cpc` | bit | `target_type_id IN (1,2)` |
| `is_rpc` | bit | `target_type_id = 1` AND productive status |
| `has_promise` | bit | 1 if PTP generated in this contact |
| `contact_hour` | int | Hour of day — enables hourly analysis |

**Channel attribution order (priority hierarchy):**

| Priority | Channel | Detection |
|---|---|---|
| 1 | WhatsApp | `contact_text LIKE '%whats%'` |
| 2 | RCS | `contact_text LIKE '%rcs%'` |
| 3 | SMS | `contact_text LIKE '%sms%'` |
| 4 | Email | `contact_text LIKE '%email%'` |
| 5 | BOT | `description LIKE '%VirtualAgent Bot%'` |
| 6 | Dialer | `campaign_id IS NOT NULL` (±15min match) |
| 7 | Manual | Default — all remaining |

---

### `fact_dialer`
**Grain:** One row per dialer call attempt
**Key:** `dialer_call_id` (= `uniqueid`)
**Source:** `dtdi.dialer` + `dtdi.dialer_contact` + `dtdi.users`
**Window:** Rolling 60 days

| Column | Type | Description |
|---|---|---|
| `dialer_call_id` | nvarchar | Primary key (uniqueid from source) |
| `case_id` | int | FK → `dim_cases` |
| `call_date` | date | FK → `DateTable` |
| `client_id` | int | FK → `dim_company` |
| `operator_id` | int | FK → `dim_operator` (via sip_account) |
| `billsec_sec` | int | Conversation duration — basis of all flags |
| `answered_flag` | bit | `billsec > 0` |
| `operator_not_connected_flag` | bit | `billsec > 3` AND `sip_account IS NULL` |
| `cpc_flag` | bit | `billsec >= 40` AND `sip_account IS NOT NULL` |

**Operator classification states:**

| State | Condition |
|---|---|
| `NO_ANSWER` | `billsec = 0` |
| `NO_OPERATOR` | `billsec > 3` AND `sip_account IS NULL` |
| `HUMAN (CPC)` | `billsec >= 40` AND `sip_account IS NOT NULL` |
| `BOT` | Fixed rules by `users_id` + `sip_account` pattern |

---

### `fact_ptp` (Cobrança)
**Grain:** One row per promise-to-pay event
**Key:** `case_id` + `contact_date` + `operator_norm`
**Source:** `reports.vw_ptp_ptpr_overview` + `vw_cases_promises_information`

| Column | Type | Description |
|---|---|---|
| `case_id` | int | FK → `dim_cases` |
| `client_id` | int | FK → `dim_company` |
| `operator_id` | int | FK → `dim_operator` |
| `contact_date` | date | FK → `DateTable` |
| `promise_date` | date | FK → `DateTable` |
| `ref_number` | bigint | Financial domain key |
| `promise_capital` | decimal | Promise amount |
| `paid` | decimal | Actual amount paid |
| `was_paid` | varchar | `'paid'` / `'not paid'` |
| `ddd` | varchar | Area code from `SUBSTRING(phone,3,2)` |
| `uf` | varchar | State mapped from DDD (27 states via CTE) |
| `dpd` | int | Days past due at contact time |
| `dpd_range` | varchar | Banded DPD (16 ranges defined in SQL) |
| `contact_time` | time | Reconstructed: `vw_cases_promises_information` → fallback `dtdi.installment` |
| `contact_datetime` | datetime | `contact_date` + `contact_time` |
| `provider` | varchar | From `case_attribute` type 303 via MAX() |

---

### `fact_ptp_enriched` (Old Vs New)
**Grain:** One row per PTP deduplicated per month
**Key:** `ref_number` per `YEAR(promise_date)` + `MONTH(promise_date)`
**Source:** `reports.vw_ptp_ptpr_overview` + `dtdi.vw_cases_payment_information`

| Column | Type | Description |
|---|---|---|
| `client_id` | int | FK → `dim_company` |
| `payment_date` | date | FK → `DateTable` |
| `ref_number` | varchar | Deduplicated financial key |
| `money_type` | varchar | `'NEW MONEY'` / `'OLD MONEY'` |
| `ptp_status` | varchar | `'PAID'` / `'OVERDUE'` / `'DUE'` |
| `payed_capital` | decimal | 0.0 if unpaid |
| `has_previous_payment` | bit | Payment on same ref in prior 30 days |
| `provider` | varchar | From `case_attribute` type 303 |

**Deduplication priority (ROW_NUMBER ORDER BY):**
1. `type = 'Installment'` first
2. Highest `promise_capital_total`
3. Most recent `contact_date`

---

### `fact_payments`
**Grain:** One row per payment transaction
**Key:** `payment_id`
**Source:** `dtdi.payment` + `dtdi.vw_cases_information`

| Column | Type | Description |
|---|---|---|
| `payment_id` | int | Primary key |
| `client_id` | int | FK → `dim_company` |
| `case_id` | int | FK → `dim_cases` |
| `payment_date` | date | FK → `DateTable` |
| `payed_capital` | money | Principal paid |
| `payed_plus_money` | money | Overpayment / interest |
| `payed_administrative_assessment` | money | Admin charges paid |
| `payed_delay_charge` | money | Penalty paid |
| `dpd_original` | varchar | DPD at case creation |
| `actual_capital` | money | Outstanding value at payment time |

---

### `fact_operator_presence` (Falta)
**Grain:** One row per operator per workday
**Key:** `user_name` + `WorkDate`
**Source:** Cartesian join `dim_operator × dim_date` LEFT JOIN `CC_operator_activity`

| Column | Type | Description |
|---|---|---|
| `users_id` | int | FK → `dim_operator` |
| `WorkDate` | date | FK → `DateTable` |
| `contact_count` | int | CC contacts on that day (null = absent) |
| `attendance_status` | varchar | `present` / `absent` / `training` / `inactive` / `not_employed` |

**Status logic:**

| Status | Condition |
|---|---|
| `not_employed` | `WorkDate < insert_date` |
| `inactive` | `WorkDate >= update_date` AND `users_status ≠ 1` |
| `training` | Within 2 days of `insert_date` — counted as present |
| `present` | `contact_count > 0` |
| `absent` | `contact_count = null OR 0` |

---

## Dimension Tables

### `dim_operator` (Query1_Ref)
**Grain:** One row per system user
**Key:** `users_id`

| Column | Type | Description |
|---|---|---|
| `users_id` | int | Primary key |
| `user_name` | varchar | Login — join key to `contact.insert_user` |
| `full_name` | varchar | Display name |
| `sip_account` | int | SIP extension — links to `dialer_contact.sip_account` |
| `is_operator` | varchar | `'Yes'` if `sip_account >= 200` |
| `is_inactive` | varchar | `'Yes'` if `users_status ≠ 1` |
| `insert_date` | date | Employment start — used in presence logic |
| `update_date` | date | Last status change — proxy for termination date |

> **Operator rule:** `sip_account >= 200` = operator. Below 200 = system/admin users excluded from presence tracking.

---

### `dim_company`
**Grain:** One row per client portfolio
**Key:** `client_id`

| Column | Type | Description |
|---|---|---|
| `client_id` | int | Primary key — used by all facts |
| `company_id` | int | Parent company identifier |
| `company_name` | varchar | Short company name |

> **Critical:** `client_id ≠ company_id`. Join path is always `fact → client_id → dim_company.client_id`. Never join directly on `company_id`. The path `case → client → company` is a two-hop join required by the source model.

---

### `dim_cases`
**Grain:** One row per case (contract)
**Key:** `case_id`

| Column | Type | Description |
|---|---|---|
| `case_id` | int | Primary key |
| `client_id` | int | FK → `dim_company` |
| `debtor_id` | int | Debtor identifier (dialer domain only) |
| `ref_number` | varchar | Financial reference key |
| `actual_capital` | decimal | Current outstanding value |
| `case_status_id` | int | Status (0=active, 1=active) |
| `provider` | varchar | `MAX(case_attribute_value)` where `case_attribute_type_id = 303` |

---

### `DateTable` (dim_date)
**Grain:** One row per calendar day
**Key:** `Date`
**Range:** 2025-01-01 to TODAY() + 365
**Built in:** DAX (not Power Query)

| Column | Type | Description |
|---|---|---|
| `Date` | date | Primary key |
| `Year / MonthNumber / Quarter` | int/varchar | Standard calendar attributes |
| `MonthYear` | varchar | Format `"yyyy-MM"` — slicer display |
| `YearMonthKey` | int | `YEAR * 100 + MONTH` — sortable |
| `WeekDayNumber` | int | 1=Monday (ISO) |
| `IsWeekend` | bool | True if Saturday or Sunday |
| `IsHoliday` | bool | `FALSE()` — hook prepared for future holiday table |
| `IsBusinessDay` | bool | Weekday AND not holiday |
| `WeekNumber` | int | ISO week number |
| `WeekOfMonth` | int | 1–5 — used for weekly pace analysis |
| `WeekOfMonthLabel` | varchar | e.g. `"Feb W1"` — dashboard label |
| `WeekOfMonthKey` | date | First day of that week-of-month — sort key |

---

## KPI Definitions

| KPI | Formula | Source | Notes |
|---|---|---|---|
| **Effectivity %** | Paid PTP / Total PTP | `fact_ptp_enriched` | `ptp_status = 'PAID'` |
| **Score Dialer** | Dialer PTP / Answered calls | `fact_dialer` + `fact_ptp` | `answered_flag = 1` |
| **Índice PTP** | PTP count / CC contacts | `fact_contacts` + `fact_ptp` | Operator productivity |
| **Score Final** | Composite operator quality | DAX | Combines Effectivity + Score Dialer |
| **Paid / RPC** | Sum(paid) / Count(RPC) | `fact_contacts` + `fact_payments` | `is_rpc = 1` |
| **Commission Value** | Paid × commission_rate | `fact_ptp_enriched` + `dim_commission_rules` | Rate per `client_id` |
| **Forecast EOM** | Cumulative paid / workdays elapsed × total workdays | DAX + `DateTable` | Weekly pace projection |
| **% Faltas** | Absent days / Total workdays | `fact_operator_presence` | Excludes inactive and not_employed |
| **% Presenças** | Present days / Total workdays | `fact_operator_presence` | Training days counted as present |
| **CPC Rate** | CPC events / Total calls | `fact_dialer` | `cpc_flag = 1` |
| **Operator Not Connected %** | No-operator calls / Answered | `fact_dialer` | Dialer quality metric |
| **Recovery %** | Sum(payed_capital) / Sum(actual_capital) | `fact_payments` + `dim_cases` | Per client / portfolio |
| **Potencial Recuperação** | Sum(actual_capital) × avg recovery rate | `dim_cases` | Executive view |
| **PTP By CC** | PTP count / CC count | `fact_contacts` | Operator efficiency ratio |
| **Paid High DPD %** | Paid DPD > 180 / Total paid | `fact_ptp` | Difficult portfolio performance |

---

## Business Rules

### Channel Attribution
Priority order prevents double-attribution:
1. WhatsApp → `contact_text LIKE '%whats%'`
2. RCS → `contact_text LIKE '%rcs%'`
3. SMS → `contact_text LIKE '%sms%'`
4. Email → `contact_text LIKE '%email%'`
5. BOT → `description LIKE '%VirtualAgent Bot%'`
6. Dialer → matched to campaign via `telecom_id` ±15min
7. Manual → all remaining

**Dialer PTPs are excluded from Manual PTP counts** to prevent double attribution.

### Dialer ↔ Contact Association
A contact is "derived from dialer" when:
- `contact.telecom_id = dialer.telecom_id`
- `contact.case_id = dialer.case_id`
- `dialer.call_date` within ±15 minutes of `contact.contact_date`
- Only the most recent matching call used (`ROW_NUMBER DESC` on `call_date`)

### PTP Deduplication (ROW_NUMBER priority)
When multiple PTPs exist for same `case_id` + `YEAR(promise_date)` + `MONTH(promise_date)`:
1. `type = 'Installment'` preferred
2. Highest `promise_capital_total`
3. Most recent `contact_date`

### NEW vs OLD Money
| Type | Rule |
|---|---|
| `OLD MONEY` | Payment on same `ref_number` exists within prior 30 days |
| `NEW MONEY` | No previous payment — genuinely recovered capital |

### Operator Presence
Present if: `contact_count > 0` OR within 2 days of `insert_date` (training)
Excluded if: `WorkDate < insert_date` OR `WorkDate >= update_date` AND `users_status ≠ 2`

### Client → Company Join
Always two-hop: `fact.client_id → dtdi.Client.client_id → dtdi.Company.company_id`.
Never join facts directly to `company_id`.

---

## Anti-Patterns

These are the modeling errors the architecture was built to prevent:

| Anti-pattern | Why it's wrong | Solution |
|---|---|---|
| Join dialer to financial via `debtor_id` | One debtor → multiple contracts → many-to-many | Temporal join via `telecom_id` ±15min |
| Use `DISTINCT` to deduplicate PTPs | Non-deterministic — loses business priority | `ROW_NUMBER()` with explicit ORDER BY |
| Financial metrics grouped by `debtor_id` | Debtor ≠ contract — distorts aggregations | Always use `ref_number` for financial domain |
| Infer absence from missing events | New hires show as absent on day 1 | Cartesian join operators × workdays |
| Count Dialer PTPs in Manual totals | Double attribution inflates conversion | Channel priority hierarchy in SQL |
| Mix `case_id` and `ref_number` in same join | Different granularities — grain mismatch | One domain key per join chain |
| Join directly to `company_id` | `client_id ≠ company_id` | Always go through `client` intermediary |

---

## DAX Measures

> **Status: pending export** — use Tabular Editor (`External Tools → Tabular Editor → Export scripts to folder`) and add `.dax` files to `dax/measures/`.

| Measure | Table | Status |
|---|---|---|
| `Effectivity %` | Cobrança | ⏳ pending export |
| `Score Dialer` | Cobrança | ⏳ pending export |
| `Score Final` | Cobrança | ⏳ pending export |
| `Índice PTP` | Cobrança | ⏳ pending export |
| `Commission Value` | Cobrança | ⏳ pending export |
| `Forecast EOM` | Cobrança | ⏳ pending export |
| `Paid / RPC` | Cobrança | ⏳ pending export |
| `% Faltas` | Falta | ⏳ pending export |
| `% Presenças` | Falta | ⏳ pending export |
| `Operator Not Connected %` | Dialer | ⏳ pending export |
| `Recovery %` | Payments | ⏳ pending export |
| `DateTable` | DateTable | ✅ [dax/Dim_date.dax](../dax/Dim_date.dax) |

---

## Glossary

| Term | Definition |
|---|---|
| **DTDI** | Ant Data Interface — MBA's analytical view layer; no direct table access |
| **case_id** | Contract-level identifier — operational hub key connecting contacts, attributes, and cases |
| **ref_number** | Financial reference linking a contract to its PTPs and payments |
| **debtor_id** | Debtor identifier used only in the dialer domain — not a financial key |
| **sip_account** | SIP extension number identifying an operator in the dialer system |
| **uniqueid** | Unique identifier for each dialer call (PK of `fact_dialer`) |
| **CPC** | Contact Per Call — meaningful reach of debtor (`target_type_id IN (1,2)`) |
| **RPC** | Right Party Contact — confirmed contact with actual debtor + productive status |
| **PTP** | Promise to Pay — commitment by debtor to pay on specific date |
| **PTPR** | PTP installment plan — multi-payment agreement |
| **DPD** | Days Past Due — days since debt became overdue |
| **provider** | Source/provider of the debt portfolio — stored as `case_attribute` type 303 |
| **NEW MONEY** | Recovered capital with no prior payment in last 30 days |
| **OLD MONEY** | Payment continuation — existing payer from previous month |
| **Effectivity** | PTP-to-payment conversion rate — primary operator performance metric |
| **WeekOfMonth** | Week position within month (1–5) — used for weekly pace analysis |
| **Forecast EOM** | End-of-month projection based on current weekly pace and remaining workdays |
| **LIBS_ID** | Lookup table identifier in `dtdi.libs_items` — maps coded values to display text |
