import Foundation

/// Forecasting math for the Monthly Plan feature: income vs. fixed bills vs. savings goal vs.
/// actual spending. Like `BudgetCalculator`, this is money math only — it takes plain arrays and
/// `DateInterval`s as input and never touches SwiftData or persistence itself. Actual spending
/// figures are computed via `BudgetCalculator`, not reimplemented here.
enum MonthlyPlanCalculator {

    /// One week's planned-vs-actual comparison, shown in the Monthly Plan's week-by-week list.
    struct WeeklyPlanComparison: Identifiable {
        let weekInterval: DateInterval
        let recommendedLimit: Decimal
        let actualSpent: Decimal
        let status: SpendingStatus

        var remaining: Decimal { recommendedLimit - actualSpent }
        var id: Date { weekInterval.start }
    }

    /// Every number the Monthly Plan screen and its Dashboard card need, computed together so
    /// both always agree.
    struct Summary {
        let estimatedMonthlyIncome: Decimal
        let estimatedMonthlyFixedExpenses: Decimal
        let monthlySavingsGoal: Decimal
        let bufferAmount: Decimal
        let flexibleSpendingAvailable: Decimal
        let spendingWeeksInMonth: Int
        let recommendedWeeklySpendingLimit: Decimal
        let currentManualWeeklyBudget: Decimal
        let actualSpentThisMonth: Decimal
        let actualSpentThisWeek: Decimal
        let projectedMonthlySavings: Decimal
        let projectedStatus: SpendingStatus
        let weeklyComparisons: [WeeklyPlanComparison]
    }

    /// Converts any recurring amount to its monthly equivalent. Not meaningful for `.oneTime` —
    /// callers must separately check a one-time item's date falls in the target month before
    /// including its raw `amount` (see `estimatedMonthlyIncome`/`estimatedMonthlyFixedExpenses`).
    static func monthlyAmount(for amount: Decimal, frequency: PlanFrequency) -> Decimal {
        switch frequency {
        case .weekly: return amount * 52 / 12
        case .biweekly: return amount * 26 / 12
        case .twiceMonthly: return amount * 2
        case .monthly: return amount
        case .quarterly: return amount / 3
        case .yearly: return amount / 12
        case .oneTime: return amount
        }
    }

    /// Sum of active income sources' monthly-equivalent amounts. A `.oneTime` source only counts
    /// when `nextPayDate` falls inside `month`.
    static func estimatedMonthlyIncome(_ sources: [IncomeSource], in month: DateInterval) -> Decimal {
        sources
            .filter { $0.isActive }
            .reduce(Decimal(0)) { total, source in
                if source.frequency == .oneTime {
                    guard let date = source.nextPayDate, month.contains(date) else { return total }
                    return total + source.amount
                }
                return total + monthlyAmount(for: source.amount, frequency: source.frequency)
            }
    }

    /// Sum of active recurring expenses' monthly-equivalent amounts. A `.oneTime` expense only
    /// counts when `dueDate` falls inside `month`.
    static func estimatedMonthlyFixedExpenses(_ expenses: [RecurringExpense], in month: DateInterval) -> Decimal {
        expenses
            .filter { $0.isActive }
            .reduce(Decimal(0)) { total, expense in
                if expense.frequency == .oneTime {
                    guard let date = expense.dueDate, month.contains(date) else { return total }
                    return total + expense.amount
                }
                return total + monthlyAmount(for: expense.amount, frequency: expense.frequency)
            }
    }

    /// income − fixed expenses − savings goal − buffer.
    static func flexibleSpendingAvailable(
        income: Decimal,
        fixedExpenses: Decimal,
        savingsGoal: Decimal,
        bufferAmount: Decimal
    ) -> Decimal {
        income - fixedExpenses - savingsGoal - bufferAmount
    }

    /// Flexible spending divided evenly across the weeks touching the month, floored at 0 — when
    /// bills plus the savings goal (plus buffer) exceed income, there is no amount left to
    /// recommend spending, not a negative one. 0 when there are no spending weeks (shouldn't
    /// happen in practice, but avoids a division by zero).
    static func recommendedWeeklySpendingLimit(flexibleSpendingAvailable: Decimal, spendingWeeksInMonth: Int) -> Decimal {
        guard spendingWeeksInMonth > 0 else { return 0 }
        return max(0, flexibleSpendingAvailable / Decimal(spendingWeeksInMonth))
    }

