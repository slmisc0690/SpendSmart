import Foundation

/// A single line item inside the Scenario Builder — the ONE unified representation future phases'
/// Add/Remove/Change actions will operate on, replacing the prior design's two separate, parallel
/// income/expense item types. A plain, `Sendable` value type: never a SwiftData `@Model`, never
/// holds or requires a `ModelContext`, and is never inserted into any persistent store — the same
/// non-persistence guarantee the Scenario feature has always had, now expressed by construction
/// (there is no initializer or method anywhere in this type that accepts a store to write to).
struct ScenarioLineItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var amount: Decimal
    var frequency: PlanFrequency
    var timing: PlanTiming
    /// "Next pay date" for an income item, "due date" for an expense item — both are the same
    /// structural concept (an optional reference date `MonthlyPlanCalculator` uses for `.oneTime`
    /// items), so this unifies `IncomeSource.nextPayDate`/`RecurringExpense.dueDate` into one field.
    var referenceDate: Date?
    var isIncluded: Bool
    var isHypothetical: Bool
    let ledger: ScenarioLedger

    /// INCOME SCHEDULING PHASE (new, additive, defaulted so every existing call site across this
    /// codebase's tests/factories keeps compiling unchanged) — mirrors
    /// `IncomeSource.monthlyDepositDay`/`twiceMonthlyFirstDeposit`/`twiceMonthlySecondDeposit`.
    /// `nil` for anything that isn't the matching frequency, or for a not-yet-configured
    /// Twice-Monthly record (see `isTwiceMonthlyScheduleComplete`). Currently populated only for
    /// `.income` items (see `ScenarioLineItemFactory.baseline`) — bills keep their existing
    /// `timing`/`referenceDate` model, unchanged this phase.
    var monthlyDepositDay: MonthlyDepositDay? = nil
    var twiceMonthlyFirstDeposit: MonthlyDepositDay? = nil
    var twiceMonthlySecondDeposit: MonthlyDepositDay? = nil

    /// `.income` for every income item regardless of its own `timing` — see `ScenarioCategory`'s
    /// own header for why Income is one Builder category independent of when in the month it
    /// lands. For an expense item, derived from `timing`; `nil` if `timing` doesn't map to a named
    /// Builder category yet.
    var category: ScenarioCategory? {
        switch ledger {
        case .income: return .income
        case .expense: return ScenarioCategory.forExpense(timing: timing)
        }
    }

    /// `true` for any frequency other than `.twiceMonthly`. For `.twiceMonthly`, `true` only once
    /// BOTH deposit days are configured — mirrors `IncomeSource.isTwiceMonthlyScheduleComplete`.
    var isTwiceMonthlyScheduleComplete: Bool {
        guard frequency == .twiceMonthly else { return true }
        return twiceMonthlyFirstDeposit != nil && twiceMonthlySecondDeposit != nil
    }
}

/// Builds the Scenario Builder's starting state from the user's REAL, active Monthly Plan data —
/// the ONLY place this architecture ever reads real `IncomeSource`/`RecurringExpense` rows. The
/// resulting `[ScenarioLineItem]` is a snapshot, copied by value; nothing here keeps a reference
/// back to the source SwiftData objects, so later mutating a `ScenarioLineItem` can never write
/// through to the real Monthly Plan.
enum ScenarioLineItemFactory {
    static func baseline(incomeSources: [IncomeSource], recurringExpenses: [RecurringExpense]) -> [ScenarioLineItem] {
        let income = incomeSources.filter(\.isActive).map { source in
            ScenarioLineItem(
                id: source.id,
                name: source.name,
                amount: source.amount,
                frequency: source.frequency,
                timing: source.timing,
                referenceDate: source.nextPayDate,
                isIncluded: true,
                isHypothetical: false,
                ledger: .income,
                monthlyDepositDay: source.monthlyDepositDay,
                twiceMonthlyFirstDeposit: source.twiceMonthlyFirstDeposit,
                twiceMonthlySecondDeposit: source.twiceMonthlySecondDeposit
            )
        }
        let expenses = recurringExpenses.filter(\.isActive).map { expense in
            ScenarioLineItem(
                id: expense.id,
                name: expense.name,
                amount: expense.amount,
                frequency: expense.frequency,
                timing: expense.timing,
                referenceDate: expense.dueDate,
                isIncluded: true,
                isHypothetical: false,
                ledger: .expense
            )
        }
        return income + expenses
    }
}

