import SwiftUI

/// One week's contribution to the selected month's total, shown in the Monthly screen's
/// "Weekly Totals" section. `spentInMonth` is only the slice of that week which falls inside
/// the selected month (a week spanning two months is clipped before this view ever sees it).
/// `weeklyStatus` reflects the week's *full* standing against the weekly budget, independent of
/// month boundaries, so it's omitted entirely when there's no weekly limit set.
struct WeeklyMonthlyTotalCard: View {
    let weekInterval: DateInterval
    let spentInMonth: Decimal
    let monthlyTotal: Decimal
    var weeklyStatus: SpendingStatus? = nil
    var isPrivacyModeEnabled: Bool = false

    private var percentOfMonth: Double {
        guard monthlyTotal > 0 else { return 0 }
        let ratio = NSDecimalNumber(decimal: spentInMonth / monthlyTotal).doubleValue
        return min(max(ratio, 0), 1)
    }

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(DateRangeHelper.weekDisplayText(for: weekInterval))
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let weeklyStatus {
                        StatusBadge(status: weeklyStatus)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    PrivacyAmountView(
                        amount: spentInMonth,
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: Theme.headlineFont,
                        color: Theme.textPrimary
                    )
                    Spacer()
                    Text("\(Int(percentOfMonth * 100))% of month")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(geometry.size.width * percentOfMonth, percentOfMonth > 0 ? 4 : 0))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

#Preview {
    WeeklyMonthlyTotalCard(
        weekInterval: DateRangeHelper.currentWeekRange(),
        spentInMonth: 210,
        monthlyTotal: 890,
        weeklyStatus: .warning
    )
    .padding()
    .background(Theme.backgroundGradient)
}
