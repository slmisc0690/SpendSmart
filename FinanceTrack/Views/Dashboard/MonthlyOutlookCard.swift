import SwiftUI

/// Dashboard-only, privacy-safe summary of the month: budgeted vs. actual spending, projected
/// savings, and a high-level status. Deliberately shows none of Monthly Plan's income sources or
/// bill list — those stay private under Settings > Monthly Plan. Takes already-computed numbers;
/// no money math happens here.
struct MonthlyOutlookCard: View {
    /// `BudgetSettings.monthlyGoal` — the user's plain manual monthly budget, if they've set one.
    let budgetedMonthlySpend: Decimal?
    let actualMonthlySpend: Decimal
    let projectedSavings: Decimal
    let status: SpendingStatus
    var isPrivacyModeEnabled: Bool = false

    private var statusLabel: String {
        switch status {
        case .good: return "On Track"
        case .warning: return "Watch"
        case .over: return "Overspending"
        }
    }

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monthly Outlook")
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text(statusLabel)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.statusColor(for: status))
                    }
                    Spacer()
                    InfoButton(title: "About Monthly Outlook", explanation: Self.infoExplanation)
                    StatusBadge(status: status)
                }

                HStack(spacing: Theme.Spacing.lg) {
                    labeledAmount(title: "Budgeted", amount: budgetedMonthlySpend)
                    labeledAmount(title: "Actual", amount: actualMonthlySpend)
                    labeledAmount(
                        title: "Projected Savings",
                        amount: projectedSavings,
                        color: projectedSavings >= 0 ? Theme.statusGood : Theme.statusOver
                    )
                }
            }
        }
    }

    static let infoExplanation = """
        This is a health check on your monthly spending plan.

        • Budgeted — the total you've planned to spend this month on everyday things. Bills like rent or insurance aren't part of this — those are already accounted for separately.

        • Actual — what you've really spent so far this month.

        • Projected Savings — if you stick to your Budgeted amount for the rest of the month, this is how much you'd end up saving. It's based on your PLAN, not your day-to-day spending, so it won't move just because you spend a little more or less on a given day.

        Example: you're budgeted for $2,000 this month, and you've actually spent $1,650 so far. That doesn't directly change Projected Savings — Projected Savings only moves if you change your monthly budget itself, or if a bill costs more or less than expected.
        """

    @ViewBuilder
    private func labeledAmount(title: String, amount: Decimal?, color: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let amount {
                PrivacyAmountView(amount: amount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.bodyFont, color: color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\u{2014}")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    VStack(spacing: 16) {
        MonthlyOutlookCard(budgetedMonthlySpend: 1400, actualMonthlySpend: 610, projectedSavings: 685, status: .good)
        MonthlyOutlookCard(budgetedMonthlySpend: nil, actualMonthlySpend: 1200, projectedSavings: 120, status: .warning)
        MonthlyOutlookCard(budgetedMonthlySpend: 1000, actualMonthlySpend: 1600, projectedSavings: -300, status: .over)
    }
    .padding()
    .background(Theme.backgroundGradient)
}