/// Bridges `[ScenarioLineItem]` back to the existing, UNMODIFIED `MonthlyPlanCalculator` — the
/// same calculation engine the real Monthly Plan uses, called with the exact same signature.
/// Builds transient `IncomeSource`/`RecurringExpense` instances purely to satisfy that signature;
/// they are never inserted into a `ModelContext` and are discarded the instant `summary(...)`
/// returns, exactly like the prior Scenario Mode implementation's own transient-object approach.
enum ScenarioSummaryBuilder {
    static func summary(
        for items: [ScenarioLineItem],
        month: DateInterval,
        planSettings: MonthlyPlanSettings?,
        weeklyBudgetLimit: Decimal,
        transactions: [FinanceTransaction],
        weekInterval: DateInterval,
        weekStartsOnSunday: Bool,
        includePending: Bool,
        warningThreshold: Double
    ) -> MonthlyPlanCalculator.Summary {
        let included = items.filter(\.isIncluded)

        let incomeSources = included.filter { $0.ledger == .income }.map { item in
            IncomeSource(
                id: item.id,
                name: item.name,
                amount: item.amount,
                frequency: item.frequency,
                timing: item.timing,
                nextPayDate: item.referenceDate,
                isActive: true
            )
        }
        let recurringExpenses = included.filter { $0.ledger == .expense }.map { item in
            RecurringExpense(
                id: item.id,
                name: item.name,
                amount: item.amount,
                frequency: item.frequency,
                timing: item.timing,
                dueDate: item.referenceDate,
                isActive: true
            )
        }

        return MonthlyPlanCalculator.summary(
            month: month,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: planSettings,
            weeklyBudgetLimit: weeklyBudgetLimit,
            transactions: transactions,
            weekInterval: weekInterval,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold
        )
    }

    /// income − expenses for one raw `PlanTiming` bucket, filtered across BOTH ledgers (income and
    /// expense items alike) — deliberately mirrors the prior Scenario implementation's own
    /// `TimingTotal` exactly (filter-by-`timing`, then the same two existing
    /// `MonthlyPlanCalculator.estimatedMonthlyIncome`/`estimatedMonthlyFixedExpenses` functions),
    /// so the Mid-Month/End-of-Month Total figures shown in the Scenario Builder's Results section
    /// are byte-for-byte unchanged by the Phase 2 category/ledger model — they are NOT computed
    /// from `ScenarioCategory` (which only income-vs-expense-buckets by a different, narrower
    /// rule; see `ScenarioLineItem.category`'s own header).
    static func timingTotal(for items: [ScenarioLineItem], timing: PlanTiming, month: DateInterval) -> ScenarioTimingTotal {
        let matching = items.filter(\.isIncluded).filter { $0.timing == timing }
        let incomeSources = matching.filter { $0.ledger == .income }.map { item in
            IncomeSource(id: item.id, name: item.name, amount: item.amount, frequency: item.frequency, timing: item.timing, nextPayDate: item.referenceDate, isActive: true)
        }
        let recurringExpenses = matching.filter { $0.ledger == .expense }.map { item in
            RecurringExpense(id: item.id, name: item.name, amount: item.amount, frequency: item.frequency, timing: item.timing, dueDate: item.referenceDate, isActive: true)
        }
        return ScenarioTimingTotal(
            income: MonthlyPlanCalculator.estimatedMonthlyIncome(incomeSources, in: month),
            expenses: MonthlyPlanCalculator.estimatedMonthlyFixedExpenses(recurringExpenses, in: month)
        )
    }

    /// PHASE 7 — Part 4: which items feed "Extra Spending After [cutoff] Bills" — used only to
    /// power the Results row's plain-English info explanation (`ScenarioSummaryText`), so the
    /// explanation can list which income/bills actually contributed. Read-only: reuses the exact
    /// same `cutoffOrdinal` eligibility rule `extraSpendingThroughCutoff` itself uses below, so the
    /// explanation can never drift from what the number actually includes. Does not change any
    /// existing calculation.
    static func itemsEligibleThroughCutoff(items: [ScenarioLineItem], cutoff: PlanTiming) -> [ScenarioLineItem] {
        guard let cutoffOrdinalValue = cutoffOrdinal(cutoff) else { return [] }
        return items.filter(\.isIncluded).filter { item in
            guard let itemOrdinal = cutoffOrdinal(item.timing) else { return false }
            return itemOrdinal <= cutoffOrdinalValue
        }
    }

