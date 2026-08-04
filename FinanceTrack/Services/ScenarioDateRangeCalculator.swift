import Foundation

/// Custom Date Range analysis for the Scenario Builder — "how much income/expense actually falls
/// within this specific start/end date." Genuinely NEW logic: investigation confirmed
/// `MonthlyPlanCalculator.estimatedMonthlyIncome`/`estimatedMonthlyFixedExpenses` only produce a
/// MONTHLY-EQUIVALENT total (a frequency-based conversion, e.g. weekly amount × 52 / 12) and never
/// count actual occurrence dates within an arbitrary range — there is no existing per-occurrence
/// recurrence engine anywhere in this codebase to reuse or duplicate. This type is deliberately the
/// ONLY place that logic lives (no second, competing date engine is introduced elsewhere).
///
/// NOT INCLUDED: Monthly Savings Goal. The real Monthly Savings Goal (and any Scenario override) is
/// defined and enforced strictly per calendar MONTH by `MonthlyPlanCalculator` — there is no
/// existing partial-range savings allocation rule anywhere in this app to reuse, and inventing a
/// proration formula here would not be "grounded in existing app behavior." Per this phase's own
/// explicit instruction ("stop and report the ambiguity before inventing one"), Date Range results
/// never include a savings figure — see this phase's final report.
enum ScenarioDateRangeCalculator {
    struct RangeTotals: Equatable {
        let income: Decimal
        let expenses: Decimal
        var extraSpending: Decimal { income - expenses }
    }

    /// Whether `frequency` is a case this engine can, in principle, count exactly.
    ///
    /// INCOME SCHEDULING PHASE: previously `.twiceMonthly` was blanket-unsupported here, because
    /// `IncomeSource`/`RecurringExpense` stored exactly ONE reference date and there was no "which
    /// two days of the month" field anywhere. That gap is now closed for income —
    /// `IncomeSource.twiceMonthlyFirstDeposit`/`twiceMonthlySecondDeposit` (via
    /// `ScenarioLineItem`) store BOTH configured deposit days explicitly, so `.twiceMonthly` is now
    /// a fully supported frequency at the engine level. Whether any GIVEN item's schedule is
    /// actually complete enough to use is a separate, per-item question — see
    /// `isItemSchedulable(_:)`, which `unsupportedItems(in:)` below now uses instead of this
    /// frequency-only check. (Bills/`RecurringExpense` do not yet carry the two-day fields — a
    /// `.twiceMonthly` bill remains excluded via `isItemSchedulable` until that's added, a
    /// deliberately out-of-scope follow-up per this phase's own report.)
    static func isFrequencySupported(_ frequency: PlanFrequency) -> Bool {
        true
    }

    /// Whether `item` has enough stored data for its own occurrences to be counted exactly — a
    /// PER-ITEM check, unlike `isFrequencySupported` (frequency-only, now always `true`).
    /// `.twiceMonthly` needs a COMPLETE schedule (both deposit days configured — see
    /// `ScenarioLineItem.isTwiceMonthlyScheduleComplete`; an old record with only a single legacy
    /// `referenceDate` and neither new day configured is NOT schedulable — nothing here ever
    /// fabricates its missing second date). `.monthly` is schedulable via either the new
    /// `monthlyDepositDay` or (for backward compatibility with bills and pre-this-phase income
    /// records) a plain `referenceDate`. Every other frequency needs `referenceDate`.
    static func isItemSchedulable(_ item: ScenarioLineItem) -> Bool {
        switch item.frequency {
        case .twiceMonthly:
            return item.isTwiceMonthlyScheduleComplete
        case .monthly:
            return item.monthlyDepositDay != nil || item.referenceDate != nil
        default:
            return item.referenceDate != nil
        }
    }

    /// Active items that cannot be counted exactly right now — see `isItemSchedulable(_:)`'s own
    /// header. The UI uses this to show a concise, honest disclosure (which items were excluded
    /// and, for Twice-Monthly, that it's an incomplete schedule needing completion) rather than
    /// silently omitting affected items with no explanation.
    static func unsupportedItems(in items: [ScenarioLineItem]) -> [ScenarioLineItem] {
        items.filter(\.isIncluded).filter { !isItemSchedulable($0) }
    }

