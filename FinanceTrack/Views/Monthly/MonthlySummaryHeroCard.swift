import SwiftUI

/// Premium hero card for the Monthly Summary screen. Mirrors `WeeklyBudgetHeroCard`'s visual
/// language, but a monthly goal is optional — with no goal set it shows total spend only and a
/// neutral message instead of a progress ring. All numbers are passed in already computed by
/// `BudgetCalculator`/`MonthlyPlanCalculator`; this view does no spending math itself. Monthly
/// Savings Goal is edited only from Monthly Plan — this card has no editing affordance for it.
struct MonthlySummaryHeroCard: View {
    let monthInterval: DateInterval
    let spent: Decimal
    let goal: Decimal?
    /// The canonical `MonthlyPlanCalculator.monthlySpendRemaining` result — `nil` when browsing a
    /// past/future month (see `MonthlySummaryView.currentMonthSpendRemaining`), since that figure
    /// is only meaningful for the live, current month. Never `goal - spent` — that formula is
    /// gone; it incorrectly ignored income, fixed bills, and buffer.
    let monthlySpendRemaining: Decimal?
    var isPrivacyModeEnabled: Bool = false
    var warningThreshold: Double = 0.70

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
                            if let monthlySpendRemaining {
                                amountRow(title: "Remaining", amount: monthlySpendRemaining, emphasized: true)
                            }
                            amountRow(title: "Spent", amount: spent, emphasized: monthlySpendRemaining == nil)
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
    MonthlySummaryHeroCard(monthInterval: DateRangeHelper.currentMonthRange(), spent: 890, goal: 1400, monthlySpendRemaining: 610)
        .padding()
        .background(Theme.backgroundGradient)
}

#Preview("No Goal") {
    MonthlySummaryHeroCard(monthInterval: DateRangeHelper.currentMonthRange(), spent: 890, goal: nil, monthlySpendRemaining: nil)
        .padding()
        .background(Theme.backgroundGradient)
}

#Preview("Past Month") {
    MonthlySummaryHeroCard(monthInterval: DateRangeHelper.lastMonthRange(), spent: 890, goal: 1400, monthlySpendRemaining: nil)
        .padding()
        .background(Theme.backgroundGradient)
}
