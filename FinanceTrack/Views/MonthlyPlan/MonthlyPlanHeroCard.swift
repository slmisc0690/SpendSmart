import SwiftUI

/// Premium hero card summarizing the Monthly Plan: income, fixed bills, savings goal, flexible
/// spending, recommended weekly limit, and a projected-savings status line. All numbers are
/// passed in already computed by `MonthlyPlanCalculator` — this view does no math itself.
struct MonthlyPlanHeroCard: View {
    let summary: MonthlyPlanCalculator.Summary
    var isPrivacyModeEnabled: Bool = false

    private var statusMessage: String {
        switch summary.projectedStatus {
        case .good: return "On track to save"
        case .warning: return "Savings goal at risk"
        case .over: return "Overspending"
        }
    }

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Monthly Plan")
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Projected for this month")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    StatusBadge(status: summary.projectedStatus)
                }

                VStack(spacing: Theme.Spacing.sm) {
                    amountRow(title: "Monthly Income", amount: summary.estimatedMonthlyIncome, color: Theme.statusGood)
                    amountRow(title: "Fixed Bills", amount: summary.estimatedMonthlyFixedExpenses, color: Theme.statusOver, prefix: "-")
                    amountRow(title: "Savings Goal", amount: summary.monthlySavingsGoal, color: Theme.textSecondary, prefix: "-")
                    if summary.bufferAmount > 0 {
                        amountRow(title: "Buffer", amount: summary.bufferAmount, color: Theme.textSecondary, prefix: "-")
                    }
                    Divider().overlay(Theme.cardStroke)
                    amountRow(title: "Flexible Spending Available", amount: summary.flexibleSpendingAvailable, color: Theme.textPrimary, emphasized: true)
                }

                HStack(spacing: Theme.Spacing.lg) {
                    amountColumn(title: "Recommended / Week", amount: summary.recommendedWeeklySpendingLimit)
                    amountColumn(title: "Current Weekly Budget", amount: summary.currentManualWeeklyBudget)
                    amountColumn(title: "Projected Savings", amount: summary.projectedMonthlySavings)
                }

                Text(statusMessage)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.statusColor(for: summary.projectedStatus))
            }
        }
    }

    @ViewBuilder
    private func amountRow(title: String, amount: Decimal, color: Color, prefix: String = "", emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(emphasized ? Theme.bodyFont : Theme.captionFont)
                .foregroundStyle(emphasized ? Theme.textPrimary : Theme.textTertiary)
            Spacer()
            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: emphasized ? Theme.headlineFont : Theme.bodyFont,
                color: color,
                prefix: prefix
            )
        }
    }

    @ViewBuilder
    private func amountColumn(title: String, amount: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.bodyFont,
                color: Theme.textPrimary
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    MonthlyPlanHeroCard(
        summary: .init(
            estimatedMonthlyIncome: 4600,
            estimatedMonthlyFixedExpenses: 2305,
            monthlySavingsGoal: 500,
            bufferAmount: 100,
            flexibleSpendingAvailable: 1695,
            spendingWeeksInMonth: 5,
            recommendedWeeklySpendingLimit: 339,
            currentManualWeeklyBudget: 350,
            actualSpentThisMonth: 610,
            actualSpentThisWeek: 120,
            projectedMonthlySavings: 685,
            projectedStatus: .good,
            weeklyComparisons: []
        )
    )
    .padding()
    .background(Theme.backgroundGradient)
}
