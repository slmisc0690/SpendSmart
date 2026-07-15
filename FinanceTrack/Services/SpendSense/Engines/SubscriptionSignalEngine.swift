import Foundation

/// Recurring/fixed-expense observations. The one rule implemented so far: whether committed
/// recurring bills are consuming an outsized share of income. Every monthly-equivalent total
/// comes from `MonthlyPlanCalculator`; this engine never sums `RecurringExpense`/`IncomeSource`
/// amounts or reimplements the frequency-to-monthly conversion itself.
struct SubscriptionSignalEngine: SpendSenseEngine {

    // MARK: - Tunables

    /// Exact Decimal 0.60 — built from integer division rather than a floating-point literal so
    /// the boundary comparison (`>=`) is never affected by binary floating-point imprecision.
    private static let fixedExpenseRatioThreshold = Decimal(60) / Decimal(100)

    func generateSignals(context: SpendSenseContext) -> [SpendSenseSignal] {
        guard let signal = generateFixedExpenseRatioSignal(context: context) else { return [] }
        return [signal]
    }

    // MARK: - Fixed-expense-ratio rule

    private func generateFixedExpenseRatioSignal(context: SpendSenseContext) -> SpendSenseSignal? {
        let calendar = Calendar.current
        let month = DateRangeHelper.monthRangeContaining(context.now, calendar: calendar)

        let income = MonthlyPlanCalculator.estimatedMonthlyIncome(context.incomeSources, in: month)
        guard income > 0 else { return nil }

        let fixedExpenses = MonthlyPlanCalculator.estimatedMonthlyFixedExpenses(context.recurringExpenses, in: month)
        guard fixedExpenses > 0 else { return nil }

        let ratio = fixedExpenses / income
        guard ratio >= Self.fixedExpenseRatioThreshold else { return nil }

        let annualizedFixedExpenses = fixedExpenses * 12
        let ratioAsDouble = NSDecimalNumber(decimal: ratio).doubleValue

        return SpendSenseSignal(
            id: "subscription.fixed-expense-ratio",
            deduplicationID: "subscription.fixed-expense-ratio",
            category: .subscriptions,
            severity: .headsUp,
            confidence: .medium,
            priority: 150,
            title: "Fixed Expenses Are a Large Share of Income",
            explanation: "Your recurring fixed expenses are \(formatCurrency(fixedExpenses)) per month against \(formatCurrency(income)) in estimated monthly income — \(formatPercentage(ratioAsDouble)) of your income.",
            metrics: [
                SpendSenseMetric(id: "subscription.fixed.monthly", label: "Monthly Fixed Expenses", value: .currency(fixedExpenses)),
                SpendSenseMetric(id: "subscription.income.monthly", label: "Monthly Income", value: .currency(income)),
                SpendSenseMetric(id: "subscription.fixed.ratio", label: "Percent of Income", value: .percentage(ratioAsDouble)),
                SpendSenseMetric(id: "subscription.fixed.annualized", label: "Annualized Fixed Expenses", value: .currency(annualizedFixedExpenses)),
            ],
            action: nil,
            relevantDate: month.start,
            evaluatedAt: context.now
        )
    }

    // MARK: - Formatting

    /// Mirrors `BudgetSignalEngine`/`SpendingSignalEngine`'s private currency formatting exactly
    /// (same locale, same style) — kept as a separate, equivalent helper here since neither
    /// exposes a shared formatting API.
    private func formatCurrency(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
    }

    private func formatPercentage(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