    /// The month-ordinal position of a `PlanTiming` value — used ONLY to decide which items are
    /// "at or before" a cutoff for `extraSpendingThroughCutoff` below. `.weekly`/`.customDate` have
    /// no stored data placing them at any specific point in the month relative to Mid-Month/
    /// End-of-Month, so they deliberately have no ordinal at all (`nil`) rather than an invented one.
    private static func cutoffOrdinal(_ timing: PlanTiming) -> Int? {
        switch timing {
        case .beginningMonth: return 0
        case .midMonth: return 1
        case .endMonth: return 2
        case .weekly, .customDate: return nil
        }
    }

    /// "Extra Spending After [cutoff] Bills" — cash remaining after ONLY the income/bills whose own
    /// timing is at or before `cutoff` (Beginning ≤ Mid ≤ End), minus the full Monthly Savings Goal
    /// and buffer (never prorated — `MonthlyPlanCalculator.flexibleSpendingAvailable` itself never
    /// prorates either across the month, so applying the full, un-prorated amount at every cutoff is
    /// the only rule grounded in the calculator's own existing behavior; a partial-savings rule
    /// would be invented, not traced).
    ///
    /// CORRECTED FORMULA (this phase) — the prior `flexibleSpendingAvailable − timingExpenses`
    /// double-counted: `flexibleSpendingAvailable` already subtracts EVERY active bill for the
    /// whole month (via `estimatedMonthlyFixedExpenses` over ALL expenses), so subtracting a
    /// timing group's total a second time removed those bills twice. This function instead
    /// recomputes income/expenses from scratch over ONLY the eligible (at-or-before-cutoff) items,
    /// via the same unmodified `estimatedMonthlyIncome`/`estimatedMonthlyFixedExpenses` functions —
    /// no item is ever subtracted more than once.
    ///
    /// `.weekly`/`.customDate` items are excluded from every cutoff (no ordinal — see
    /// `cutoffOrdinal`). This means a mid-month-style cutoff for `.beginningMonth`/`.midMonth` is a
    /// genuine partial-month view; "Extra Spending After End-of-Month Bills" is NOT computed via
    /// this function at all — it is `flexibleSpendingAvailable` directly (the true whole-month
    /// figure, which already includes every item regardless of timing) — see the view model call
    /// site.
    static func extraSpendingThroughCutoff(
        items: [ScenarioLineItem],
        cutoff: PlanTiming,
        month: DateInterval,
        planSettings: MonthlyPlanSettings?
    ) -> Decimal {
        guard let cutoffOrdinalValue = cutoffOrdinal(cutoff) else { return 0 }
        let eligible = items.filter(\.isIncluded).filter { item in
            guard let itemOrdinal = cutoffOrdinal(item.timing) else { return false }
            return itemOrdinal <= cutoffOrdinalValue
        }
        let incomeSources = eligible.filter { $0.ledger == .income }.map { item in
            IncomeSource(id: item.id, name: item.name, amount: item.amount, frequency: item.frequency, timing: item.timing, nextPayDate: item.referenceDate, isActive: true)
        }
        let recurringExpenses = eligible.filter { $0.ledger == .expense }.map { item in
            RecurringExpense(id: item.id, name: item.name, amount: item.amount, frequency: item.frequency, timing: item.timing, dueDate: item.referenceDate, isActive: true)
        }
        let income = MonthlyPlanCalculator.estimatedMonthlyIncome(incomeSources, in: month)
        let expenses = MonthlyPlanCalculator.estimatedMonthlyFixedExpenses(recurringExpenses, in: month)
        let savingsGoal = planSettings?.monthlySavingsGoal ?? 0
        let buffer = planSettings?.bufferAmount ?? 0
        return income - expenses - savingsGoal - buffer
    }
}

/// income − expenses for one `PlanTiming` bucket — see `ScenarioSummaryBuilder.timingTotal(for:timing:month:)`.
struct ScenarioTimingTotal {
    let income: Decimal
    let expenses: Decimal
    var net: Decimal { income - expenses }
}
