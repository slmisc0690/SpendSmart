import SwiftUI

/// Hero card on the dashboard: current week range, spending progress ring, remaining/spent/limit
/// figures, a Monthly Remaining running total, and a plain-English status message.
struct SpendingCardView: View {
    let spent: Decimal
    let limit: Decimal
    let status: SpendingStatus
    let weekInterval: DateInterval
    /// Canonical `MonthlyPlanCalculator.monthlySpendRemaining` result — see
    /// `DashboardView.monthlySpendRemaining`. Passed in already computed; this view does no
    /// money math of its own beyond `remaining` below.
    let monthlyRemaining: Decimal
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
                    InfoButton(title: "About This Week", explanation: Self.infoExplanation)
                    StatusBadge(status: status)
                }

                HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                    WeeklyProgressView(spent: spent, limit: limit, status: status)

                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        amountRow(title: "Remaining", amount: remaining, emphasized: true)
                        amountRow(title: "Spent", amount: spent, emphasized: false)
                        amountRow(title: "Limit", amount: limit, emphasized: false)
                        amountRow(title: "Monthly Remaining", amount: monthlyRemaining, emphasized: false)
                    }
                    Spacer(minLength: 0)
                }

                Text(status.dashboardMessage)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.statusColor(for: status))
            }
        }
    }

    static let infoExplanation = """
        This shows how much you've spent so far this week compared to your weekly spending limit.

        • Spent — everyday purchases that count toward your budget this week, like groceries, gas, or eating out. Bill payments like rent or car insurance don't count here since they're already planned for separately.

        • Limit — the amount you've decided (or the app has worked out for you) is a healthy amount to spend each week.

        • Remaining — your Limit minus your Spent so far.

        • Monthly Remaining — the bigger picture: how much money you have left for the WHOLE month, after bills, savings, and everything you've spent so far — not just this one week.

        Example: your weekly limit is $500, and you've spent $320 so far on groceries and gas. Remaining shows $180 for the week. Monthly Remaining might show $1,200 — the total cushion left across the whole month.
        """

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
    SpendingCardView(spent: 210, limit: 350, status: .warning, weekInterval: DateRangeHelper.currentWeekRange(), monthlyRemaining: 2500)
        .padding()
        .background(Theme.backgroundGradient)
}
