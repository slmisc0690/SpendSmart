import Foundation

/// CORRECTIVE PHASE — replaces the Scenario Builder's prior "Extra Spending After Mid-Month/
/// End-of-Month Bills" figures (`ScenarioSummaryBuilder.extraSpendingThroughCutoff`, left in place
/// but no longer displayed — see `MonthlyPlanScenarioView`'s own header) with genuine cumulative
/// cash-flow-through-a-date math.
///
/// ROOT CAUSE of the incorrect $8,023/$9,023-style figures physical-device testing found: the old
/// formula filtered items by their user-assigned `PlanTiming` LABEL (a purely descriptive bucket —
/// see `PlanTiming`'s own header, "purely descriptive for now... not this enum" for date math),
/// then summed each eligible item's FULL MONTHLY-EQUIVALENT amount via
/// `MonthlyPlanCalculator.monthlyAmount` (e.g. a biweekly paycheck × 26 / 12) — never how many of
/// that paycheck's ACTUAL occurrences had happened by the cutoff date. A single biweekly income
/// tagged `.beginningMonth` contributed its full annualized-monthly average every time, regardless
/// of the cutoff, which is why Mid-Month showed a number far larger than "the paychecks that have
/// actually arrived by the 15th."
///
/// THE FIX: reuse `ScenarioDateRangeCalculator.occurrenceCount`/`isFrequencySupported` — the
/// existing, already-tested, per-occurrence recurrence engine built for Custom Date Range (Phase
/// 4) — completely UNMODIFIED. That engine counts real occurrences of a recurring item between two
/// dates, anchored at the item's own stored `referenceDate` (`IncomeSource.nextPayDate`/
/// `RecurringExpense.dueDate`). Applying it to `[month.start, cutoff]` for Mid-Month and
/// `[month.start, last day of month]` for End-Month is genuine cumulative cash flow, not a
/// monthly-average estimate.
///
/// CUTOFF DEFINITIONS (investigation finding — see this phase's final report): `PlanTiming` and the
/// wider data model carry NO stored numeric date for what "Mid-Month" or "End-of-Month" mean as a
/// period boundary — that concept exists nowhere in the schema. Mid-Month is defined here as the
/// 15th of the target month (inclusive) — the standard, unambiguous meaning of the term, and
/// consistent with the worked example in this phase's own brief (two paychecks arriving by the
/// 15th). End-of-Month is the last calendar day of the month — already how the Scenario Builder's
/// existing `.endMonth` Extra Spending row was defined (routed directly to
/// `flexibleSpendingAvailable`, the whole-month figure). This is a global PERIOD BOUNDARY decision,
/// not a per-item guess about when a specific income/bill lands — every item's own occurrence dates
/// still come exclusively from its own stored `referenceDate`, never invented.
///
/// WHAT'S EXCLUDED, AND WHY (never guessed): an item with no stored `referenceDate`, or with
/// `.twiceMonthly` frequency (no second stored date anywhere in this schema — see
/// `ScenarioDateRangeCalculator.isFrequencySupported`'s own header), contributes $0 here rather
/// than an invented figure — exactly the same "exclude, don't guess" rule Custom Date Range already
/// established. `excludedItems(in:)` lets the UI disclose exactly what was left out, so a user can
/// always see why a total is smaller than expected instead of it silently being wrong.
enum ScenarioCashFlowCalculator {
    /// One named contributor (an income source or a bill) and the amount it actually contributed
    /// through the cutoff — never a monthly-equivalent estimate. EXACT-DATES PHASE: one
    /// `Contributor` per actual occurrence date, not one aggregated row per item — an item with two
    /// occurrences in range (e.g. a biweekly paycheck landing twice before a cutoff) produces two
    /// separate `Contributor`s, each with its own real date and the item's per-deposit `amount`
    /// (never a summed total), so info explanations can list "Scott Paycheck — Aug 7 — $2,000" and
    /// "Scott Paycheck — Aug 21 — $2,000" as distinct lines. `totalIncome`/`totalBills` summing over
    /// every contributor is unaffected by this — the total was always occurrences × amount either
    /// way.
    struct Contributor: Identifiable {
        let name: String
        let date: Date
        let amount: Decimal
        var id: String { "\(name)|\(date.timeIntervalSince1970)" }
    }

    /// A full cash-flow breakdown through one cutoff date. `savingsAllocated` is `nil` when there is
    /// no established rule for this cutoff (Mid-Month — see this phase's final report on why no
    /// partial-month savings proration is invented) and non-nil (possibly zero) when there is one
    /// (End-Month — the full, un-prorated Monthly Savings Goal, the same established rule
    /// `flexibleSpendingAvailable` already uses for the whole month).
    struct Breakdown {
        let incomeContributors: [Contributor]
        let billContributors: [Contributor]
        let savingsAllocated: Decimal?

