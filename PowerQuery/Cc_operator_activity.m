let
    Source =
        Sql.Database(
            "SERVER_NAME",
            "DATABASE_NAME",
            [
                Query = "

-- FACT_OPERATOR_ACTIVITY
-- Grain: one row per operator per day
-- Purpose: count operator contact interactions to infer daily activity

DECLARE @startDate DATE = '2025-01-01';
DECLARE @endDate   DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE));

SELECT
    u.user_id,
    cnt.insert_user AS user_name,
    CONVERT(date, cnt.contact_date) AS contact_date,
    COUNT_BIG(*) AS contact_count

FROM contact_events cnt

LEFT JOIN users u
    ON u.user_name = cnt.insert_user

WHERE
    cnt.target_type_id IN (1,2,5,6)
    AND cnt.insert_user NOT IN ('system_user','auto_process')
    AND cnt.contact_date >= @startDate
    AND cnt.contact_date <  @endDate

GROUP BY
    u.user_id,
    cnt.insert_user,
    CONVERT(date, cnt.contact_date);
                "
            ]
        ),

    ChangedType =
        Table.TransformColumnTypes(
            Source,
            {
                {"user_id", Int64.Type},
                {"user_name", type text},
                {"contact_date", type date},
                {"contact_count", Int64.Type}
            }
        )
in
    ChangedType