    /// income − fixed expenses − what's actually been spent so far this month. This is what the
    /// user will actually end up saving at the current pace, not just the target.
    ///
    /// URGENT MONTHLY PLAN CALCULATION CORRECTION (Part 4) — this is the LEGACY actual-spending
    /// projection. It remains completely UNCHANGED and still drives `Summary.projectedMonthlySavings`
    /// (Dashboard, `PrimaryDashboardSummarySyncService`, `SpendSmartQueryEngine`,
    /// `SharedPrimaryDataViews` — none of those consumers are touched by this phase). It is
    /// DELIBERATELY NOT used for the Monthly Plan top card anymore — see
    /// `projectedSavingsFromActualSpending` (an explicitly-named alias for this exact function,
    /// added so a future caller can never confuse this with `projectedMonthlySavingsFromPlan`
    /// below by an ambiguous shared name) and `MonthlyPlanHeroCard`, which now takes the
    /// planned-spending values as explicit parameters instead.
    static func projectedMonthlySavings(income: Decimal, fixedExpenses: Decimal, actualSpentThisMonth: Decimal) -> Decimal {
        income - fixedExpenses - actualSpentThisMonth
    }

    /// Explicitly-named alias for `projectedMonthlySavings(income:fixedExpenses:
    /// actualSpentThisMonth:)` — same formula, same value, just a name that can never be confused
    /// with `projectedMonthlySavingsFromPlan` (Part 4's explicit requirement: distinct names so
    /// these two concepts cannot be accidentally wired together again).
    static func projectedSavingsFromActualSpending(income: Decimal, fixedExpenses: Decimal, actualSpentThisMonth: Decimal) -> Decimal {
        projectedMonthlySavings(income: income, fixedExpenses: fixedExpenses, actualSpentThisMonth: actualSpentThisMonth)
    }

    // MARK: - MONTHLY PLAN + SCENARIO CORRECTIONS PHASE — Planned Weekly Spending planning path
    //
    // The ONE authoritative formula path for "Planned Weekly Spending" planning (Part 13) — never
    // duplicated in a view or a view model. Deliberately separate from
    // `projectedMonthlySavings(income:fixedExpenses:actualSpentThisMonth:)` above, which remains
    // completely UNCHANGED (it still drives `Summary.projectedMonthlySavings`, consumed by
    // `MonthlyPlanHeroCard`, `DashboardView`, `PrimaryDashboardSummarySyncService`,
    // `SpendSmartQueryEngine`, and `SharedPrimaryDataViews` — none of those call sites are touched
    // by this phase). This is a DIFFERENT metric: a forward-looking planning projection based on
    // how much the user INTENDS to spend each week, not a backward-looking one based on actual
    // spending so far. The two numbers are expected to differ and are shown in different places.

    /// The automatic Planned Weekly Spending — used whenever no manual override is set. Exactly
    /// `flexibleSpendingAvailable ÷ 4`, matching the required example ($3,169 ÷ 4 = $792.25).
    static func automaticPlannedWeeklySpending(flexibleSpendingAvailable: Decimal) -> Decimal {
        flexibleSpendingAvailable / 4
    }

    /// The Planned Weekly Spending actually in effect — the user's manual override when one is
    /// set, otherwise the automatic value. `override` is `nil` for "automatic mode," never a
    /// truthy/nonzero check (a deliberate custom `$0.00` override is a real override, not
    /// "no override" — see `MonthlyPlanSettings.plannedWeeklySpendingOverride`'s own header).
    static func effectivePlannedWeeklySpending(override: Decimal?, flexibleSpendingAvailable: Decimal) -> Decimal {
        override ?? automaticPlannedWeeklySpending(flexibleSpendingAvailable: flexibleSpendingAvailable)
    }

    /// Planned Weekly Spending × 4 — never 4.33 or any other week-count approximation (locked
    /// product behavior, matching `BudgetSettings.applyMonthlyPlanAutoCalculate`'s own established
    /// "always exactly 4" rule).
    static func plannedMonthlySpending(plannedWeeklySpending: Decimal) -> Decimal {
        plannedWeeklySpending * 4
    }