        var totalIncome: Decimal { incomeContributors.reduce(0) { $0 + $1.amount } }
        var totalBills: Decimal { billContributors.reduce(0) { $0 + $1.amount } }
        var remaining: Decimal { totalIncome - totalBills - (savingsAllocated ?? 0) }
    }

    /// Mid-Month cutoff = the 15th of `month` (inclusive) — see this type's own header for why.
    static func midMonthCutoff(for month: DateInterval, calendar: Calendar = .current) -> Date {
        calendar.date(bySetting: .day, value: 15, of: month.start) ?? month.start
    }

    /// End-of-Month cutoff = the last calendar day of `month` (inclusive) — `month.end` itself is
    /// exclusive (the instant the next month begins), so this steps back one day.
    static func endMonthCutoff(for month: DateInterval, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.end
    }

    /// Cumulative cash flow from the start of `month` through `midMonthCutoff(for:)` — no savings
    /// allocation (no established partial-month rule; see this type's own header).
    static func midMonthCashFlow(items: [ScenarioLineItem], month: DateInterval, calendar: Calendar = .current) -> Breakdown {
        breakdown(items: items, start: month.start, end: midMonthCutoff(for: month, calendar: calendar), savingsAllocated: nil, calendar: calendar)
    }

    /// Cumulative cash flow from the start of `month` through `endMonthCutoff(for:)` — the full
    /// Monthly Savings Goal is allocated, matching the established whole-month rule.
    static func endMonthCashFlow(items: [ScenarioLineItem], month: DateInterval, planSettings: MonthlyPlanSettings?, calendar: Calendar = .current) -> Breakdown {
        let savingsGoal = planSettings?.monthlySavingsGoal ?? 0
        return breakdown(items: items, start: month.start, end: endMonthCutoff(for: month, calendar: calendar), savingsAllocated: savingsGoal, calendar: calendar)
    }

    // MARK: - MONTHLY OUTLOOK + SCENARIO PERIOD-CASH-FLOW CORRECTION — period-only cards
    //
    // ROOT CAUSE this section corrects: the End-of-Month CARD was displaying `endMonthCashFlow`
    // above — CUMULATIVE from `month.start`, which includes every Mid-Month income/bill a second
    // time. Physical-device evidence: End-of-Month showed the full $10,400 monthly income (Scott
    // + Lisa's FIRST deposits counted again, on top of their second deposits and VA) and $6,211 in
    // cumulative bills (Beginning + Mid-Month + End-of-Month bill groups all summed together)
    // instead of the End-of-Month PERIOD alone ($6,500 income; $4,282 bills — the End-of-Month
    // Bill Group only).
    //
    // TWO DISTINCT FIXES, one per Locked Product Definition:
    // - INCOME uses exact occurrence dates as before (never monthly-equivalent, never invented),
    //   but the End-of-Month period's date range now EXCLUDES the Mid-Month range
    //   (`(midMonthCutoff, endMonthCutoff]` instead of `[month.start, endMonthCutoff]`), so a
    //   deposit already counted in the Mid-Month period is never counted again here.
    // - BILLS use the Bill Group (`PlanTiming`) directly — the same raw-sum convention
    //   `FixedBillsTimingFilter.displayedTotal(for:)` established for the Fixed Bills screen —
    //   never date-occurrence counting for this card. A bill's own `timing` already unambiguously
    //   places it in exactly one of Beginning/Mid-Month/End-of-Month/Weekly/Custom-Date; summing
    //   by that label, once, is the "exact Mid-Month/End-of-Month bill group" this phase requires
    //   (matching the corrected exact fixtures: $1,989 Mid-Month, $4,282 End-of-Month).
    //
    // The prior `midMonthCashFlow`/`endMonthCashFlow` above are UNCHANGED and remain available for
    // any genuinely cumulative/full-month use — they are simply no longer what the Mid-Month/
    // End-of-Month PERIOD cards display.

    /// Mid-Month PERIOD cash flow — income by exact occurrence date within `[month.start,
    /// midMonthCutoff]` (identical date range to the old cumulative function, since there is no
    /// period before Mid-Month to double-count), bills by the Mid-Month Bill Group (never
    /// date-occurrence). No savings allocation (Part 7: no established Mid-Month partial rule).
    static func midMonthPeriodCashFlow(items: [ScenarioLineItem], month: DateInterval, calendar: Calendar = .current) -> Breakdown {
        periodBreakdown(items: items, incomeStart: month.start, incomeEnd: midMonthCutoff(for: month, calendar: calendar), billTiming: .midMonth, savingsAllocated: nil, calendar: calendar)
    }

