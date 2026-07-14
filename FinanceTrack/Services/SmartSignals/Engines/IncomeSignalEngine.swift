import Foundation

/// Income-source structural observations. The one rule implemented so far: whether a single
/// estimated income source represents most of total estimated monthly income. Every monthly-
/// equivalent total comes from `MonthlyPlanCalculator.estimatedMonthlyIncome`; this engine never
/// sums `IncomeSource` amounts, converts frequencies, or reimplements one-time-date inclusion
/// itself.
struct IncomeSignalEngine: SmartSignalEngine {

    // MARK: - Tunables

    /// Exact Decimal 0.80 — built from integer division rather than a floating-point literal so
    /// the boundary comparison (`>=`) is never affected by binary floating-point imprecision.
    private static let concentrationThreshold = Decimal(80) / Decimal(100)

    func generateSignals(context: SmartSignalContext) -> [SmartSignal] {
        guard let signal = generateConcentrationSignal(context: context) else { return [] }
        return [signal]
    }

    // MARK: - Income-concentration rule

    private func generateConcentrationSignal(context: SmartSignalContext) -> SmartSignal? {
        guard !context.incomeSources.isEmpty else { return nil }

        let calendar = Calendar.current
        let currentMonth = DateRangeHelper.monthRangeContaining(context.now, calendar: calendar)

        let totalMonthlyIncome = MonthlyPlanCalculator.estimatedMonthlyIncome(context.incomeSources, in: currentMonth)
        guard totalMonthlyIncome > 0 else { return nil }

        let qualifyingContributions = qualifyingMonthlyContributions(context.incomeSources, in: currentMonth)
        guard qualifyingContributions.count >= 2 else { return nil }

        guard let largestMonthlyIncome = qualifyingContributions.max(), largestMonthlyIncome > 0 else { return nil }

        let concentrationRatio = largestMonthlyIncome / totalMonthlyIncome
        guard concentrationRatio >= Self.concentrationThreshold else { return nil }

        let annualizedIncome = totalMonthlyIncome * Decimal(12)
        let ratioAsDouble = NSDecimalNumber(decimal: concentrationRatio).doubleValue

        return SmartSignal(
            id: "income.concentration",
            deduplicationID: "income.concentration",
            category: .income,
            severity: .information,
            confidence: .medium,
            priority: 110,
            title: "Most of Your Income Comes From One Source",
            explanation: "Your largest estimated income source represents \(formatPercentage(ratioAsDouble)) of your estimated monthly income (\(formatCurrency(largestMonthlyIncome)) of \(formatCurrency(totalMonthlyIncome))).",
            metrics: [
                SmartSignalMetric(id: "income.total.monthly", label: "Monthly Income", value: .currency(totalMonthlyIncome)),
                SmartSignalMetric(id: "income.largest-source.monthly", label: "Largest Income Source", value: .currency(largestMonthlyIncome)),
                SmartSignalMetric(id: "income.concentration.ratio", label: "Income Concentration", value: .percentage(ratioAsDouble)),
                SmartSignalMetric(id: "income.total.annualized", label: "Annualized Income", value: .currency(annualizedIncome)),
            ],
            action: nil,
            relevantDate: currentMonth.start,
            evaluatedAt: context.now
        )
    }

    /// Each source's own monthly-equivalent contribution, computed by calling
    /// `MonthlyPlanCalculator.estimatedMonthlyIncome` with a one-element array — never
    /// `monthlyAmount` directly — so inactive sources, one-time sources outside `month`, and every
    /// frequency conversion stay entirely owned by `MonthlyPlanCalculator`. Only strictly-positive
    /// contributions qualify; a source contributing nothing this month isn't a "source" for
    /// concentration purposes.
    private func qualifyingMonthlyContributions(_ sources: [IncomeSource], in month: DateInterval) -> [Decimal] {
        sources
            .map { MonthlyPlanCalculator.estimatedMonthlyIncome([$0], in: month) }
            .filter { $0 > 0 }
    }

    // MARK: - Formatting

    /// Mirrors `BudgetSignalEngine`/`SpendingSignalEngine`/`SubscriptionSignalEngine`'s private
    /// currency formatting exactly (same locale, same style) — kept as a separate, equivalent
    /// helper here since none of them expose a shared formatting API.
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
