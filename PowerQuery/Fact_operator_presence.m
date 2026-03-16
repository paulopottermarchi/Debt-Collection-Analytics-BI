let
    //---------------------------------------
    // FACT_OPERATOR_PRESENCE
    // Grain: one row per operator per workday
    // Purpose: track operator attendance using contact activity
    //---------------------------------------

    //---------------------------------------
    // 1. Generate list of work dates
    //---------------------------------------

    StartDate = #date(2025, 1, 1),

    CurrentDateTime =
        DateTimeZone.SwitchZone(
            DateTimeZone.FixedUtcNow(),
            -3
        ),

    EndDate = Date.From(CurrentDateTime),

    DateList =
        List.Dates(
            StartDate,
            Duration.Days(EndDate - StartDate) + 1,
            #duration(1,0,0,0)
        ),

    DateTable =
        Table.FromList(
            DateList,
            Splitter.SplitByNothing(),
            {"WorkDate"}
        ),

    //---------------------------------------
    // 2. Identify weekdays
    //---------------------------------------

    AddWeekDay =
        Table.AddColumn(
            DateTable,
            "WeekDay",
            each Date.DayOfWeek([WorkDate], Day.Sunday)
        ),

    //---------------------------------------
    // 3. Keep only business days
    //---------------------------------------

    BusinessDays =
        Table.SelectRows(
            AddWeekDay,
            each [WeekDay] >= 1 and [WeekDay] <= 5
        ),

    CleanDates =
        Table.RemoveColumns(
            BusinessDays,
            {"WeekDay"}
        ),

    //---------------------------------------
    // 4. Filter operators
    //---------------------------------------

    Users = Dim_Operator,

    Operators =
        Table.SelectRows(
            Users,
            each [is_operator] = "Yes"
        ),

    //---------------------------------------
    // 5. Cartesian join operators x dates
    //---------------------------------------

    CrossJoin =
        Table.AddColumn(
            Operators,
            "AllDates",
            each CleanDates
        ),

    Expanded =
        Table.ExpandTableColumn(
            CrossJoin,
            "AllDates",
            {"WorkDate"}
        ),

    //---------------------------------------
    // 6. Merge contact activity (CC table)
    //---------------------------------------

    Merged =
        Table.NestedJoin(
            Expanded,
            {"user_name", "WorkDate"},
            CC_Operator_Activity,
            {"user_name", "contact_date"},
            "Activity",
            JoinKind.LeftOuter
        ),

    ExpandedActivity =
        Table.ExpandTableColumn(
            Merged,
            "Activity",
            {"contact_count"},
            {"contact_count"}
        ),

    //---------------------------------------
    // 7. Attendance status logic
    //---------------------------------------

    AddedStatus =
        Table.AddColumn(
            ExpandedActivity,
            "attendance_status",
            each
                let
                    startDate = [insert_date],
                    endDate =
                        if [update_date] = null
                        then EndDate
                        else [update_date],

                    workDay = [WorkDate],
                    activity = [contact_count],

                    trainingEnd =
                        startDate + #duration(2,0,0,0)

                in

                    if workDay < startDate then
                        "not_employed"

                    else if workDay >= endDate then
                        "inactive"

                    else if workDay >= startDate
                        and workDay < trainingEnd then
                        "training"

                    else if activity <> null
                        and activity > 0 then
                        "present"

                    else
                        "absent",
            type text
        ),

    //---------------------------------------
    // 8. Sort output
    //---------------------------------------

    Sorted =
        Table.Sort(
            AddedStatus,
            {
                {"WorkDate", Order.Descending},
                {"full_name", Order.Ascending}
            }
        ),

    //---------------------------------------
    // 9. Final column selection
    //---------------------------------------

    FinalColumns =
        Table.SelectColumns(
            Sorted,
            {
                "users_id",
                "user_name",
                "full_name",
                "insert_date",
                "update_date",
                "sip_account",
                "WorkDate",
                "contact_count",
                "attendance_status"
            }
        ),

    ChangedType =
        Table.TransformColumnTypes(
            FinalColumns,
            {{"WorkDate", type date}}
        )

in
    ChangedType