    /// End-of-Month PERIOD cash flow — income by exact occurrence date within `(midMonthCutoff,
    /// endMonthCutoff]` ONLY (excludes the Mid-Month range, correcting the prior cumulative-from-
    /// month-start defect), bills by the End-of-Month Bill Group (never cumulative bills-through-
    /// cutoff).
    ///
    /// SCENARIO MONTHLY PLANNING CORRECTION — the Monthly Savings Goal is NO LONGER allocated
    /// inside this period's `remaining` (a prior phase subtracted the FULL, un-prorated goal here,
    /// which was ruled incorrect: the goal is a MONTHLY planning concept, not something that
    /// belongs to only one of the two periods — see `MonthlyPlanScenarioViewModel`'s
    /// `currentAvailableAfterPlannedSavings`/`scenarioAvailableAfterPlannedSavings`, which apply the
    /// goal once, at the monthly level, against `Mid-Month Remaining + End-of-Month Remaining`
    /// combined). `planSettings` is retained in the signature only for call-site symmetry with
    /// `midMonthPeriodCashFlow`; it is no longer read here.
    static func endMonthPeriodCashFlow(items: [ScenarioLineItem], month: DateInterval, planSettings: MonthlyPlanSettings?, calendar: Calendar = .current) -> Breakdown {
        let periodStart = calendar.date(byAdding: .day, value: 1, to: midMonthCutoff(for: month, calendar: calendar)) ?? month.start
        return periodBreakdown(items: items, incomeStart: periodStart, incomeEnd: endMonthCutoff(for: month, calendar: calendar), billTiming: .endMonth, savingsAllocated: nil, calendar: calendar)
    }

    private static func periodBreakdown(items: [ScenarioLineItem], incomeStart: Date, incomeEnd: Date, billTiming: PlanTiming, savingsAllocated: Decimal?, calendar: Calendar) -> Breakdown {
        let normalizedStart = calendar.startOfDay(for: incomeStart)
        let normalizedEnd = calendar.startOfDay(for: incomeEnd)
        let included = items.filter(\.isIncluded)

        let incomeContributors = included
            .filter { $0.ledger == .income }
            .flatMap { contributors(for: $0, start: normalizedStart, end: normalizedEnd, calendar: calendar) }
            .sorted { $0.date < $1.date }

        // Bill Group membership, not date-occurrence — see this section's own header. Each bill
        // contributes its own raw amount exactly once (`FixedBillsTimingFilter.displayAmount`'s
        // own convention), for every ACTIVE, included bill whose `timing` matches `billTiming`.
        let billContributors = included
            .filter { $0.ledger == .expense && $0.timing == billTiming }
            .map { Contributor(name: $0.name, date: $0.referenceDate ?? normalizedEnd, amount: $0.amount) }
            .sorted { $0.date < $1.date }

        return Breakdown(incomeContributors: incomeContributors, billContributors: billContributors, savingsAllocated: savingsAllocated)
    }

    /// Active items excluded from cash-flow totals — no usable stored schedule (see
    /// `ScenarioDateRangeCalculator.isItemSchedulable(_:)` — e.g. a Twice-Monthly item whose
    /// second deposit day was never configured) — surfaced so the UI can disclose exactly what
    /// wasn't counted, same pattern as `ScenarioDateRangeCalculator.unsupportedItems(in:)`.
    static func excludedItems(in items: [ScenarioLineItem]) -> [ScenarioLineItem] {
        items.filter(\.isIncluded).filter { !isEligible($0) }
    }

    private static func isEligible(_ item: ScenarioLineItem) -> Bool {
        ScenarioDateRangeCalculator.isItemSchedulable(item)
    }

    private static func breakdown(items: [ScenarioLineItem], start: Date, end: Date, savingsAllocated: Decimal?, calendar: Calendar) -> Breakdown {
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.startOfDay(for: end)
        let included = items.filter(\.isIncluded)

        let incomeContributors = included
            .filter { $0.ledger == .income }
            .flatMap { contributors(for: $0, start: normalizedStart, end: normalizedEnd, calendar: calendar) }
            .sorted { $0.date < $1.date }
        let billContributors = included
            .filter { $0.ledger == .expense }
            .flatMap { contributors(for: $0, start: normalizedStart, end: normalizedEnd, calendar: calendar) }
            .sorted { $0.date < $1.date }

        return Breakdown(incomeContributors: incomeContributors, billContributors: billContributors, savingsAllocated: savingsAllocated)
    }

    /// Empty (never a zero-amount row) when the item is excluded (see `isEligible`) or genuinely
    /// had zero occurrences through `end` — either way, nothing to list for that item. Routes
    /// through `ScenarioDateRangeCalculator.occurrenceDates(for:start:end:calendar:)` — the ONE
    /// scheduling engine — so Cash Flow and Custom Date Range can never disagree about how many
    /// times, or on what dates, an item actually occurred. One `Contributor` per date (see this
    /// type's own header on why aggregating occurrences into one row would hide the exact deposit
    /// dates this task requires).
    private static func contributors(for item: ScenarioLineItem, start: Date, end: Date, calendar: Calendar) -> [Contributor] {
        guard isEligible(item) else { return [] }
        return ScenarioDateRangeCalculator.occurrenceDates(for: item, start: start, end: end, calendar: calendar)
            .map { Contributor(name: item.name, date: $0, amount: item.amount) }
    }
}