    /// The part of Average Monthly Flexible Spending NOT set aside for planned weekly spending.
    /// May be negative when planned spending exceeds flexible spending available — deliberately
    /// never clamped to zero (Part 7's explicit requirement: an over-limit plan must show its real
    /// negative effect, not be silently hidden).
    static func additionalPlannedSavings(flexibleSpendingAvailable: Decimal, plannedMonthlySpending: Decimal) -> Decimal {
        flexibleSpendingAvailable - plannedMonthlySpending
    }

    /// Monthly Savings Goal + Additional Planned Savings — the planning-workflow Projected Monthly
    /// Savings (Part 6). Distinct from `projectedMonthlySavings(income:fixedExpenses:
    /// actualSpentThisMonth:)` above; may be negative (Part 7) when Additional Planned Savings is
    /// negative enough to exceed the goal.
    static func projectedMonthlySavingsFromPlan(monthlySavingsGoal: Decimal, additionalPlannedSavings: Decimal) -> Decimal {
        monthlySavingsGoal + additionalPlannedSavings
    }

    /// Explicitly-named alias for `projectedMonthlySavingsFromPlan(monthlySavingsGoal:
    /// additionalPlannedSavings:)` — matches Part 4's exact suggested naming
    /// (`projectedSavingsFromPlannedSpending`) alongside `projectedSavingsFromActualSpending`
    /// above, so the two concepts read as unmistakably distinct at every call site.
    static func projectedSavingsFromPlannedSpending(monthlySavingsGoal: Decimal, additionalPlannedSavings: Decimal) -> Decimal {
        projectedMonthlySavingsFromPlan(monthlySavingsGoal: monthlySavingsGoal, additionalPlannedSavings: additionalPlannedSavings)
    }

    /// On track to save (projected ≥ goal), savings goal at risk (0 ≤ projected < goal), or
    /// overspending (projected < 0). Reuses `SpendingStatus` for consistent color/badge styling
    /// with the rest of the app — `.good`/`.warning`/`.over` map to those three states here.
    static func monthlyPlanStatus(projectedSavings: Decimal, savingsGoal: Decimal) -> SpendingStatus {
        if projectedSavings >= savingsGoal { return .good }
        if projectedSavings >= 0 { return .warning }
        return .over
    }

    /// Writes `recommendedLimit` into `settings.weeklySpendingLimit` — the one place Monthly
    /// Plan is allowed to touch `BudgetSettings`, and only ever called explicitly (either the
    /// user taps "Use Recommended Weekly Limit", or `autoUpdateWeeklyBudgetFromPlan` is on).
    static func applyRecommendedWeeklyLimit(_ recommendedLimit: Decimal, to settings: BudgetSettings) {
        settings.weeklySpendingLimit = recommendedLimit
        settings.updatedAt = .now
    }

    // MARK: - Monthly Spend Remaining (authoritative Weekly Spending Limit source)

    /// income − fixed expenses. A month-start planning figure — deliberately does not account
    /// for the savings goal, buffer, or actual spending; each of those is applied by a later,
    /// separate step below so no input is ever subtracted twice.
    static func moneyAfterBills(income: Decimal, fixedExpenses: Decimal) -> Decimal {
        income - fixedExpenses
    }

    /// The fixed monthly amount available to spend once bills, the Monthly Savings Goal, and the
    /// optional Buffer are all protected. Clamped at 0 — a goal/buffer combination that exceeds
    /// money after bills must never produce a negative budget.
    static func monthlySpendingBudget(moneyAfterBills: Decimal, savingsGoal: Decimal, bufferAmount: Decimal) -> Decimal {
        max(0, moneyAfterBills - savingsGoal - bufferAmount)
    }

    /// `monthlySpendingBudget` minus actual qualifying spending so far this month (see
    /// `BudgetCalculator.monthlySpent` — the single canonical actual-spending source, never
    /// duplicated here). Clamped at 0 — spending beyond the budget must never show as available
    /// to spend. This is the sole authoritative input to the derived Weekly Spending Limit
    /// (`BudgetSettings.applyMonthlyPlanAutoCalculate`), which divides it by exactly 4.
    static func monthlySpendRemaining(monthlySpendingBudget: Decimal, actualMonthlySpending: Decimal) -> Decimal {
        max(0, monthlySpendingBudget - actualMonthlySpending)
    }

