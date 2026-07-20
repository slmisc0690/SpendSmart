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
    static func projectedMonthlySavings(income: Decimal, fixedExpenses: Decimal, actualSpentThisMonth: Decimal) -> Decimal {
        income - fixedExpenses - actualSpentThisMonth
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

    // MARK: - Projected savings from a manual weekly limit

    /// income − fixed expenses − buffer. Deliberately does *not* subtract a savings goal (unlike
    /// `flexibleSpendingAvailable`) — this answers "what's left after bills alone," which is what
    /// Settings' weekly-limit projection is estimating against.
    static func availableAfterBills(income: Decimal, fixedExpenses: Decimal, bufferAmount: Decimal) -> Decimal {
        income - fixedExpenses - bufferAmount
    }

    /// A flat weekly limit applied across every spending week in the month.
    static func monthlySpendingBudget(weeklyLimit: Decimal, spendingWeeksInMonth: Int) -> Decimal {
        weeklyLimit * Decimal(spendingWeeksInMonth)
    }

    /// What sticking to `weeklyLimit` every week would leave you with at month's end: available
    /// after bills minus the monthly spending budget that limit implies. Positive means projected
    /// savings; negative means that limit would overspend what's available after bills.
    static func projectedSavingsFromWeeklyLimit(availableAfterBills: Decimal, monthlySpendingBudget: Decimal) -> Decimal {
        availableAfterBills - monthlySpendingBudget
    }

    /// Whether there's enough Monthly Plan data (at least one active income source) to make the
    /// weekly-limit savings projection meaningful. With no income entered, "available after
    /// bills" is just a negative guess, not a real estimate.
    static func hasIncomeDataForProjection(_ sources: [IncomeSource]) -> Bool {
        sources.contains { $0.isActive }
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
        let recommendedWeekly = recommendedWeeklySpendingLimit(flexibleSpendingAvailable: flexible, spendingWeeksInMonth: weeks.count)

        let spentThisMonth = BudgetCalculator.monthlySpent(transactions, in: month, includePending: includePending)
        let spentThisWeek = BudgetCalculator.weeklySpent(transactions, in: weekInterval, includePending: includePending)

        let projectedSavings = projectedMonthlySavings(income: income, fixedExpenses: fixedExpenses, actualSpentThisMonth: spentThisMonth)
        let status = monthlyPlanStatus(projectedSavings: projectedSavings, savingsGoal: savingsGoal)

        let weeklyComparisons: [WeeklyPlanComparison] = weeks.map { week in
            let spent: Decimal
            if let clipped = DateRangeHelper.clampedInterval(week, to: month) {
                spent = BudgetCalculator.monthlySpent(transactions, in: clipped, includePending: includePending)
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
