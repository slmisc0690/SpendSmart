import Foundation

/// INCOME SCHEDULING PHASE: a single "which day within a month" deposit rule — either a specific
/// numeric day (1...31) or the month's own Last Day. Used for Monthly income (one day) and
/// Twice-Monthly income (two days, `first`/`second` on `IncomeSource`). Deliberately a plain,
/// in-memory value type — NOT stored directly on `IncomeSource`/`ScenarioLineItem` (see those
/// types' own headers for why: stable, proven-safe SwiftData primitives are persisted instead,
/// e.g. `IncomeSource.twiceMonthlyFirstDayNumber: Int?` + `.twiceMonthlyFirstDayIsLastDay: Bool`);
/// this type is the single place that pair of primitives is interpreted and resolved to an actual
/// calendar date.
enum MonthlyDepositDay: Equatable, Hashable, Sendable {
    /// 1...31 — a day beyond the target month's real length clamps to that month's last day (see
    /// `resolvedDate(inMonthContaining:calendar:)`), never rolling into the next month.
    case numericDay(Int)
    /// The month's own actual final calendar day — resolved independently for every month/year it
    /// applies to (never derived by repeatedly stepping from an already-clamped date, which would
    /// drift: e.g. Jan 31 → clamp to Feb 28 → naively +1 month from THAT gives Mar 28, not Mar 31).
    case lastDayOfMonth

    /// Builds a `MonthlyDepositDay?` from the two raw SwiftData-persisted primitives — `nil` when
    /// neither is set (the "not yet configured" / incomplete-schedule state; see
    /// `IncomeSource.isTwiceMonthlyScheduleComplete`). `isLastDay` wins if somehow both are set.
    static func from(dayNumber: Int?, isLastDay: Bool) -> MonthlyDepositDay? {
        if isLastDay { return .lastDayOfMonth }
        if let dayNumber { return .numericDay(dayNumber) }
        return nil
    }

    /// Resolves this rule to an actual `Date` within the calendar month containing
    /// `referenceDate` (any date inside that month — typically that month's own 1st, from a
    /// month-walking loop). A numeric day beyond the month's real length (e.g. 31 in February)
    /// clamps to that month's last day — the approved short-month rule; `.lastDayOfMonth` always
    /// resolves to that month's true final calendar day.
    func resolvedDate(inMonthContaining referenceDate: Date, calendar: Calendar = .current) -> Date {
        guard let monthInterval = calendar.dateInterval(of: .month, for: referenceDate) else { return referenceDate }
        switch self {
        case .lastDayOfMonth:
            return calendar.date(byAdding: .day, value: -1, to: monthInterval.end) ?? referenceDate
        case .numericDay(let requestedDay):
            let daysInMonth = calendar.range(of: .day, in: .month, for: referenceDate)?.count ?? 28
            let clampedDay = min(max(requestedDay, 1), daysInMonth)
            var components = calendar.dateComponents([.year, .month], from: monthInterval.start)
            components.day = clampedDay
            return calendar.date(from: components) ?? referenceDate
        }
    }

    /// Short, human-readable label for Monthly Plan presentation and Add/Edit Income, e.g. "15th"
    /// or "Last day".
    var displayLabel: String {
        switch self {
        case .lastDayOfMonth: return "Last day"
        case .numericDay(let day): return day.ordinalString
        }
    }
}

private extension Int {
    var ordinalString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

/// SCHEDULE UX PHASE: the approved, user-friendly preset options for configuring a
/// `MonthlyDepositDay` in Add/Edit Income (Monthly's one selector, Twice a Month's two selectors —
/// see `AddEditIncomeSourceView`). Deliberately only ONE "end of the month" concept —
/// `.lastDayOfMonth` — never a second, separately-labeled "End of Month" synonym that would
/// resolve identically and confuse users about whether they differ (this phase's own explicit
/// investigation finding).
enum MonthlyDepositDayPreset: String, CaseIterable, Identifiable {
    case beginningOfMonth
    case midMonth
    case lastDayOfMonth
    case chooseADay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beginningOfMonth: return "Beginning of Month"
        case .midMonth: return "Mid-Month"
        case .lastDayOfMonth: return "Last Day of Month"
        case .chooseADay: return "Choose a Day"
        }
    }

    /// The preset that represents `day` — `.chooseADay` for `nil` (not yet configured) or any
    /// numeric day other than 1/15 (never a spurious match: a genuinely custom day like the 7th
    /// must show as "Choose a Day," not silently snap to a nearby preset).
    static func matching(_ day: MonthlyDepositDay?) -> MonthlyDepositDayPreset {
        switch day {
        case .numericDay(1): return .beginningOfMonth
        case .numericDay(15): return .midMonth
        case .lastDayOfMonth: return .lastDayOfMonth
        case .numericDay, nil: return .chooseADay
        }
    }

    /// The resolved day this preset represents — `nil` for `.chooseADay`, since that preset alone
    /// carries no specific day (the caller supplies its own numeric value).
    var resolvedDay: MonthlyDepositDay? {
        switch self {
        case .beginningOfMonth: return .numericDay(1)
        case .midMonth: return .numericDay(15)
        case .lastDayOfMonth: return .lastDayOfMonth
        case .chooseADay: return nil
        }
    }
}
