-- Fact_Payments
-- Grain: one row per payment event
-- Source: operational payment system

SELECT
    p.payment_id,
    p.client_id,
    p.case_id,
    p.payment_date,
    p.payed_capital,
    p.payed_plus_money,
    p.payed_administrative_assessment,
    p.payed_delay_charge,
    c.dpd_original,
    c.original_capital,
    c.actual_capital,
    c.case_statute_id

FROM payment p
LEFT JOIN cases_information c
    ON p.case_id = c.case_id;
