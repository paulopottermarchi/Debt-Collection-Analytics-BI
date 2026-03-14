-- FACT_PROMISES (PTP)
-- Grain: one row per promise event

-- Business Logic:
-- 1. Extract promise events from operational system
-- 2. Normalize operator names
-- 3. Map phone area codes to geographic regions
-- 4. Enrich promises with payment outcome
-- 5. Reconstruct exact contact datetime

-- fact_promises.sql
-- Fact table representing Promise To Pay (PTP) events in a debt collection BI system
-- Grain: one row per promise event

DECLARE @startDate DATE = DATEFROMPARTS(YEAR(GETDATE()) - 1, 1, 1);
DECLARE @endDate   DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE));

WITH ddd_map AS (
    -- Mapping Brazilian area codes (DDD) to states
    SELECT v.ddd, v.uf
    FROM (VALUES
        ('11','São Paulo'),('12','São Paulo'),('13','São Paulo'),('14','São Paulo'),('15','São Paulo'),
        ('16','São Paulo'),('17','São Paulo'),('18','São Paulo'),('19','São Paulo'),
        ('21','Rio de Janeiro'),('22','Rio de Janeiro'),('24','Rio de Janeiro'),
        ('27','Espírito Santo'),('28','Espírito Santo'),
        ('31','Minas Gerais'),('32','Minas Gerais'),('33','Minas Gerais'),('34','Minas Gerais'),
        ('35','Minas Gerais'),('37','Minas Gerais'),('38','Minas Gerais'),
        ('41','Paraná'),('42','Paraná'),('43','Paraná'),('44','Paraná'),('45','Paraná'),('46','Paraná'),
        ('47','Santa Catarina'),('48','Santa Catarina'),('49','Santa Catarina'),
        ('51','Rio Grande do Sul'),('53','Rio Grande do Sul'),('54','Rio Grande do Sul'),('55','Rio Grande do Sul'),
        ('61','Distrito Federal'),
        ('62','Goiás'),('64','Goiás'),
        ('63','Tocantins'),
        ('65','Mato Grosso'),('66','Mato Grosso'),
        ('67','Mato Grosso do Sul'),
        ('68','Acre'),
        ('69','Rondônia'),
        ('71','Bahia'),('73','Bahia'),('74','Bahia'),('75','Bahia'),('77','Bahia'),
        ('79','Sergipe'),
        ('81','Pernambuco'),('87','Pernambuco'),
        ('82','Alagoas'),
        ('83','Paraíba'),
        ('84','Rio Grande do Norte'),
        ('85','Ceará'),('88','Ceará'),
        ('86','Piauí'),('89','Piauí'),
        ('91','Pará'),('93','Pará'),('94','Pará'),
        ('92','Amazonas'),('97','Amazonas'),
        ('95','Roraima'),
        ('96','Amapá'),
        ('98','Maranhão'),('99','Maranhão')
    ) v(ddd, uf)
),

contact_time AS (
    -- Extract contact time from promise interaction logs
    SELECT
        p.case_id,
        CONVERT(date, p.contact_date) AS contact_date,
        LOWER(LTRIM(RTRIM(p.operator))) AS operator_norm,
        MAX(p.contact_time) AS contact_time
    FROM promises_information p
    WHERE p.contact_date >= @startDate
      AND p.contact_date <  @endDate
    GROUP BY
        p.case_id,
        CONVERT(date, p.contact_date),
        LOWER(LTRIM(RTRIM(p.operator)))
),

installment_time AS (
    -- Fallback contact time derived from installment creation
    SELECT
        i.case_id,
        CONVERT(date, i.insert_date) AS contact_date,
        CONVERT(time, MIN(i.insert_date)) AS contact_time
    FROM installment i
    WHERE i.insert_date >= @startDate
      AND i.insert_date <  @endDate
    GROUP BY
        i.case_id,
        CONVERT(date, i.insert_date)
),

promise_base AS (
    -- Base dataset aggregating promise events
    SELECT
        o.case_id,
        o.client_id,

        TRIM(attr.attribute_value) AS provider,

        LOWER(TRIM(o.operator)) AS operator_norm,
        o.operator AS operator_name,
        u.user_id AS operator_id,

        o.type,
        o.payment_number,

        CONVERT(date, o.contact_date) AS contact_date,
        CONVERT(date, o.promise_date) AS promise_date,
        o.last_payment_date AS payment_date,

        o.dpd,

        SUBSTRING(o.phone_number, 3, 2) AS ddd,

        CASE
            WHEN o.contact_attribute IS NULL OR o.contact_attribute = 'NULL'
            THEN 'Outgoing Call'
            ELSE o.contact_attribute
        END AS contact_attribute,

        SUM(o.promise_capital) AS promise_capital,
        SUM(o.paid) AS paid

    FROM ptp_overview o

    LEFT JOIN users u
        ON LOWER(TRIM(u.full_name)) = LOWER(TRIM(o.operator))

    LEFT JOIN cases c
        ON c.case_id = o.case_id

    LEFT JOIN case_attributes attr
        ON attr.case_id = c.case_id
       AND attr.attribute_type = 303

    WHERE o.contact_date >= @startDate
      AND o.contact_date <  @endDate

    GROUP BY
        o.case_id,
        o.client_id,
        TRIM(attr.attribute_value),
        LOWER(TRIM(o.operator)),
        o.operator,
        u.user_id,
        o.type,
        o.payment_number,
        CONVERT(date, o.contact_date),
        CONVERT(date, o.promise_date),
        o.last_payment_date,
        o.dpd,
        SUBSTRING(o.phone_number, 3, 2),
        CASE
            WHEN o.contact_attribute IS NULL OR o.contact_attribute = 'NULL'
            THEN 'Outgoing Call'
            ELSE o.contact_attribute
        END
),

promise_enriched AS (
    SELECT
        b.*,
        m.uf,

        CASE
            WHEN paid = 0 THEN 'not paid'
            ELSE 'paid'
        END AS was_paid,

        CASE
            WHEN dpd BETWEEN 0 AND 15 THEN 'DPD 0-15'
            WHEN dpd BETWEEN 16 AND 30 THEN 'DPD 16-30'
            WHEN dpd BETWEEN 31 AND 60 THEN 'DPD 31-60'
            WHEN dpd BETWEEN 61 AND 90 THEN 'DPD 61-90'
            WHEN dpd BETWEEN 91 AND 120 THEN 'DPD 91-120'
            WHEN dpd BETWEEN 121 AND 180 THEN 'DPD 121-180'
            WHEN dpd BETWEEN 181 AND 360 THEN 'DPD 181-360'
            ELSE 'DPD 360+'
        END AS dpd_range

    FROM promise_base b
    LEFT JOIN ddd_map m
        ON m.ddd = b.ddd
)

SELECT
    pe.*,
    COALESCE(ct.contact_time, it.contact_time) AS contact_time,

    CASE
        WHEN COALESCE(ct.contact_time, it.contact_time) IS NULL THEN NULL
        ELSE DATEADD(
            SECOND,
            DATEDIFF(SECOND, 0, COALESCE(ct.contact_time, it.contact_time)),
            CAST(pe.contact_date AS datetime)
        )
    END AS contact_datetime

FROM promise_enriched pe

LEFT JOIN contact_time ct
    ON ct.case_id = pe.case_id
   AND ct.contact_date = pe.contact_date
   AND ct.operator_norm = pe.operator_norm

LEFT JOIN installment_time it
    ON it.case_id = pe.case_id
   AND it.contact_date = pe.contact_date;
