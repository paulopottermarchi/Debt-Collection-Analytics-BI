-- DIM_COMPANY
-- Grain: one row per client (portfolio)
-- Purpose: map clients to their respective companies

SELECT
    c.company_id,
    c.company_name,
    cl.client_id

FROM company c

LEFT JOIN client cl
    ON cl.company_id = c.company_id

WHERE
    cl.client_id > 1
    AND cl.client_id <> 999;
