-- Business Logic
-- 1. Extract dialer call events
-- 2. Deduplicate dialer_contact by unique call identifier
-- 3. Enrich calls with operator information
-- 4. Generate operational flags:
--      answered_flag
--      operator_not_connected_flag
--      cpc_flag
-- 5. Output analytical-ready dialer dataset

-- FACT_DIALER
-- Grain: one row per dialer call attempt
-- Purpose: store dialer operational events for analytics and performance monitoring

SET NOCOUNT ON;

WITH dialer_contact_dedup AS (
    -- Deduplicate dialer contact records by unique call identifier
    SELECT
        dc.unique_id,
        dc.sip_account,
        dc.contact_id,

        ROW_NUMBER() OVER (
            PARTITION BY dc.unique_id
            ORDER BY dc.call_date DESC
        ) AS rn

    FROM dialer_contact dc
),

dialer_base AS (
    -- Base dialer call events
    SELECT
        d.uniqueid AS dialer_call_id,
        d.queue_item_id,
        d.disposition_code,

        d.campaign_id,
        d.campaign_name,

        d.case_id,
        d.debtor_id,
        d.telecom_id,
        d.client_id,
        d.phone_number,

        d.call_date AS call_datetime,
        CAST(d.call_date AS DATE) AS call_date,

        ISNULL(d.duration,0) AS duration_sec,
        ISNULL(d.billsec,0)  AS billsec_sec,

        d.disposition,
        d.hangup_cause

    FROM dialer_calls d
    WHERE d.call_date >= DATEADD(DAY, -60, CAST(GETDATE() AS DATE))
),

dialer_final AS (
    SELECT
        d.*,

        dc.contact_id,
        dc.sip_account AS dialer_sip_account,

        u.user_id   AS operator_id,
        u.user_name AS operator_name,

        -- Technical Answer Flag
        CASE 
            WHEN ISNULL(d.billsec_sec,0) > 0 THEN 1
            ELSE 0
        END AS answered_flag,

        -- Call answered but operator not connected
        CASE
            WHEN ISNULL(d.billsec_sec,0) > 3
             AND dc.sip_account IS NULL
            THEN 1
            ELSE 0
        END AS operator_not_connected_flag,

        -- Technical CPC (Connected Party Contact)
        CASE 
            WHEN ISNULL(d.billsec_sec,0) >= 40
             AND dc.sip_account IS NOT NULL
            THEN 1
            ELSE 0
        END AS cpc_flag

    FROM dialer_base d

    LEFT JOIN dialer_contact_dedup dc
        ON dc.unique_id = d.dialer_call_id
       AND dc.rn = 1

    LEFT JOIN users u
        ON u.sip_account = dc.sip_account
)

SELECT *
FROM dialer_final
ORDER BY call_datetime DESC;
