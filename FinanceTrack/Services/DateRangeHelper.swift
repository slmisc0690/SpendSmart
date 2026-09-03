import Foundation

/// Computes the week/month date ranges used throughout the app (dashboard totals, reports).
/// This is the single source of truth for "what is the current week/month" — `BudgetCalculator`
/// takes the resulting `DateInterval` as input rather than computing its own.
enum DateRangeHelper {

    /// The single calendar day containing `referenceDate` — midnight to the following midnight,
    /// `end` exclusive. THE canonical half-open single-day boundary in this app — every existing
    /// call site that needs "does this Date fall on day X" (`DailyTransactionTotals.genericGroups`,
    /// `ExpenseListView`, `WeeklyBudgetView`, `MonthlySummaryView`) independently hand-rolls this
    /// exact `startOfDay` + `byAdding: .day` shape; new code should call this instead of
    /// reimplementing it a fifth time. Added for the Ask SpendSmart transaction-search reliability
    /// fix, whose prior bug was comparing a transaction's full timestamp against a bare end-of-range
    /// `Date` at literal midnight (`transaction.date > endDate`) — which incorrectly excluded any
    /// transaction later than midnight on its own end day. Always use `dayRangeContaining(_:).end`
    /// as an EXCLUSIVE upper bound, never the raw parsed end date itself.
    static func dayRangeContaining(_ referenceDate: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: referenceDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? referenceDate
        return DateInterval(start: start, end: end)
    }

    /// The 7-day range containing `referenceDate`, starting Sunday or Monday depending on
    /// `weekStartsOnSunday` (from `BudgetSettings.weekStartsOnSunday`). `end` is exclusive
    /// (the instant the following week begins).
    static func weekRangeContaining(
        _ referenceDate: Date,
        weekStartsOnSunday: Bool = true,
        calendar: Calendar = .current
    ) -> DateInterval {
        var cal = calendar
        cal.firstWeekday = weekStartsOnSunday ? 1 : 2
        let start = cal.dateInterval(of: .weekOfYear, for: referenceDate)?.start ?? referenceDate
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? referenceDate
        return DateInterval(start: start, end: end)
    }

    static func currentWeekRange(weekStartsOnSunday: Bool = true, calendar: Calendar = .current) -> DateInterval {
        weekRangeContaining(.now, weekStartsOnSunday: weekStartsOnSunday, calendar: calendar)
    }

