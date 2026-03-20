# Data Dictionary — Debt Collection Analytics Platform

> **Status:** Fact tables, dimensions, and KPI definitions complete. DAX measures to be added after Tabular Editor export.

---

## Table of Contents

- [Fact Tables](#fact-tables)
- [Dimension Tables](#dimension-tables)
- [KPI Definitions](#kpi-definitions)
- [DAX Measures](#dax-measures)
- [Business Rules](#business-rules)
- [Glossary](#glossary)

---

## Fact Tables

### `fact_dialer`
**Grain:** One row per dialer call attempt  
**Key:** `dialer_call_id` (`uniqueid`)  
**Source:** `dtdi.dialer` + `dtdi.dialer_contact`  
**Window:** Rolling 60 days

| Column | Type | Description |
|---|---|---|
| `dialer_call_id` | varchar | Unique call identifier (uniqueid) — primary key |
| `queue_item_id` | int | Queue item reference |
| `campaign_id` | int | Dialer campaign identifier |
| `campaign_name` | varchar | Campaign name |
| `case_id` | int | FK → `dim_cases` |
| `debtor_id` | int | Debtor identifier (dialer domain key) |
| `telecom_id` | int | Telecom identifier — used for contact join |
| `client_id` | int | FK → `dim_company` |
| `phone_number` | varchar | Dialed phone number |
| `call_datetime` | datetime | Exact call timestamp |
| `call_date` | date | FK → `dim_date` |
| `duration_sec` | int | Total call duration in seconds |
| `billsec_sec` | int | Billable seconds (debtor answered) |
| `disposition` | varchar | Call disposition (ANSWER, NO ANSWER, BUSY, etc.) |
| `hangup_cause` | varchar | Technical hangup reason |
| `contact_id` | int | FK to contact event (via dialer_contact) |
| `dialer_sip_account` | varchar | SIP account of connected operator |
| `operator_id` | int | FK → `dim_operator` |
| `operator_name` | varchar | Operator username |
| `answered_flag` | bit | 1 if `billsec > 0` (technical answer) |
| `operator_not_connected_flag` | bit | 1 if `billsec > 3` AND `sip_account IS NULL` |
| `cpc_flag` | bit | 1 if `billsec >= 40` AND `sip_account IS NOT NULL` |

**Classification states:**

| State | Condition |
|---|---|
| `NO_ANSWER` | `billsec = 0` |
| `NO_OPERATOR` | `billsec > 3` AND `sip_account IS NULL` |
| `HUMAN` | `billsec >= 40` AND `sip_account IS NOT NULL` |
| `BOT` | Fixed rules by `users_id` + `sip_account` |

---

### `fact_contacts`
**Grain:** One row per CRM contact interaction  
**Key:** `contact_id`  
**Source:** `dtdi.contact`  
**Window:** Rolling 60 days

| Column | Type | Description |
|---|---|---|
| `contact_id` | int | Primary key |
| `dialer_contact_id` | int | Linked dialer call (if derived from dialer) |
| `case_id` | int | FK → `dim_cases` |
| `client_id` | int | FK → `dim_company` |
| `telecom_id` | int | Telecom identifier |
| `contact_datetime` | datetime | Exact contact timestamp |
| `contact_date` | date | FK → `dim_date` |
| `contact_hour` | int | Hour of day (0–23) for hourly analysis |
| `operator_id` | int | FK → `dim_operator` |
| `operator_name` | varchar | Full operator name |
| `operator_login` | varchar | Normalized login (lowercased) |
| `status_type_id` | int | CRM status code |
| `status_label` | varchar | Human-readable status description |
| `target_type_id` | int | Contact target classification |
| `campaign_id` | int | Campaign (if derived from dialer) |
| `campaign_name` | varchar | Campaign name |
| `contact_channel` | varchar | WhatsApp / RCS / SMS / Email / BOT / Dialer / Manual |
| `derived_from_dialer_flag` | bit | 1 if matched to a dialer call via ±15min window |
| `has_promise` | bit | 1 if a PTP was generated in this contact |
| `promise_capital` | decimal | PTP value at contact level |
| `promise_date` | date | Promise payment date |
| `flag_bot` | bit | 1 if VirtualAgent Bot detected in contact_text |
| `flag_whatsapp` | bit | 1 if WhatsApp detected |
| `flag_rcs` | bit | 1 if RCS detected |
| `flag_sms` | bit | 1 if SMS detected |
| `flag_email` | bit | 1 if email detected |
| `is_cpc` | bit | 1 if `target_type_id IN (1,2)` |
| `is_rpc` | bit | 1 if `target_type_id = 1` AND productive status |

**Channel priority (attribution order):**
WhatsApp → RCS → SMS → Email → BOT → Dialer → Manual

---

### `fact_ptp`
**Grain:** One row per promise-to-pay event  
**Key:** `case_id` + `contact_date` + `operator_norm`  
**Source:** `reports.vw_ptp_ptpr_overview`

| Column | Type | Description |
|---|---|---|
| `case_id` | int | FK → `dim_cases` |
| `client_id` | int | FK → `dim_company` |
| `operator_id` | int | FK → `dim_operator` |
| `operator_name` | varchar | Operator full name |
| `provider` | varchar | Provider from `case_attribute` type 303 |
| `contact_date` | date | FK → `dim_date` (contact date) |
| `promise_date` | date | Scheduled payment date |
| `payment_date` | date | Actual payment date (if paid) |
| `contact_time` | time | Reconstructed from `vw_cases_promises_information` or `dtdi.installment` fallback |
| `contact_datetime` | datetime | Full datetime combining contact_date + contact_time |
| `promise_capital` | decimal | Promise amount for this installment |
| `paid` | decimal | Amount actually paid |
| `was_paid` | varchar | `'paid'` / `'not paid'` |
| `ddd` | varchar | Area code extracted from phone_number[3:4] |
| `uf` | varchar | Brazilian state mapped from DDD (27 states) |
| `dpd` | int | Days past due at contact time |
| `dpd_range` | varchar | DPD band (e.g. `'DPD 31-60'`) |
| `contact_attribute` | varchar | Contact channel attribute (default: `'Outgoing Call'`) |
| `payment_number` | int | Installment number within the agreement |
| `type` | varchar | Promise type (`Installment` / other) |

**DPD Bands:**

| Band | Range |
|---|---|
| DPD 0-15 | 0 to 15 days |
| DPD 16-30 | 16 to 30 days |
| DPD 31-60 | 31 to 60 days |
| DPD 61-90 | 61 to 90 days |
| DPD 91-120 | 91 to 120 days |
| DPD 121-180 | 121 to 180 days |
| DPD 181-360 | 181 to 360 days |
| DPD 360+ | 361+ days |

---

### `fact_ptp_enriched`
**Grain:** One row per PTP per month (deduplicated)  
**Key:** `ref_number` per `YEAR(promise_date)` + `MONTH(promise_date)`  
**Source:** `reports.vw_ptp_ptpr_overview` + `dtdi.vw_cases_payment_information`

| Column | Type | Description |
|---|---|---|
| `case_id` | int | FK → `dim_cases` |
| `client_id` | int | FK → `dim_company` |
| `company_name` | varchar | Denormalized company name |
| `ref_number` | varchar | Financial key linking PTP to payments |
| `client_ref_number` | varchar | Client-side reference number |
| `operator` | varchar | Operator name |
| `promise_date` | date | FK → `dim_date` |
| `promise_capital_total` | decimal | Total promise value |
| `promise_capital` | decimal | Installment value |
| `number_of_installments` | int | Total installments in agreement |
| `payment_number` | int | Current installment number |
| `provider` | varchar | Provider from `case_attribute` type 303 |
| `payment_id` | int | FK → `fact_payments` (null if unpaid) |
| `payment_date` | date | Actual payment date |
| `payed_capital` | decimal | Amount paid (0.0 if unpaid) |
| `has_previous_payment` | bit | 1 if payment exists on same ref in prior 30 days |
| `money_type` | varchar | `'NEW MONEY'` / `'OLD MONEY'` |
| `ptp_status` | varchar | `'PAID'` / `'OVERDUE'` / `'DUE'` |

**Deduplication rule (ROW_NUMBER priority):**
1. `type = 'Installment'` first
2. Highest `promise_capital_total`
3. Most recent `contact_date`

**Money classification:**

| Type | Condition |
|---|---|
| `NEW MONEY` | No previous payment on `ref_number` in last 30 days |
| `OLD MONEY` | Previous payment found on `ref_number` in last 30 days |

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
| `payment_date` | date | FK → `dim_date` |
| `payed_capital` | decimal | Principal amount paid |
| `payed_plus_money` | decimal | Interest/fees paid |
| `payed_administrative_assessment` | decimal | Administrative charges paid |
| `payed_delay_charge` | decimal | Delay penalty paid |
| `dpd_original` | int | DPD at time of original case creation |
| `original_capital` | decimal | Original debt value |
| `actual_capital` | decimal | Current outstanding value |
| `case_statute_id` | int | Case status at payment time |

---

### `fact_operator_presence`
**Grain:** One row per operator per workday  
**Key:** `user_name` + `WorkDate`  
**Source:** Cartesian join `dim_operator × dim_date` LEFT JOIN `CC_operator_activity`

| Column | Type | Description |
|---|---|---|
| `users_id` | int | FK → `dim_operator` |
| `user_name` | varchar | Operator login |
| `full_name` | varchar | Operator full name |
| `insert_date` | date | Employment start date |
| `update_date` | date | Last status update (used for termination detection) |
| `sip_account` | int | SIP extension number |
| `WorkDate` | date | FK → `dim_date` |
| `contact_count` | int | Number of contacts logged on WorkDate (null = absent) |
| `attendance_status` | varchar | `'present'` / `'absent'` / `'training'` / `'inactive'` / `'not_employed'` |

**Status logic:**

| Status | Condition |
|---|---|
| `not_employed` | `WorkDate < insert_date` |
| `inactive` | `WorkDate >= update_date` AND `user_status ≠ 1` |
| `training` | Within 2 days of `insert_date` (counted as present) |
| `present` | `contact_count > 0` |
| `absent` | `contact_count = null OR = 0` |

---

## Dimension Tables

### `dim_cases`
**Grain:** One row per case (contract)  
**Key:** `case_id`

| Column | Type | Description |
|---|---|---|
| `case_id` | int | Primary key |
| `client_id` | int | FK → `dim_company` |
| `debtor_id` | int | Debtor identifier |
| `ref_number` | varchar | Financial reference key |
| `client_ref_number` | varchar | Client-side reference |
| `case_status_id` | int | Current case status (0=active, 1=active) |
| `original_capital` | decimal | Original debt value |
| `actual_capital` | decimal | Current outstanding value |
| `department_id` | int | Department assignment |
| `currency_id` | int | Currency |
| `insert_date` | date | Case creation date |
| `update_date` | date | Last update date |
| `provider` | varchar | Provider from `case_attribute` type 303 |

---

### `dim_operator` (Query1_Ref)
**Grain:** One row per system user  
**Key:** `users_id`

| Column | Type | Description |
|---|---|---|
| `users_id` | int | Primary key |
| `user_name` | varchar | Login name (used for joins with contact.insert_user) |
| `full_name` | varchar | Full display name |
| `users_status` | int | 1 = active, 2 = inactive |
| `is_inactive` | varchar | `'Yes'` / `'No'` |
| `is_operator` | varchar | `'Yes'` if `sip_account >= 200`, else `'No'` |
| `sip_account` | int | SIP extension — links to `dtdi.dialer_contact` |
| `insert_date` | date | User creation date (employment start) |
| `update_date` | date | Last status change date |

**Operator rule:** `sip_account >= 200` = operator. Accounts below 200 are system/admin users.

---

### `dim_company`
**Grain:** One row per client portfolio  
**Key:** `client_id`

| Column | Type | Description |
|---|---|---|
| `company_id` | int | Company identifier |
| `company_name` | varchar | Short company name |
| `client_id` | int | Primary key (FK used by all facts) |

> **Important:** `client_id ≠ company_id`. The join path is always `fact → client_id → dim_company.client_id`. Never join directly on `company_id`.

---

### `dim_date` (DateTable)
**Grain:** One row per calendar day  
**Key:** `Date`  
**Range:** 2025-01-01 to TODAY() + 365

| Column | Type | Description |
|---|---|---|
| `Date` | date | Primary key |
| `Year` | int | Calendar year |
| `MonthNumber` | int | Month number (1–12) |
| `MonthName` | varchar | Full month name (e.g. "February") |
| `MonthShort` | varchar | Abbreviated month (e.g. "Feb") |
| `MonthYear` | varchar | Format `"yyyy-MM"` |
| `YearMonthKey` | int | Sortable key: `YEAR * 100 + MONTH` |
| `Quarter` | varchar | e.g. `"Q1"` |
| `WeekDayNumber` | int | 1=Monday, 7=Sunday (ISO) |
| `WeekDayName` | varchar | Full weekday name |
| `IsWeekend` | bool | True if Saturday or Sunday |
| `IsHoliday` | bool | Currently `FALSE()` — hook prepared for future holiday table |
| `IsBusinessDay` | bool | True if weekday AND not holiday |
| `WeekNumber` | int | ISO week number |
| `WeekYear` | int | ISO week year |
| `WeekYearKey` | int | `WeekYear * 100 + WeekNumber` |
| `WeekLabel` | varchar | e.g. `"W05 Feb"` |
| `WeekOfMonth` | int | 1–5 (week position within month) |
| `WeekOfMonthLabel` | varchar | e.g. `"Feb W1"` |
| `WeekOfMonthKey` | date | First day of that week-of-month |

---

### `dim_commission_rules`
**Grain:** One row per client commission rule  
**Key:** `client_id`

| Column | Type | Description |
|---|---|---|
| `client_id` | int | FK → `dim_company` |
| `commission_rate` | decimal | Commission percentage applied to paid amount |

---

## KPI Definitions

| KPI | Formula | Fact Source | Notes |
|---|---|---|---|
| **Effectivity %** | `Paid PTP / Total PTP` | `fact_ptp_enriched` | Paid = `ptp_status = 'PAID'` |
| **Score Dialer** | `Dialer PTP / Answered calls` | `fact_dialer` + `fact_ptp` | Answered = `answered_flag = 1` |
| **Índice PTP** | `PTP count / CC contacts` | `fact_contacts` + `fact_ptp` | CC = contacts with `contact_count > 0` |
| **Score Final** | Composite operator quality score | DAX | Combines Effectivity + Score Dialer |
| **Paid / RPC** | `Sum(paid) / Count(RPC)` | `fact_contacts` + `fact_payments` | RPC = `is_rpc = 1` |
| **Commission Value** | `Paid × commission_rate` | `fact_ptp_enriched` + `dim_commission_rules` | Rate varies per `client_id` |
| **Forecast EOM** | `Cumulative paid / workdays elapsed × total workdays` | DAX + `dim_date` | Based on weekly pace |
| **% Faltas** | `Absent days / Total workdays` | `fact_operator_presence` | Excludes inactive and not_employed |
| **% Presenças** | `Present days / Total workdays` | `fact_operator_presence` | Includes training days as present |
| **CPC Rate** | `CPC events / Total call attempts` | `fact_dialer` | CPC = `cpc_flag = 1` |
| **Operator Not Connected %** | `operator_not_connected / answered` | `fact_dialer` | Measures dialer quality |
| **Recovery %** | `Sum(payed_capital) / Sum(actual_capital)` | `fact_payments` + `dim_cases` | Per client / portfolio |
| **Potencial Recuperação** | `Sum(actual_capital) × avg recovery rate` | `dim_cases` | Executive view |
| **PTP By CC** | `PTP count / CC contact count` | `fact_contacts` | Operator productivity ratio |
| **Paid High DPD %** | `Paid with DPD > 180 / Total paid` | `fact_ptp` | Measures difficult portfolio performance |

---

## DAX Measures

> **Status: To be completed** — export from Tabular Editor (`External Tools → Tabular Editor → Export scripts to folder`) and add files to `dax/measures/`.

### Measures to document

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
| `PTP By CC` | Cobrança | ⏳ pending export |
| `Operator Not Connected %` | Dialer | ⏳ pending export |
| `Recovery %` | Payments | ⏳ pending export |
| `DateTable` | DateTable | ✅ [DateTable.dax](../dax/DateTable.dax) |

---

## Business Rules

### Channel Attribution
Contacts are attributed to a single channel using this priority order:
1. WhatsApp (`contact_text LIKE '%whats%'`)
2. RCS (`contact_text LIKE '%rcs%'`)
3. SMS (`contact_text LIKE '%sms%'`)
4. Email (`contact_text LIKE '%email%'`)
5. BOT (`description LIKE '%VirtualAgent Bot%'`)
6. Dialer (matched to a campaign via `telecom_id` ±15min window)
7. Manual (default — all remaining contacts)

### Dialer ↔ Contact Association
A contact is considered "derived from dialer" when:
- `contact.telecom_id = dialer.telecom_id`
- `contact.case_id = dialer.case_id`
- `dialer.call_date` within ±15 minutes of `contact.contact_date`

Only the most recent matching dialer call is used (`ROW_NUMBER DESC` on `call_date`).

### Operator Classification
- **Is operator:** `sip_account >= 200`
- **Is inactive:** `users_status ≠ 1`
- **Terminate detection:** `update_date` used as termination date proxy when `users_status = 2`

### NEW vs OLD Money
| Type | Rule |
|---|---|
| OLD MONEY | A payment on the same `ref_number` exists within the previous 30 days |
| NEW MONEY | No previous payment found — represents newly recovered capital |

### PTP Deduplication
When multiple PTPs exist for the same `case_id` in the same month, the canonical record is selected by:
1. `type = 'Installment'` preferred over other types
2. Highest `promise_capital_total`
3. Most recent `contact_date`

### Operator Presence
An operator is marked **present** on a given workday if:
- `contact_count > 0` on that day, OR
- The day falls within 2 days of their `insert_date` (training tolerance)

An operator is **excluded** from presence calculations if:
- `WorkDate < insert_date` (not yet employed)
- `WorkDate >= update_date` AND `users_status ≠ 1` (terminated)

---

## Glossary

| Term | Definition |
|---|---|
| **CPC** | Contact Per Call — a call where the debtor was meaningfully reached (`target_type_id IN (1,2)`) |
| **RPC** | Right Party Contact — confirmed contact with the actual debtor (`target_type_id = 1` + productive status) |
| **PTP** | Promise to Pay — a commitment made by the debtor to pay on a specific date |
| **DPD** | Days Past Due — number of days the debt has been overdue |
| **ref_number** | Financial reference key linking a case to its PTPs and payments |
| **case_id** | Contract-level identifier — hub key connecting contacts, dialer, and case attributes |
| **debtor_id** | Debtor identifier used in the dialer domain (no direct `case_id` in dialer) |
| **sip_account** | SIP extension number identifying an operator in the dialer system |
| **uniqueid** | Unique identifier for each dialer call attempt (primary key of `fact_dialer`) |
| **provider** | Source/provider of the debt portfolio, stored as `case_attribute` type 303 |
| **NEW MONEY** | Recovered capital with no prior payment in the last 30 days |
| **OLD MONEY** | Payment continuation — debtor was already paying in the previous month |
| **Effectivity** | PTP-to-payment conversion rate — primary operator performance metric |
| **Score Dialer** | Ratio of PTPs generated through dialer calls vs answered calls |
| **WeekOfMonth** | Week position within the current month (1–5), used for weekly pace analysis |
| **Forecast EOM** | End-of-month projection based on current weekly pace and remaining workdays |
