# Databricks notebook source
# MAGIC %md
# MAGIC # 01 · Bronze Layer — Raw Ingestion
# MAGIC
# MAGIC **Pipeline:** Debt Collection Analytics · MBA Brasil
# MAGIC **Layer:** Bronze (raw, unmodified data)
# MAGIC
# MAGIC Simulates the exact views from `debthor_dbs_interface.dtdi` used in production:
# MAGIC
# MAGIC | Source Table / View | Used in |
# MAGIC |---------------------|---------|
# MAGIC | `dialer_calls` | `Fact_dialer` base |
# MAGIC | `dialer_contact` | dialer operator enrichment |
# MAGIC | `contact_events` | `Fact_contacts` base |
# MAGIC | `ptp_overview` | `Fact_ptp` + `Fact_ptp_enriched` + `Fact_contacts` |
# MAGIC | `payments` | `Fact_payments` + `Fact_ptp_enriched` |
# MAGIC | `cases` | `Dim_cases` + enrichment |
# MAGIC | `case_attributes` (type=303) | provider attribute |
# MAGIC | `users` | operator join in all facts |
# MAGIC | `client` + `company` | `Dim_client` / `Dim_company` |
# MAGIC | `installment` | contact_time fallback in `Fact_ptp` |

# COMMAND ----------

%pip install faker --quiet

# COMMAND ----------

from pyspark.sql.functions import current_timestamp, lit
from faker import Faker
import pandas as pd
import numpy as np
import random
from datetime import datetime, timedelta

fake = Faker('pt_BR')
random.seed(42)
np.random.seed(42)

BRONZE_PATH = "/mnt/debt_collection/bronze"

# Reference pools — matching real system constraints
CLIENTS      = [2, 3, 5, 8, 10]           # excludes client_id=1 and 999 (Dim_company filter)
COMPANIES    = {2:"CredX", 3:"FinTrust", 5:"RecovCo", 8:"DebtSolve", 10:"AlphaFin"}
SIP_ACCOUNTS = list(range(200, 220))       # sip_account >= 200 = operator (Fact_dialer logic)
DDD_LIST     = ["11","12","13","21","22","31","41","47","51","61","71","81","85","91"]
DISPOSITIONS = ["ANSWERED","NO ANSWER","BUSY","FAILED"]
PTP_TYPES    = ["Installment","Installment","Single","Installment","Single"]  # weighted
PTP_STATES   = ["Active","Expired","Canceled","Fulfilled"]
PROVIDERS    = ["ProviderAlpha","ProviderBeta","ProviderGamma","ProviderDelta"]
STATUS_TYPES = [2, 8, 48, 118, 119, 120, 300, 15, 20]
TARGET_TYPES = [1, 2, 3, 4, 5]

START = datetime(2024, 1, 1)
END   = datetime(2025, 4, 10)
N_CASES    = 2000
N_DIALER   = 15000
N_PTP      = 6000
N_CONTACTS = 8000

def rand_dt(s=START, e=END):
    return s + timedelta(seconds=random.randint(0, int((e - s).total_seconds())))

def rand_phone():
    return "55" + random.choice(DDD_LIST) + str(random.randint(900000000, 999999999))

