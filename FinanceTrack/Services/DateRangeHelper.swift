import Foundation

/// Computes the week/month date ranges used throughout the app (dashboard totals, reports).
/// This is the single source of truth for "what is the current week/month" — `BudgetCalculator`
/// takes the resulting `DateInterval` as input rather than computing its own.
enum DateRangeHelper {

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
    /// walked from its start to its end. Shared by the Monthly Summary and Monthly Plan screens
    /// so both agree on what "the weeks in this month" means.
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
}
