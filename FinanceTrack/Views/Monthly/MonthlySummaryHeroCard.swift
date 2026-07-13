import SwiftUI

/// Premium hero card for the Monthly Summary screen. Mirrors `WeeklyBudgetHeroCard`'s visual
/// language, but a monthly goal is optional — with no goal set it shows total spend only and a
/// neutral message instead of a progress ring. All numbers are passed in already computed by
/// `BudgetCalculator`; this view does no spending math itself.
struct MonthlySummaryHeroCard: View {
    let monthInterval: DateInterval
    let spent: Decimal
    let goal: Decimal?
    var isPrivacyModeEnabled: Bool = false
    var warningThreshold: Double = 0.70
    var onEditGoal: () -> Void

    private var hasGoal: Bool { (goal ?? 0) > 0 }

    private var status: SpendingStatus? {
        guard let goal, goal > 0 else { return nil }
        return BudgetCalculator.status(spent: spent, limit: goal, warningThreshold: warningThreshold)
    }

    private var statusMessage: String {
        switch status {
        case .none: return "Monthly spending overview"
        case .good: return "You're within your monthly goal"
        case .warning: return "Getting close to your monthly goal"
        case .over: return "Over monthly goal"
        }
    }

    private var statusColor: Color {
        guard let status else { return Theme.textSecondary }
        return Theme.statusColor(for: status)
    }

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This Month")
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text(DateRangeHelper.monthDisplayText(for: monthInterval))
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if let status {
                        StatusBadge(status: status)
                    }
                }

                if hasGoal, let goal {
                    HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                        WeeklyProgressView(spent: spent, limit: goal, status: status ?? .good)

                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            amountRow(title: "Remaining", amount: BudgetCalculator.remaining(limit: goal, spent: spent), emphasized: true)
                            amountRow(title: "Spent", amount: spent, emphasized: false)
                            amountRow(title: "Goal", amount: goal, emphasized: false)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    amountRow(title: "Total Spent", amount: spent, emphasized: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusMessage)
                        .font(Theme.bodyFont)
                        .foregroundStyle(statusColor)

                    if status == .over, let goal {
                        HStack(spacing: 4) {
                            PrivacyAmountView(
                                amount: BudgetCalculator.overBudgetAmount(spent: spent, limit: goal),
                                isPrivacyModeEnabled: isPrivacyModeEnabled,
                                font: Theme.captionFont,
                                color: Theme.statusOver
                            )
                            Text("over your monthly goal")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.statusOver)
                        }
                    }
                }

                Button(action: onEditGoal) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text(hasGoal ? "Edit Monthly Goal" : "Set Monthly Goal")
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

#Preview("With Goal") {
    MonthlySummaryHeroCard(monthInterval: DateRangeHelper.currentMonthRange(), spent: 890, goal: 1400) {}
        .padding()
        .background(Theme.backgroundGradient)
}

#Preview("No Goal") {
    MonthlySummaryHeroCard(monthInterval: DateRangeHelper.currentMonthRange(), spent: 890, goal: nil) {}
        .padding()
        .background(Theme.backgroundGradient)
}
