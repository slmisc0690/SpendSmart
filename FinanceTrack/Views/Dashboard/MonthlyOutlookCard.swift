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
    let recommendedWeeklyLimit: Decimal
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

                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Recommended weekly limit:")
                        .font(Theme.captionFont)
                    PrivacyAmountView(
                        amount: recommendedWeeklyLimit,
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: Theme.captionFont.weight(.semibold),
                        color: Theme.textPrimary
                    )
                }
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }

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
        MonthlyOutlookCard(budgetedMonthlySpend: 1400, actualMonthlySpend: 610, projectedSavings: 685, status: .good, recommendedWeeklyLimit: 339)
        MonthlyOutlookCard(budgetedMonthlySpend: nil, actualMonthlySpend: 1200, projectedSavings: 120, status: .warning, recommendedWeeklyLimit: 250)
        MonthlyOutlookCard(budgetedMonthlySpend: 1000, actualMonthlySpend: 1600, projectedSavings: -300, status: .over, recommendedWeeklyLimit: 200)
    }
    .padding()
    .background(Theme.backgroundGradient)
}