    /// The calendar-month range containing `referenceDate`. `end` is exclusive.
    static func monthRangeContaining(_ referenceDate: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: referenceDate) ?? DateInterval(start: referenceDate, end: referenceDate)
    }

    static func currentMonthRange(calendar: Calendar = .current) -> DateInterval {
        monthRangeContaining(.now, calendar: calendar)
    }

    /// The calendar month immediately before the one containing `referenceDate`.
    static func lastMonthRange(relativeTo referenceDate: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let previousMonthDate = calendar.date(byAdding: .month, value: -1, to: referenceDate) ?? referenceDate
        return monthRangeContaining(previousMonthDate, calendar: calendar)
    }

    /// The 3-calendar-month quarter (Jan–Mar, Apr–Jun, Jul–Sep, Oct–Dec) containing `referenceDate`.
    static func quarterRangeContaining(_ referenceDate: Date, calendar: Calendar = .current) -> DateInterval {
        let month = calendar.component(.month, from: referenceDate)
        let quarterStartMonth = ((month - 1) / 3) * 3 + 1
        var components = calendar.dateComponents([.year], from: referenceDate)
        components.month = quarterStartMonth
        components.day = 1
        let start = calendar.date(from: components) ?? referenceDate
        let end = calendar.date(byAdding: .month, value: 3, to: start) ?? referenceDate
        return DateInterval(start: start, end: end)
    }

    static func currentQuarterRange(calendar: Calendar = .current) -> DateInterval {
        quarterRangeContaining(.now, calendar: calendar)
    }

    /// The calendar-year range containing `referenceDate`. `end` is exclusive.
    static func yearRangeContaining(_ referenceDate: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .year, for: referenceDate) ?? DateInterval(start: referenceDate, end: referenceDate)
    }

    static func currentYearRange(calendar: Calendar = .current) -> DateInterval {
        yearRangeContaining(.now, calendar: calendar)
    }

    /// Short display text for a week range, e.g. "Jul 6 – Jul 12".
    static func weekDisplayText(for interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        // `interval.end` is exclusive (the start of the *next* week); step back one second so the
        // displayed range shows the week's actual last day (e.g. Saturday, not the following Sunday).
        let lastDay = interval.end.addingTimeInterval(-1)
        return "\(formatter.string(from: interval.start)) \u{2013} \(formatter.string(from: lastDay))"
    }

    /// Display text for a month range, e.g. "July 2026".
    static func monthDisplayText(for interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: interval.start)
    }

    /// The overlap between `interval` and `bounds`, or `nil` if they don't overlap at all. Used
    /// by the Monthly screen so a week that spans two months only counts, on that screen, the
    /// slice of itself that actually falls inside the selected month.
    static func clampedInterval(_ interval: DateInterval, to bounds: DateInterval) -> DateInterval? {
        interval.intersection(with: bounds)
    }

    /// Every Sunday/Monday-start calendar week that touches `interval` (typically a month),
    /// walked from its start to its end. Shared by the Monthly Summary screen only — This Week /
    /// Week-by-Week / Monthly Outlook / Monthly Plan's own weekly comparisons all moved to
    /// `fourWeekBlocks(in:)` below; `weekStartsOnSunday`-based weeks are kept here purely because
    /// Monthly Summary (and Insights/SpendSense/Scenario, which never touch this function at all)
    /// still use the plain Sunday/Monday scheme and were explicitly left unchanged.
    static func weeksOverlapping(
        _ interval: DateInterval,
        weekStartsOnSunday: Bool = true,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        var weeks: [DateInterval] = []
        var cursor = interval.start
        while cursor < interval.end {
            let week = weekRangeContaining(cursor, weekStartsOnSunday: weekStartsOnSunday, calendar: calendar)
            weeks.append(week)
            cursor = week.end
        }
        return weeks
    }

    /// MONTH-ALIGNED FOUR-WEEK SCHEME — `month` split into exactly 4 weeks, always: Week 1 starts
    /// on the 1st of the month regardless of what weekday that is (never the Sunday/Monday
    /// calendar week containing it, which is what `weeksOverlapping` does and why that scheme can
    /// bleed a few days from the adjacent month into the first/last row). Weeks 1–3 are always 7
    /// days; Week 4 is the remainder of the month (7–10 days, depending on month length) — never
    /// a 5th/6th short week. Every block is a strict subset of `month`, so the 4 blocks' spending
    /// totals always sum to exactly the month's own total, with no cross-month bleed either way.
    /// This is the ONE authoritative source for This Week / Week-by-Week / Monthly Outlook /
    /// Monthly Plan's weekly comparisons — see `DashboardView`/`WeeklyBudgetView`/`MonthlyPlanView`
    /// `weekInterval` and `MonthlyPlanCalculator.summary()`'s own `weeks` computation.
    static func fourWeekBlocks(in month: DateInterval, calendar: Calendar = .current) -> [DateInterval] {
        var blocks: [DateInterval] = []
        var cursor = month.start
        for index in 0..<4 {
            let end: Date
            if index == 3 {
                end = month.end
            } else {
                end = calendar.date(byAdding: .day, value: 7, to: cursor) ?? month.end
            }
            blocks.append(DateInterval(start: cursor, end: end))
            cursor = end
        }
        return blocks
    }

    /// Whichever of `fourWeekBlocks(in:)` (for the month containing `referenceDate`) actually
    /// contains `referenceDate` — the month-aligned replacement for `currentWeekRange`. Falls
    /// back to the last block if `referenceDate` somehow lands exactly on the month boundary
    /// (should not happen in practice, since block 4's `end` is exclusive and equals the next
    /// month's `start`, matching every other `DateInterval` in this file).
    static func currentFourWeekBlock(referenceDate: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let month = monthRangeContaining(referenceDate, calendar: calendar)
        let blocks = fourWeekBlocks(in: month, calendar: calendar)
        return blocks.first { $0.contains(referenceDate) } ?? blocks.last ?? month
    }

    /// The weekday name a `fourWeekBlocks(in:)` block starts on — always the same as the 1st of
    /// the month's weekday, since every block after the first is exactly 7 days later (and 7 days
    /// later always lands on the same weekday). e.g. "Saturday" for a month whose 1st is a
    /// Saturday. Used by the "(Starts on: ...)" label under each Week-by-Week row.
    static func fourWeekBlockStartWeekdayName(for block: DateInterval, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "EEEE"
        return formatter.string(from: block.start)
    }
}
