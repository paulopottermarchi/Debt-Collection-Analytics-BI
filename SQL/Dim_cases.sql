-- DIM_CASES
-- Grain: one row per case (contract)
-- Purpose: store descriptive attributes of collection cases for analytical modeling

SET NOCOUNT ON;

SELECT
    c.case_id,
    c.client_id,
    c.debtor_id,

    -- Business identifiers
    c.ref_number,
    c.client_ref_number,

    -- Current case status
    c.case_status_id,

    -- Financial values
    c.original_capital,
    c.actual_capital,

    -- Context attributes
    c.department_id,
    c.currency_id,

    -- Dates
    CAST(c.insert_date AS DATE) AS insert_date,
    CAST(c.update_date AS DATE) AS update_date,

    -- Additional attribute (example: provider)
    attr.attribute_value AS provider

FROM cases c

LEFT JOIN case_attributes attr
    ON c.case_id = attr.case_id
   AND attr.attribute_type = 303

WHERE
    c.case_status_id IN (0,1)
    OR c.update_date >= DATEADD(DAY, -60, CAST(GETDATE() AS DATE));
