import SwiftUI

/// One week's planned-vs-actual row in the Monthly Plan's week-by-week comparison.
struct WeeklyPlanComparisonRow: View {
    let comparison: MonthlyPlanCalculator.WeeklyPlanComparison
    var isPrivacyModeEnabled: Bool = false

    private var percent: Double {
        BudgetCalculator.progress(spent: comparison.actualSpent, limit: comparison.recommendedLimit)
    }

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(DateRangeHelper.weekDisplayText(for: comparison.weekInterval))
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    StatusBadge(status: comparison.status)
                }

                HStack {
                    labeledAmount(title: "Recommended", amount: comparison.recommendedLimit)
                    Spacer()
                    labeledAmount(title: "Actual", amount: comparison.actualSpent)
                    Spacer()
                    labeledAmount(
                        title: comparison.remaining >= 0 ? "Left" : "Over",
                        amount: abs(comparison.remaining),
                        color: comparison.remaining >= 0 ? Theme.statusGood : Theme.statusOver
                    )
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(Theme.statusColor(for: comparison.status))
                            .frame(width: max(geometry.size.width * percent, percent > 0 ? 4 : 0))
                    }
                }
                .frame(height: 6)
            }
        }
    }

    @ViewBuilder
    private func labeledAmount(title: String, amount: Decimal, color: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
            PrivacyAmountView(amount: amount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.captionFont, color: color)
        }
    }
}

#Preview {
    WeeklyPlanComparisonRow(
        comparison: .init(
            weekInterval: DateRangeHelper.currentWeekRange(),
            recommendedLimit: 340,
            actualSpent: 210,
            status: .warning
        )
    )
    .padding()
    .background(Theme.backgroundGradient)
}
