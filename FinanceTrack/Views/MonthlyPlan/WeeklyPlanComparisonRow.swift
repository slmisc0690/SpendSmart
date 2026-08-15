import SwiftUI

/// One week's planned-vs-actual row in the Monthly Plan's week-by-week comparison.
struct WeeklyPlanComparisonRow: View {
    let comparison: MonthlyPlanCalculator.WeeklyPlanComparison
    /// MONTH-ALIGNED FOUR-WEEK CORRECTION — 1-based position of this row among the month's
    /// (always exactly 4) `fourWeekBlocks`, used only for the "Week N:" label prefix. `nil`
    /// preserves this row's original bare-date-range appearance for any caller that doesn't (yet)
    /// have an index to pass — see `MonthlyPlanScenarioView`'s own separate row, which still
    /// calls `DateRangeHelper.weekDisplayText` directly rather than through this component.
    var weekNumber: Int?
    var isPrivacyModeEnabled: Bool = false

    private var percent: Double {
        BudgetCalculator.progress(spent: comparison.actualSpent, limit: comparison.recommendedLimit)
    }

    private var dateRangeLabel: String {
        let range = DateRangeHelper.weekDisplayText(for: comparison.weekInterval)
        guard let weekNumber else { return range }
        return "Week \(weekNumber): \(range)"
    }

    /// The weekday name this week starts on — always the same as the month's 1st (see
    /// `DateRangeHelper.fourWeekBlockStartWeekdayName(for:)`'s own header).
    private var startsOnLabel: String {
        "Starts on: \(DateRangeHelper.fourWeekBlockStartWeekdayName(for: comparison.weekInterval))"
    }

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    VStack(alignment: .center, spacing: 2) {
                        Text(dateRangeLabel)
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text(startsOnLabel)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
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
            weekInterval: DateRangeHelper.currentFourWeekBlock(),
            recommendedLimit: 340,
            actualSpent: 210,
            status: .warning
        ),
        weekNumber: 1
    )
    .padding()
    .background(Theme.backgroundGradient)
}
