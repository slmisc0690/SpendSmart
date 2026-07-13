import SwiftUI

/// Hero card on the dashboard: current week range, spending progress ring, remaining/spent/limit
/// figures, and a plain-English status message.
struct SpendingCardView: View {
    let spent: Decimal
    let limit: Decimal
    let status: SpendingStatus
    let weekInterval: DateInterval
    var isPrivacyModeEnabled: Bool = false

    private var remaining: Decimal {
        BudgetCalculator.remaining(limit: limit, spent: spent)
    }

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This Week")
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text(DateRangeHelper.weekDisplayText(for: weekInterval))
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    StatusBadge(status: status)
                }

                HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                    WeeklyProgressView(spent: spent, limit: limit, status: status)

                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        amountRow(title: "Remaining", amount: remaining, emphasized: true)
                        amountRow(title: "Spent", amount: spent, emphasized: false)
                        amountRow(title: "Limit", amount: limit, emphasized: false)
                    }
                    Spacer(minLength: 0)
                }

                Text(status.dashboardMessage)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.statusColor(for: status))
            }
        }
    }

    @ViewBuilder
    private func amountRow(title: String, amount: Decimal, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: emphasized ? Theme.headlineFont : Theme.bodyFont,
                color: emphasized ? Theme.textPrimary : Theme.textSecondary
            )
        }
    }
}

#Preview {
    SpendingCardView(spent: 210, limit: 350, status: .warning, weekInterval: DateRangeHelper.currentWeekRange())
        .padding()
        .background(Theme.backgroundGradient)
}
