💰 Debt Collection Analytics — Data Engineering & BI Project

End-to-end data analytics architecture designed for debt collection operations, focused on building a reliable, scalable, and audit-ready analytical layer.

📊 Overview

This project addresses a common problem in event-driven operational systems: inconsistent KPIs caused by poor data modeling and lack of defined granularity.

The solution restructures the analytical layer to ensure:

Clear event separation

Controlled cardinality (1:N)

Elimination of many-to-many distortions

Full traceability from KPI to source event

It enables accurate analysis of:

Contact performance (Dialer, Manual, Digital)

RPC (Right Party Contact) and CPC metrics

PTP (Promise to Pay) generation and conversion

Payment behavior and recovery efficiency

Operator productivity and attendance

Portfolio and company-level performance

🏗️ Architecture
SQL Server (Raw / Operational Data)
        │
        ▼
SQL Layer (Fact & Dimension Modeling - T-SQL)
        │
        ▼
Power Query (Transformation Layer)
        │
        ▼
DAX (Semantic Layer & Metrics)
        │
        ▼
Power BI (Visualization Layer)
⭐ Data Modeling Approach

The model follows a star schema architecture, designed around event-driven domains.

📌 Fact Tables (Event-Based)

fact_dialer → Call attempts (granularity: call attempt)

fact_contacts → CRM contact events

fact_ptp → Promise-to-pay events

fact_ptp_enriched → PTP with payment linkage

fact_payments → Financial transactions

Each fact table has a well-defined grain, avoiding metric distortion.

📌 Dimension Tables (Conformed)

dim_cases → Contract-level entity

dim_operator → Operator dimension (shared across facts)

dim_client → Client/company structure

dim_date → Time intelligence

Dimensions are conformed and reusable, ensuring consistency across domains.

🧠 Key Engineering Decisions

Explicit granularity definition per fact

Removal of many-to-many relationships

Controlled joins between operational and financial domains

Use of ROW_NUMBER() for deterministic deduplication

Modular transformations using CTEs

Centralization of business logic in the data layer (SQL)

Temporal association between calls and PTPs

Separation of event domains (Dialer, Contact, Payment, PTP)

📈 Key Metrics

CPC (Contact per Call)

RPC (Right Party Contact)

PTP Conversion Rate

Paid / RPC

Paid / Contacts

Collection Efficiency by DPD

Operator Productivity

Attendance & Absenteeism

All metrics are:

✔ Traceable to source events

✔ Based on consistent grain

✔ Free from duplication bias

📊 Dashboard

The dashboard supports:

Executive (Revenue, Portfolio Performance)

Managerial (Conversion, Efficiency)

Operational (Calls, Contacts, Productivity)

📚 Data Governance

To ensure reliability and maintainability:

📐 ERD (Entity Relationship Diagram) documenting relationships and cardinality

📖 Data Dictionary defining:

Fact granularity

KPI definitions

Business rules

This reduces ambiguity and improves scalability of the model.

⚙️ Performance & Scalability

Dynamic date filtering

Rolling windows for high-volume data (e.g., dialer)

Pre-aggregations at SQL layer

Use of COUNT_BIG and analytical functions

Optimized queries for large datasets

⚙️ Technologies

SQL Server

T-SQL (CTEs, Window Functions)

Power Query (M)

DAX

Power BI

Dimensional Modeling (Star Schema)

📂 Repository Structure
.
├── dax/
├── powerquery/
├── sql/
├── data-model/
│   ├── star_schema.png
│   └── executive_dashboard.png
🎯 Purpose

This project demonstrates:

Real-world data engineering practices

Design of a production-grade analytical model

Strong alignment between business logic and data architecture

Ability to build scalable and auditable data solutions

🚀 Next Steps

Cloud migration (AWS / Azure)

Data orchestration (Airflow)

Incremental loads & partitioning

Real-time pipeline exploration

Forecasting models

👨‍💻 Author

Paulo Potter Marchi
Data Analyst → Data Engineer

⭐ Final Note

This project reinforces a key principle:

Reliable metrics come from correct data modeling — not from dashboards.
