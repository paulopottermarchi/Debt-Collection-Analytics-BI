-- FACT_CONTACTS
-- Grain: one row per contact interaction
-- Purpose: unify manual and dialer interactions with enriched business logic

WITH contact_base AS (
    SELECT
        c.contact_id,
        c.case_id,
        c.telecom_id,
        c.description,
        c.contact_date,
        c.status_type_id,
        c.target_type_id,
        c.contact_text,

        LOWER(TRIM(c.insert_user)) AS operator_login

    FROM contact_events c

    WHERE
        c.contact_date >= DATEADD(DAY, -60, CAST(GETDATE() AS DATE))
        AND c.insert_user NOT IN ('system_user','auto_process')
),

/* ============================================
   MATCH CONTACT WITH DIALER (±15 min window)
   ============================================ */
manual_campaign_match AS (
    SELECT
        cb.contact_id,
        d.contact_id AS dialer_contact_id,
        d.campaign_id,
        d.campaign_name,

        ROW_NUMBER() OVER (
            PARTITION BY cb.contact_id
            ORDER BY d.call_date DESC
        ) AS rn

    FROM contact_base cb

    INNER JOIN dialer_calls d
        ON d.telecom_id = cb.telecom_id
       AND d.case_id = cb.case_id
       AND d.call_date BETWEEN
            DATEADD(MINUTE, -15, cb.contact_date)
            AND DATEADD(MINUTE, 15, cb.contact_date)
),

/* ============================================
   PTP ASSOCIATION
   ============================================ */
ptp_dedup AS (
    SELECT
        p.contact_id,
        p.contact_date AS ptp_contact_date,
        p.promise_capital,
        p.promise_capital_total,
        p.promise_date,

        ROW_NUMBER() OVER (
            PARTITION BY p.contact_id
            ORDER BY p.promise_date DESC
        ) AS rn

    FROM ptp_overview p
    WHERE p.contact_id IS NOT NULL
)

SELECT
    cb.contact_id,
    mcm.dialer_contact_id,

    cb.case_id,
    cs.client_id,

    cb.telecom_id,

    cb.contact_date AS contact_datetime,
    CAST(cb.contact_date AS DATE) AS contact_date,
    DATEPART(HOUR, cb.contact_date) AS contact_hour,

    u.user_id AS operator_id,
    u.full_name AS operator_name,
    cb.operator_login,

    cb.contact_text,
    cb.status_type_id,
    cb.target_type_id,

    mcm.campaign_id,
    mcm.campaign_name,

    CASE
        WHEN mcm.campaign_id IS NOT NULL THEN 1
        ELSE 0
    END AS derived_from_dialer_flag,

    ptp.ptp_contact_date,
    ptp.promise_capital,
    ptp.promise_capital_total,
    ptp.promise_date,

    CASE
        WHEN ptp.contact_id IS NOT NULL THEN 1
        ELSE 0
    END AS has_promise,

    /* ---------- CHANNEL FLAGS ---------- */
    CASE WHEN cb.contact_text LIKE '%bot%' THEN 1 ELSE 0 END AS flag_bot,
    CASE WHEN cb.contact_text LIKE '%whats%' THEN 1 ELSE 0 END AS flag_whatsapp,
    CASE WHEN cb.contact_text LIKE '%rcs%' THEN 1 ELSE 0 END AS flag_rcs,
    CASE WHEN cb.contact_text LIKE '%sms%' THEN 1 ELSE 0 END AS flag_sms,
    CASE WHEN cb.contact_text LIKE '%email%' THEN 1 ELSE 0 END AS flag_email,

    /* ---------- STATUS LABEL ---------- */
    CASE
        WHEN cb.status_type_id IN (2,300) THEN 'Agreement'
        WHEN cb.status_type_id IN (118,119,120) THEN 'Negotiation'
        WHEN cb.status_type_id = 48 THEN 'No Contact Attempt'
        WHEN cb.status_type_id = 8 THEN 'No Interaction'
        ELSE CONCAT('Status_', cb.status_type_id)
    END AS status_label,

    /* ---------- CHANNEL ---------- */
    CASE
        WHEN cb.contact_text LIKE '%whats%' THEN 'WhatsApp'
        WHEN cb.contact_text LIKE '%rcs%' THEN 'RCS'
        WHEN cb.contact_text LIKE '%sms%' THEN 'SMS'
        WHEN cb.contact_text LIKE '%email%' THEN 'Email'
        WHEN cb.description LIKE '%bot%' THEN 'BOT'
        WHEN mcm.campaign_id IS NOT NULL THEN 'Dialer'
        ELSE 'Manual'
    END AS contact_channel,

    /* ---------- METRICS ---------- */
    CASE
        WHEN cb.target_type_id IN (1,2) THEN 1
        ELSE 0
    END AS is_cpc,

    CASE
        WHEN cb.target_type_id = 1
         AND cb.status_type_id IN (2,300,118,119,120)
        THEN 1 ELSE 0
    END AS is_rpc

FROM contact_base cb

LEFT JOIN users u
    ON u.user_name = cb.operator_login

LEFT JOIN cases cs
    ON cs.case_id = cb.case_id

LEFT JOIN manual_campaign_match mcm
    ON cb.contact_id = mcm.contact_id
   AND mcm.rn = 1

LEFT JOIN ptp_dedup ptp
    ON cb.contact_id = ptp.contact_id
   AND ptp.rn = 1;