    /// Computes everything the Monthly Plan screen shows, for `month`. `weekInterval` should be
    /// the *current* week (for `actualSpentThisWeek`), which may or may not be the same month as
    /// `month` near a month boundary.
    static func summary(
        month: DateInterval,
        incomeSources: [IncomeSource],
        recurringExpenses: [RecurringExpense],
        planSettings: MonthlyPlanSettings?,
        weeklyBudgetLimit: Decimal,
        transactions: [FinanceTransaction],
        weekInterval: DateInterval,
        weekStartsOnSunday: Bool,
        includePending: Bool,
        warningThreshold: Double
    ) -> Summary {
        let income = estimatedMonthlyIncome(incomeSources, in: month)
        let fixedExpenses = estimatedMonthlyFixedExpenses(recurringExpenses, in: month)
        let savingsGoal = planSettings?.monthlySavingsGoal ?? 0
        let buffer = planSettings?.bufferAmount ?? 0
        let flexible = flexibleSpendingAvailable(income: income, fixedExpenses: fixedExpenses, savingsGoal: savingsGoal, bufferAmount: buffer)

        let weeks = DateRangeHelper.weeksOverlapping(month, weekStartsOnSunday: weekStartsOnSunday)
        // WEEKLY SPENDING UNIFICATION — the per-week Recommended amount is the ONE authoritative
        // Effective Planned Weekly Spending (custom override when set, otherwise Flexible Spending
        // Available ÷ 4 — see `effectivePlannedWeeklySpending`'s own header), repeated identically
        // for every week `weeks` contains. Never `recommendedWeeklySpendingLimit`'s calendar-week
        // divisor (`weeks.count`, which produces 5 or 6 depending on the month and silently ignores
        // any custom override) — that legacy formula is the root cause of Monthly Plan/Dashboard
        // Week-by-Week showing a different number than the real Planned Weekly Spending setting.
        // `recommendedWeeklySpendingLimit(flexibleSpendingAvailable:spendingWeeksInMonth:)` itself
        // is left defined and untouched for any existing direct caller, just no longer used here.
        let recommendedWeekly = effectivePlannedWeeklySpending(override: planSettings?.plannedWeeklySpendingOverride, flexibleSpendingAvailable: flexible)

        let spentThisMonth = BudgetCalculator.monthlySpent(transactions, in: month, includePending: includePending)
        let spentThisWeek = BudgetCalculator.weeklySpent(transactions, in: weekInterval, includePending: includePending)

        let projectedSavings = projectedMonthlySavings(income: income, fixedExpenses: fixedExpenses, actualSpentThisMonth: spentThisMonth)
        let status = monthlyPlanStatus(projectedSavings: projectedSavings, savingsGoal: savingsGoal)

        let weeklyComparisons: [WeeklyPlanComparison] = weeks.map { week in
            let spent: Decimal
            if let clipped = DateRangeHelper.clampedInterval(week, to: month) {
                // Each week's Actual now routes through `BudgetCalculator.weeklySpent`
                // (`countsTowardWeeklyBudget`) — the SAME per-transaction eligibility flag the
                // dedicated Weekly Budget screen already used, never `monthlySpent`
                // (`countsTowardMonthlySpending`, a different, independent flag) — so Monthly
                // Plan, Dashboard, and Weekly Budget can never disagree about what counts as this
                // week's spending.
                spent = BudgetCalculator.weeklySpent(transactions, in: clipped, includePending: includePending)
            } else {
                spent = 0
            }
            let weekStatus = BudgetCalculator.status(spent: spent, limit: recommendedWeekly, warningThreshold: warningThreshold)
            return WeeklyPlanComparison(weekInterval: week, recommendedLimit: recommendedWeekly, actualSpent: spent, status: weekStatus)
        }

        return Summary(
            estimatedMonthlyIncome: income,
            estimatedMonthlyFixedExpenses: fixedExpenses,
            monthlySavingsGoal: savingsGoal,
            bufferAmount: buffer,
            flexibleSpendingAvailable: flexible,
            spendingWeeksInMonth: weeks.count,
            recommendedWeeklySpendingLimit: recommendedWeekly,
            currentManualWeeklyBudget: weeklyBudgetLimit,
            actualSpentThisMonth: spentThisMonth,
            actualSpentThisWeek: spentThisWeek,
            projectedMonthlySavings: projectedSavings,
            projectedStatus: status,
            weeklyComparisons: weeklyComparisons
        )
    }
}
