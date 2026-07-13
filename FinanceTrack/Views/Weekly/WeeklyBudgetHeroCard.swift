import SwiftUI

/// Premium hero card for the Weekly Budget screen: week range, progress ring, remaining/spent/
/// limit figures, status message, an explicit over-budget amount when applicable, and an
/// "Edit Weekly Limit" affordance. All numbers are passed in already computed by
/// `BudgetCalculator`/`DateRangeHelper` — this view does no spending math itself.
struct WeeklyBudgetHeroCard: View {
    let weekInterval: DateInterval
    let spent: Decimal
    let limit: Decimal
    let status: SpendingStatus
    var isPrivacyModeEnabled: Bool = false
    var onEditLimit: () -> Void

    private var remaining: Decimal {
        BudgetCalculator.remaining(limit: limit, spent: spent)
    }

    private var overBudgetAmount: Decimal {
        BudgetCalculator.overBudgetAmount(spent: spent, limit: limit)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(status.dashboardMessage)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.statusColor(for: status))

                    if status == .over {
                        HStack(spacing: 4) {
                            PrivacyAmountView(
                                amount: overBudgetAmount,
                                isPrivacyModeEnabled: isPrivacyModeEnabled,
                                font: Theme.captionFont,
                                color: Theme.statusOver
                            )
                            Text("over your weekly limit")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.statusOver)
                        }
                    }
                }

                Button(action: onEditLimit) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Edit Weekly Limit")
                            .font(Theme.captionFont)
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
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

#Preview("On Track") {
    WeeklyBudgetHeroCard(weekInterval: DateRangeHelper.currentWeekRange(), spent: 90, limit: 350, status: .good) {}
        .padding()
        .background(Theme.backgroundGradient)
}

#Preview("Over Budget") {
    WeeklyBudgetHeroCard(weekInterval: DateRangeHelper.currentWeekRange(), spent: 420, limit: 350, status: .over) {}
        .padding()
        .background(Theme.backgroundGradient)
}
