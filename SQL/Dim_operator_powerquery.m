let
    // Data source
    Source = Sql.Database(
        "SERVER_NAME", 
        "DATABASE_NAME", 
        [
            Query = "
                SELECT 
                    u.user_id,
                    u.user_name,
                    u.first_name,
                    u.last_name,
                    u.full_name,
                    u.short_name,
                    u.user_status,
                    u.sip_account,
                    u.insert_date,
                    u.update_date
                FROM users u
            "
        ]
    ),

    // Convert SIP account to numeric when possible
    ChangedType = Table.TransformColumns(
        Source,
        {{"sip_account", each try Number.FromText(_) otherwise null, type number}}
    ),

    // Convert dates
    DateTypes = Table.TransformColumnTypes(
        ChangedType,
        {{"insert_date", type date}, {"update_date", type date}}
    ),

    // Flag inactive users
    AddedInactiveFlag = Table.AddColumn(
        DateTypes,
        "is_inactive",
        each if [user_status] <> 1 then "Yes" else "No"
    ),

    // Flag operators (example rule: SIP >= 200)
    AddedOperatorFlag = Table.AddColumn(
        AddedInactiveFlag,
        "is_operator",
        each if [sip_account] >= 200 then "Yes" else "No"
    ),

    // Replace errors
    Cleaned = Table.ReplaceErrorValues(
        AddedOperatorFlag,
        {{"is_operator", "Yes"}}
    ),

    // Select useful columns
    FinalColumns = Table.SelectColumns(
        Cleaned,
        {
            "user_id",
            "user_name",
            "full_name",
            "user_status",
            "is_inactive",
            "is_operator",
            "sip_account",
            "insert_date",
            "update_date"
        }
    )

in
    FinalColumns