    /// `start`/`end` are both INCLUSIVE calendar days — an occurrence landing on either boundary
    /// date counts. `start` must be on or before `end`; violating that returns zero totals rather
    /// than crashing (callers are expected to validate via `isValidRange` before calling, exactly
    /// like every other Scenario Builder amount-validation convention).
    static func totals(for items: [ScenarioLineItem], start: Date, end: Date, calendar: Calendar = .current) -> RangeTotals {
        guard isValidRange(start: start, end: end, calendar: calendar) else {
            return RangeTotals(income: 0, expenses: 0)
        }
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: end)) ?? end

        let included = items.filter(\.isIncluded)
        let income = included.filter { $0.ledger == .income }
            .reduce(Decimal(0)) { $0 + occurrenceTotal(for: $1, start: normalizedStart, end: normalizedEnd, calendar: calendar) }
        let expenses = included.filter { $0.ledger == .expense }
            .reduce(Decimal(0)) { $0 + occurrenceTotal(for: $1, start: normalizedStart, end: normalizedEnd, calendar: calendar) }
        return RangeTotals(income: income, expenses: expenses)
    }

    static func isValidRange(start: Date, end: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: start) <= calendar.startOfDay(for: end)
    }

    /// Every occurrence date of `item` within `[start, end]` (already-normalized, inclusive calendar
    /// days), multiplied by `item.amount`. An item that isn't schedulable (see
    /// `isItemSchedulable(_:)`) has no known occurrence dates at all — deliberately EXCLUDED
    /// (contributes 0) rather than guessed, matching this phase's "do not invent an allocation
    /// rule" principle applied to missing schedule data too.
    private static func occurrenceTotal(for item: ScenarioLineItem, start: Date, end: Date, calendar: Calendar) -> Decimal {
        let count = occurrenceCount(for: item, start: start, end: end, calendar: calendar)
        return item.amount * Decimal(count)
    }

    /// Occurrence count for a full `ScenarioLineItem`, using its own explicit deposit-schedule
    /// fields when present (`.monthly`'s `monthlyDepositDay`, `.twiceMonthly`'s two configured
    /// days — both resolved independently PER PERIOD via `MonthlyDepositDay.resolvedDate`, never by
    /// cumulative stepping from an already-clamped date, which would drift), falling back to the
    /// legacy anchor-based `occurrenceCount(anchor:frequency:...)` for `.weekly`/`.biweekly`/
    /// `.quarterly`/`.oneTime`, and for a `.monthly` item that predates this phase's explicit-day
    /// fields (including every bill — `RecurringExpense` doesn't carry them, unchanged this
    /// phase). `.yearly` always uses the new per-year resolution (fixes the same cumulative-drift
    /// risk for a Feb 29 anchor persisting into non-adjacent leap years). NOT private:
    /// `ScenarioCashFlowCalculator` calls this too, so Current/Scenario cash flow and Custom Date
    /// Range always agree on occurrence counts — the ONE scheduling engine, never a second,
    /// competing implementation.
    static func occurrenceCount(for item: ScenarioLineItem, start: Date, end: Date, calendar: Calendar = .current) -> Int {
        occurrenceDates(for: item, start: start, end: end, calendar: calendar).count
    }

    /// EXACT-DATES PHASE: every individual occurrence date of `item` within `[start, end]`
    /// (inclusive), sorted ascending — the single authoritative source `occurrenceCount(for:)`
    /// itself is now derived from (`.count`), so the two can never disagree, and cash-flow
    /// contributor explanations can list each real deposit date instead of only a summed total
    /// (see `ScenarioCashFlowCalculator.Contributor`'s own header — this task's explicit "use only
    /// the actual deposit occurrences" rule applies to what's DISPLAYED, not only what's totaled).
    static func occurrenceDates(for item: ScenarioLineItem, start: Date, end: Date, calendar: Calendar = .current) -> [Date] {
        guard isItemSchedulable(item) else { return [] }
        switch item.frequency {
        case .monthly:
            let depositDay = item.monthlyDepositDay
                ?? item.referenceDate.map { MonthlyDepositDay.numericDay(calendar.component(.day, from: $0)) }
            guard let depositDay else { return [] }
            return monthlyDepositDayDates(depositDay, start: start, end: end, calendar: calendar)
        case .yearly:
            guard let anchor = item.referenceDate else { return [] }
            return yearlyDates(anchorDay: calendar.startOfDay(for: anchor), start: start, end: end, calendar: calendar)
        case .twiceMonthly:
            guard let first = item.twiceMonthlyFirstDeposit, let second = item.twiceMonthlySecondDeposit else { return [] }
            return twiceMonthlyDates(first: first, second: second, start: start, end: end, calendar: calendar)
        case .oneTime:
            guard let anchor = item.referenceDate else { return [] }
            let anchorDay = calendar.startOfDay(for: anchor)
            return (anchorDay >= start && anchorDay <= end) ? [anchorDay] : []
        case .weekly:
            guard let anchor = item.referenceDate else { return [] }
            return steppedDates(anchorDay: calendar.startOfDay(for: anchor), stepDays: 7, start: start, end: end, calendar: calendar)
        case .biweekly:
            guard let anchor = item.referenceDate else { return [] }
            return steppedDates(anchorDay: calendar.startOfDay(for: anchor), stepDays: 14, start: start, end: end, calendar: calendar)
        case .quarterly:
            guard let anchor = item.referenceDate else { return [] }
            return steppedMonthDates(anchorDay: calendar.startOfDay(for: anchor), monthStep: 3, start: start, end: end, calendar: calendar)
        }
    }

    /// Number of times a recurring item anchored at `anchor` (its real `nextPayDate`/`dueDate`)
    /// lands within `[start, end]` inclusive. Each frequency steps forward AND backward from the
    /// anchor by its own fixed interval so an anchor date outside the range still correctly yields
    /// in-range occurrences; a hard iteration cap prevents runaway loops on pathological input
    /// (never reachable for any realistic range this UI offers).
    static func occurrenceCount(anchor: Date, frequency: PlanFrequency, start: Date, end: Date, calendar: Calendar = .current) -> Int {
        let anchorDay = calendar.startOfDay(for: anchor)

        switch frequency {
        case .oneTime:
            return (anchorDay >= start && anchorDay <= end) ? 1 : 0
        case .weekly:
            return countStepped(anchorDay: anchorDay, stepDays: 7, start: start, end: end, calendar: calendar)
        case .biweekly:
            return countStepped(anchorDay: anchorDay, stepDays: 14, start: start, end: end, calendar: calendar)
        case .monthly:
            return countSteppedMonths(anchorDay: anchorDay, monthStep: 1, start: start, end: end, calendar: calendar)
        case .quarterly:
            return countSteppedMonths(anchorDay: anchorDay, monthStep: 3, start: start, end: end, calendar: calendar)
        case .yearly:
            return countSteppedMonths(anchorDay: anchorDay, monthStep: 12, start: start, end: end, calendar: calendar)
        case .twiceMonthly:
            // Unsupported — see `isFrequencySupported`'s own header. Always 0, never an estimate.
            return 0
        }
    }

    private static let maxSteps = 10_000

    /// Fixed-day-count recurrence (weekly/biweekly): walk from `anchorDay` in both directions in
    /// `stepDays` increments, counting every landing date inside `[start, end]`.
    private static func countStepped(anchorDay: Date, stepDays: Int, start: Date, end: Date, calendar: Calendar) -> Int {
        steppedDates(anchorDay: anchorDay, stepDays: stepDays, start: start, end: end, calendar: calendar).count
    }

    /// EXACT-DATES PHASE: the date-returning form of `countStepped` — the count is derived from
    /// this, never the other way around.
    private static func steppedDates(anchorDay: Date, stepDays: Int, start: Date, end: Date, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        if anchorDay >= start && anchorDay <= end { dates.append(anchorDay) }

        var forward = anchorDay
        var steps = 0
        while let next = calendar.date(byAdding: .day, value: stepDays, to: forward), next <= end, steps < maxSteps {
            if next >= start { dates.append(next) }
            forward = next
            steps += 1
        }

        var backward = anchorDay
        steps = 0
        while let previous = calendar.date(byAdding: .day, value: -stepDays, to: backward), previous >= start, steps < maxSteps {
            if previous <= end { dates.append(previous) }
            backward = previous
            steps += 1
        }
        return dates.sorted()
    }

    /// Calendar-month-step recurrence (quarterly, and the legacy `.monthly` anchor fallback): steps
    /// by whole months so the day-of-month tracks the anchor (clamped by
    /// `Calendar.date(byAdding:)`'s own standard short-month/leap-year clamping, e.g. Jan 31
    /// monthly → Feb 28/29), never a fixed day count.
    private static func countSteppedMonths(anchorDay: Date, monthStep: Int, start: Date, end: Date, calendar: Calendar) -> Int {
        steppedMonthDates(anchorDay: anchorDay, monthStep: monthStep, start: start, end: end, calendar: calendar).count
    }

    /// EXACT-DATES PHASE: the date-returning form of `countSteppedMonths`.
    private static func steppedMonthDates(anchorDay: Date, monthStep: Int, start: Date, end: Date, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        if anchorDay >= start && anchorDay <= end { dates.append(anchorDay) }

        var forward = anchorDay
        var steps = 0
        while let next = calendar.date(byAdding: .month, value: monthStep, to: forward), next <= end, steps < maxSteps {
            if next >= start { dates.append(next) }
            forward = next
            steps += 1
        }

        var backward = anchorDay
        steps = 0
        while let previous = calendar.date(byAdding: .month, value: -monthStep, to: backward), previous >= start, steps < maxSteps {
            if previous <= end { dates.append(previous) }
            backward = previous
            steps += 1
        }
        return dates.sorted()
    }

    // MARK: - INCOME SCHEDULING PHASE: per-period-independent day resolution

    /// Every "start of month" date overlapping `[start, end]` — used to resolve a day-of-month
    /// deposit rule independently for EACH month it applies to, never by cumulative stepping from
    /// an already-clamped date (which would drift: e.g. Jan 31 → Feb 28 (clamped) → naively +1
    /// month from THAT gives Mar 28, not Mar 31 — this walks the actual calendar months instead).
    private static func monthStarts(overlapping start: Date, end: Date, calendar: Calendar) -> [Date] {
        guard var cursor = calendar.dateInterval(of: .month, for: start)?.start,
              let endMonthStart = calendar.dateInterval(of: .month, for: end)?.start else { return [] }
        var result: [Date] = []
        var steps = 0
        while cursor <= endMonthStart, steps < maxSteps {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
            steps += 1
        }
        return result
    }

    /// The per-year analogue of `monthStarts` — every Jan 1 overlapping `[start, end]`.
    private static func yearStarts(overlapping start: Date, end: Date, calendar: Calendar) -> [Date] {
        guard var cursor = calendar.dateInterval(of: .year, for: start)?.start,
              let endYearStart = calendar.dateInterval(of: .year, for: end)?.start else { return [] }
        var result: [Date] = []
        var steps = 0
        while cursor <= endYearStart, steps < maxSteps {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .year, value: 1, to: cursor) else { break }
            cursor = next
            steps += 1
        }
        return result
    }

    /// One occurrence per calendar month in `[start, end]`, at `depositDay` (a numeric day —
    /// clamped independently per month for short months — or Last Day).
    private static func monthlyDepositDayDates(_ depositDay: MonthlyDepositDay, start: Date, end: Date, calendar: Calendar) -> [Date] {
        monthStarts(overlapping: start, end: end, calendar: calendar)
            .map { depositDay.resolvedDate(inMonthContaining: $0, calendar: calendar) }
            .filter { $0 >= start && $0 <= end }
            .sorted()
    }

    /// One occurrence per calendar YEAR in `[start, end]`, at the anchor's month/day — resolved
    /// independently for every year (a Feb 29 anchor clamps to Feb 28 in a non-leap target year,
    /// computed fresh for that year, never inherited from a previous year's clamped result, so a
    /// later leap year correctly shows Feb 29 again).
    private static func yearlyDates(anchorDay: Date, start: Date, end: Date, calendar: Calendar) -> [Date] {
        let anchorMonth = calendar.component(.month, from: anchorDay)
        let anchorDayOfMonth = calendar.component(.day, from: anchorDay)
        return yearStarts(overlapping: start, end: end, calendar: calendar)
            .compactMap { yearStart -> Date? in
                var components = calendar.dateComponents([.year], from: yearStart)
                components.month = anchorMonth
                components.day = 1
                guard let monthStart = calendar.date(from: components) else { return nil }
                return MonthlyDepositDay.numericDay(anchorDayOfMonth).resolvedDate(inMonthContaining: monthStart, calendar: calendar)
            }
            .filter { $0 >= start && $0 <= end }
            .sorted()
    }

    /// Twice-Monthly occurrences: `first`/`second` resolved independently for every month in
    /// `[start, end]`. DUPLICATE-OCCURRENCE RULE: when both configured rules clamp to the SAME
    /// calendar date in a given month (e.g. numeric days 30 and 31 both clamping to Feb 28), that
    /// month contributes exactly ONE occurrence, not two — `Set` naturally implements this; both
    /// configured rules remain independently in effect for any other month where they resolve to
    /// different dates.
    private static func twiceMonthlyDates(first: MonthlyDepositDay, second: MonthlyDepositDay, start: Date, end: Date, calendar: Calendar) -> [Date] {
        monthStarts(overlapping: start, end: end, calendar: calendar).flatMap { monthStart -> [Date] in
            let datesThisMonth: Set<Date> = [
                first.resolvedDate(inMonthContaining: monthStart, calendar: calendar),
                second.resolvedDate(inMonthContaining: monthStart, calendar: calendar)
            ]
            return datesThisMonth.filter { $0 >= start && $0 <= end }
        }.sorted()
    }
}
