-- DIM_CLIENT
-- Grain: one row per client (portfolio)

SELECT
    cl.client_id,
    c.company_id,
    c.company_name

FROM client cl
LEFT JOIN company c
    ON c.company_id = cl.company_id;
