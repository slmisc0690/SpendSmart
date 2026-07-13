import SwiftUI

/// Previous/next month navigation with the current month label, plus an optional "This Month"
/// shortcut when a past/future month is selected.
struct MonthSelectorView: View {
    let monthInterval: DateInterval
    let isCurrentMonth: Bool
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onToday: () -> Void

    var body: some View {
        HStack {
            iconButton(systemName: "chevron.left", action: onPrevious)

            Spacer()

            VStack(spacing: 2) {
                Text(DateRangeHelper.monthDisplayText(for: monthInterval))
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                if !isCurrentMonth {
                    Button("This Month", action: onToday)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(minHeight: 34)

            Spacer()

            iconButton(systemName: "chevron.right", action: onNext)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.cardSurface))
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MonthSelectorView(
        monthInterval: DateRangeHelper.currentMonthRange(),
        isCurrentMonth: false,
        onPrevious: {},
        onNext: {},
        onToday: {}
    )
    .padding(.vertical)
    .background(Theme.backgroundGradient)
}
