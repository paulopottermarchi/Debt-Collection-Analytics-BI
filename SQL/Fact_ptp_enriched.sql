-- FACT_PTP_ENRICHED
-- Grain: one row per PTP (Promise to Pay)
-- Purpose: classify PTPs and payments into NEW vs OLD money and track payment status

WITH ptp_base AS (
    -- Select latest PTP per case per month
    SELECT
        ptp.case_id,
        ptp.client_id,
        ptp.ref_number,
        ptp.client_ref_number,
        ptp.operator,
        ptp.promise_date,
        ptp.promise_capital_total,
        ptp.promise_capital,
        ptp.contact_date,
        ptp.number_of_installments,
        ptp.payment_number,
        ptp.state,

        ROW_NUMBER() OVER (
            PARTITION BY
                ptp.case_id,
                YEAR(ptp.promise_date),
                MONTH(ptp.promise_date)
            ORDER BY
                CASE
                    WHEN ptp.type = 'Installment' THEN 1
                    ELSE 2
                END,
                ptp.promise_capital_total DESC,
                ptp.contact_date DESC
        ) AS rn

    FROM ptp_overview ptp

    WHERE ptp.promise_date >= DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
      AND ptp.promise_date <  DATEADD(
            MONTH, 1,
            DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
      )
),

/* ============================================
   PAYMENTS IN CURRENT MONTH
   ============================================ */
payments_month AS (
    SELECT
        p.*,

        pay.payment_id,
        pay.payment_date,
        pay.payed_capital,

        -- Check if previous payment exists
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM payments h
                WHERE h.ref_number = pay.ref_number
                  AND h.payment_date < pay.payment_date
                  AND h.payment_date >= DATEADD(
                        MONTH, -1,
                        DATEFROMPARTS(YEAR(pay.payment_date), MONTH(pay.payment_date), 1)
                  )
            )
            THEN 1 ELSE 0
        END AS has_previous_payment

    FROM ptp_base p

    INNER JOIN payments pay
        ON pay.ref_number = p.ref_number

    WHERE p.rn = 1
      AND pay.payment_date >= DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
      AND pay.payment_date <  DATEADD(
            MONTH, 1,
            DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
        )
),

/* ============================================
   PTP WITHOUT PAYMENT
   ============================================ */
ptp_without_payment AS (
    SELECT
        p.*,

        NULL AS payment_id,
        NULL AS payment_date,
        0.0  AS payed_capital,

        -- Payment in previous month
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM payments h
                WHERE h.ref_number = p.ref_number
                  AND h.payment_date >= DATEADD(
                        MONTH, -1,
                        DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
                  )
                  AND h.payment_date < DATEFROMPARTS(
                        YEAR(GETDATE()), MONTH(GETDATE()), 1
                  )
            )
            THEN 1 ELSE 0
        END AS has_previous_payment

    FROM ptp_base p

    WHERE p.rn = 1
      AND p.state NOT IN ('Expired', 'Canceled')

      AND NOT EXISTS (
            SELECT 1
            FROM payments pay
            WHERE pay.ref_number = p.ref_number
              AND pay.payment_date >= DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
              AND pay.payment_date <  DATEADD(
                    MONTH, 1,
                    DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
                )
      )
),

/* ============================================
   PROVIDER ATTRIBUTE
   ============================================ */
case_attribute_provider AS (
    SELECT
        ca.case_id,
        MAX(ca.attribute_value) AS provider
    FROM case_attributes ca
    WHERE ca.attribute_type = 303
    GROUP BY ca.case_id
)

SELECT
    x.case_id,
    x.client_id,
    c.company_name,

    x.ref_number,
    x.client_ref_number,
    x.operator,
    x.promise_date,
    x.promise_capital_total,
    x.promise_capital,
    x.number_of_installments,
    x.payment_number,

    ca.provider,

    x.payment_id,
    x.payment_date,
    x.payed_capital,

    /* NEW vs OLD MONEY */
    CASE
        WHEN x.has_previous_payment = 1 THEN 'OLD MONEY'
        ELSE 'NEW MONEY'
    END AS money_type,

    /* PTP STATUS */
    CASE
        WHEN x.payment_date IS NOT NULL THEN 'PAID'
        WHEN x.promise_date < CAST(GETDATE() AS DATE) THEN 'OVERDUE'
        ELSE 'DUE'
    END AS ptp_status

FROM (
    SELECT * FROM payments_month
    UNION ALL
    SELECT * FROM ptp_without_payment
) x

LEFT JOIN client cl
    ON cl.client_id = x.client_id

LEFT JOIN company c
    ON c.company_id = cl.company_id

LEFT JOIN case_attribute_provider ca
    ON ca.case_id = x.case_id

ORDER BY
    x.ref_number,
    x.payment_date;