print(f"✅ Config ready | Period: {START.date()} → {END.date()}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. `company` + `client`

# COMMAND ----------

df_company = spark.createDataFrame(pd.DataFrame([
    {"company_id": cid, "company_name": cname} for cid, cname in COMPANIES.items()
])).withColumn("_ingested_at", current_timestamp()).withColumn("_source", lit("dtdi.company"))
df_company.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/company")

df_client = spark.createDataFrame(pd.DataFrame([
    {"client_id": cid, "company_id": cid} for cid in CLIENTS
])).withColumn("_ingested_at", current_timestamp()).withColumn("_source", lit("dtdi.client"))
df_client.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/client")

print(f"✅ company → {df_company.count()} rows")
print(f"✅ client  → {df_client.count()} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. `users` — operators
# MAGIC
# MAGIC Joined in `Fact_dialer` via `u.sip_account = dc.sip_account`
# MAGIC and in `Fact_contacts` via `u.user_name = cb.operator_login`.

# COMMAND ----------

users_rows = []
for i, sip in enumerate(SIP_ACCOUNTS):
    name = fake.name()
    users_rows.append({
        "user_id":     1000 + i,
        "sip_account": sip,
        "user_name":   name.lower().replace(" ", "."),
        "full_name":   name,
        "insert_date": rand_dt(START, START + timedelta(days=30)),
    })

df_users = spark.createDataFrame(pd.DataFrame(users_rows)) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.users"))
df_users.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/users")
print(f"✅ users → {df_users.count()} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. `cases` + `case_attributes`
# MAGIC
# MAGIC `Dim_cases` filter: `case_status_id IN (0,1) OR update_date >= last 60 days`
# MAGIC `case_attributes` with `attribute_type = 303` = Provider (used in Fact_ptp, Fact_ptp_enriched, Dim_cases)

# COMMAND ----------

cases_rows = []
for i in range(N_CASES):
    ins = rand_dt(START, END - timedelta(days=10))
    cases_rows.append({
        "case_id":           10000 + i,
        "client_id":         random.choice(CLIENTS),
        "debtor_id":         50000 + i,
        "ref_number":        f"REF{10000+i:07d}",
        "client_ref_number": f"CREF{10000+i:07d}",
        "case_status_id":    random.choice([0, 1, 1, 2]),
        "original_capital":  round(random.uniform(1000, 100000), 2),
        "actual_capital":    round(random.uniform(800, 90000), 2),
        "department_id":     random.randint(1, 5),
        "currency_id":       1,
        "insert_date":       ins,
        "update_date":       ins + timedelta(days=random.randint(0, 90)),
        "dpd_original":      random.randint(1, 720),
    })

cases_pd = pd.DataFrame(cases_rows)
df_cases = spark.createDataFrame(cases_pd) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.cases"))
df_cases.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/cases")

attr_rows = [
    {"case_id": int(r["case_id"]), "attribute_type": 303,
     "attribute_value": random.choice(PROVIDERS), "update_date": r["update_date"]}
    for _, r in cases_pd.iterrows()
]
df_case_attr = spark.createDataFrame(pd.DataFrame(attr_rows)) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.case_attributes"))
df_case_attr.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/case_attributes")

print(f"✅ cases           → {df_cases.count():,} rows")
print(f"✅ case_attributes → {df_case_attr.count():,} rows (all attribute_type=303)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. `dialer_calls` + `dialer_contact`
# MAGIC
# MAGIC `dialer_calls`: base of `Fact_dialer` — filtered to last 60 days in production.
# MAGIC `dialer_contact`: deduplicated by `ROW_NUMBER() OVER (PARTITION BY unique_id ORDER BY call_date DESC)`.
# MAGIC Some uniqueids have multiple rows — exactly what the dedup in Fact_dialer removes.

# COMMAND ----------

case_ids   = cases_pd["case_id"].tolist()
client_ids = cases_pd["client_id"].tolist()

dialer_rows = []
for i in range(N_DIALER):
    idx     = random.randint(0, N_CASES - 1)
    call_dt = rand_dt(END - timedelta(days=60), END)
    billsec = random.randint(0, 580)
    dialer_rows.append({
        "uniqueid":         f"UID{i:010d}",
        "queue_item_id":    random.randint(1, 99999),
        "disposition_code": random.randint(0, 5),
        "campaign_id":      random.randint(100, 110),
        "campaign_name":    f"Campaign_{random.randint(100,110)}",
        "case_id":          int(case_ids[idx]),
        "debtor_id":        int(cases_pd.iloc[idx]["debtor_id"]),
        "telecom_id":       f"TEL{random.randint(10000,99999)}",
        "client_id":        int(client_ids[idx]),
        "phone_number":     rand_phone(),
        "call_date":        call_dt,
        "duration":         billsec + random.randint(0, 20),
        "billsec":          billsec,
        "disposition":      random.choice(DISPOSITIONS),
        "hangup_cause":     random.choice(["NORMAL_CLEARING","NO_ANSWER","USER_BUSY","ORIGINATOR_CANCEL"]),
    })

df_dialer_calls = spark.createDataFrame(pd.DataFrame(dialer_rows)) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.dialer_calls"))
df_dialer_calls.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/dialer_calls")

# dialer_contact — includes intentional duplicates for dedup demo
dc_rows = []
for i, row in enumerate(dialer_rows):
    sip = random.choice(SIP_ACCOUNTS) if row["billsec"] > 3 else None
    dc_rows.append({
        "unique_id":   row["uniqueid"],
        "sip_account": sip,
        "contact_id":  f"CTT{i:08d}" if row["billsec"] >= 40 else None,
        "call_date":   row["call_date"],
    })
    if random.random() < 0.20:  # ~20% duplicate rows
        dc_rows.append({
            "unique_id":   row["uniqueid"],
            "sip_account": random.choice(SIP_ACCOUNTS),
            "contact_id":  None,
            "call_date":   row["call_date"] - timedelta(seconds=random.randint(1, 30)),
        })

df_dialer_contact = spark.createDataFrame(pd.DataFrame(dc_rows)) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.dialer_contact"))
df_dialer_contact.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/dialer_contact")

print(f"✅ dialer_calls   → {df_dialer_calls.count():,} rows (last 60 days)")
print(f"✅ dialer_contact → {df_dialer_contact.count():,} rows (includes duplicates for dedup demo)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. `ptp_overview`
# MAGIC
# MAGIC Source for `Fact_ptp`, `Fact_ptp_enriched`, and `Fact_contacts` (PTP association).
# MAGIC The `operator` column is the full name — matched to `users.full_name` via LOWER/TRIM.

# COMMAND ----------

users_pd  = pd.DataFrame(users_rows)
ptp_rows  = []

for i in range(N_PTP):
    idx        = random.randint(0, N_CASES - 1)
    user_row   = users_pd.sample(1).iloc[0]
    contact_dt = rand_dt(END - timedelta(days=400), END)
    promise_dt = contact_dt + timedelta(days=random.randint(1, 30))
    capital    = round(random.uniform(200, 60000), 2)
    paid_amt   = round(capital * random.uniform(0.8, 1.0), 2) if random.random() < 0.28 else 0.0

    ptp_rows.append({
        "ptp_id":                 f"PTP{i:08d}",
        "case_id":                int(case_ids[idx]),
        "client_id":              int(client_ids[idx]),
        "ref_number":             f"REF{int(case_ids[idx]):07d}",
        "client_ref_number":      f"CREF{int(case_ids[idx]):07d}",
        "operator":               user_row["full_name"],   # matched via LOWER(TRIM(...))
        "contact_id":             f"CTT{i:08d}",
        "type":                   random.choice(PTP_TYPES),
        "payment_number":         random.randint(1, 6),
        "number_of_installments": random.randint(1, 12),
        "contact_date":           contact_dt,
        "promise_date":           promise_dt,
        "last_payment_date":      promise_dt + timedelta(days=random.randint(0,5)) if paid_amt > 0 else None,
        "promise_capital":        capital,
        "promise_capital_total":  capital,
        "paid":                   paid_amt,
        "dpd":                    random.randint(1, 720),
        "phone_number":           rand_phone(),
        "contact_attribute":      random.choice(["Outgoing Call", None, "Inbound", "WhatsApp"]),
        "state":                  random.choice(PTP_STATES),
        "contact_time":           contact_dt.strftime("%H:%M:%S"),
    })

df_ptp_overview = spark.createDataFrame(pd.DataFrame(ptp_rows)) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.ptp_overview"))
df_ptp_overview.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/ptp_overview")
print(f"✅ ptp_overview → {df_ptp_overview.count():,} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6. `payments`
# MAGIC
# MAGIC Used in `Fact_payments` and `Fact_ptp_enriched` (NEW vs OLD MONEY check via `EXISTS`).
# MAGIC Includes all financial columns from `Fact_payments.sql`.

# COMMAND ----------

ptp_pd    = pd.DataFrame(ptp_rows)
paid_ptps = ptp_pd[ptp_pd["paid"] > 0].reset_index(drop=True)

pay_rows = []
for i, row in paid_ptps.iterrows():
    pay_rows.append({
        "payment_id":                      f"PAY{i:08d}",
        "ref_number":                      row["ref_number"],
        "case_id":                         row["case_id"],
        "client_id":                       row["client_id"],
        "payment_date":                    row["last_payment_date"],
        "payed_capital":                   row["paid"],
        "payed_plus_money":                round(row["paid"] * 0.05, 2),
        "payed_administrative_assessment": round(row["paid"] * 0.02, 2),
        "payed_delay_charge":              round(row["paid"] * 0.01, 2),
        "payment_type":                    random.choice(["PIX","Boleto","TED","Débito"]),
    })

df_payments = spark.createDataFrame(pd.DataFrame(pay_rows)) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.payments"))
df_payments.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/payments")
print(f"✅ payments → {df_payments.count():,} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 7. `contact_events`
# MAGIC
# MAGIC Base of `Fact_contacts`. Filtered in production: `contact_date >= last 60 days`
# MAGIC AND `insert_user NOT IN ('system_user','auto_process')`.

# COMMAND ----------

CHANNELS = ["whatsapp contact", "rcs message", "sms sent", "email sent", "bot attempt", "Manual follow up", "Negotiation call"]

contact_rows = []
for i in range(N_CONTACTS):
    idx      = random.randint(0, N_CASES - 1)
    user_row = users_pd.sample(1).iloc[0]
    c_dt     = rand_dt(END - timedelta(days=60), END)
    contact_rows.append({
        "contact_id":     f"CTT{i:08d}",
        "case_id":        int(case_ids[idx]),
        "telecom_id":     f"TEL{random.randint(10000,99999)}",
        "description":    random.choice(["bot attempt", "manual", "scheduled"]),
        "contact_date":   c_dt,
        "status_type_id": random.choice(STATUS_TYPES),
        "target_type_id": random.choice(TARGET_TYPES),
        "contact_text":   random.choice(CHANNELS),
        "insert_user":    user_row["user_name"],  # user_name — NOT system_user/auto_process
    })

df_contacts = spark.createDataFrame(pd.DataFrame(contact_rows)) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.contact_events"))
df_contacts.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/contact_events")
print(f"✅ contact_events → {df_contacts.count():,} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 8. `installment` — fallback contact_time
# MAGIC
# MAGIC Used in `Fact_ptp` when `contact_time` is NULL in `ptp_overview`.
# MAGIC Logic: `CONVERT(time, MIN(insert_date))` grouped by `case_id + date`.

# COMMAND ----------

inst_rows = [
    {"installment_id": f"INST{i:08d}", "case_id": r["case_id"],
     "ref_number": r["ref_number"], "insert_date": r["contact_date"], "amount": r["promise_capital"]}
    for i, r in enumerate(ptp_rows[:3000])
]

df_installment = spark.createDataFrame(pd.DataFrame(inst_rows)) \
    .withColumn("_ingested_at", current_timestamp()) \
    .withColumn("_source", lit("dtdi.installment"))
df_installment.write.format("delta").mode("overwrite").save(f"{BRONZE_PATH}/installment")
print(f"✅ installment → {df_installment.count():,} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 9. Bronze Summary

# COMMAND ----------

bronze_tables = {
    "company":         f"{BRONZE_PATH}/company",
    "client":          f"{BRONZE_PATH}/client",
    "users":           f"{BRONZE_PATH}/users",
    "cases":           f"{BRONZE_PATH}/cases",
    "case_attributes": f"{BRONZE_PATH}/case_attributes",
    "dialer_calls":    f"{BRONZE_PATH}/dialer_calls",
    "dialer_contact":  f"{BRONZE_PATH}/dialer_contact",
    "ptp_overview":    f"{BRONZE_PATH}/ptp_overview",
    "payments":        f"{BRONZE_PATH}/payments",
    "contact_events":  f"{BRONZE_PATH}/contact_events",
    "installment":     f"{BRONZE_PATH}/installment",
}

print("=" * 50)
print(f"{'TABLE':<20} {'ROWS':>10} {'COLS':>6}")
print("=" * 50)
for name, path in bronze_tables.items():
    df = spark.read.format("delta").load(path)
    print(f"{name:<20} {df.count():>10,} {len(df.columns):>6}")
print("=" * 50)
print("\n✅ Bronze complete — 11 tables mirroring dtdi schema.")
