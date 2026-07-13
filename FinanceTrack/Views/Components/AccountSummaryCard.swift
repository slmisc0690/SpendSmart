import SwiftUI

/// One tile in the Accounts screen's summary row. Similar to `StatCard`, but also supports a
/// plain (non-currency) value like an account count, which shouldn't be privacy-masked or
/// currency-formatted.
struct AccountSummaryCard: View {
    let title: String
    let systemIconName: String
    /// Set for a currency tile (privacy-aware). Leave nil and use `plainValue` for a count tile.
    var amount: Decimal? = nil
    var plainValue: String? = nil
    let subtitle: String
    let accentColor: Color
    var isPrivacyModeEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Image(systemName: systemIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(accentColor.opacity(0.16)))

            Group {
                if let amount {
                    PrivacyAmountView(
                        amount: amount,
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: Theme.amountFont(19),
                        color: Theme.textPrimary
                    )
                } else {
                    Text(plainValue ?? "\u{2014}")
                        .font(Theme.amountFont(19))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Spacing.sm) {
        AccountSummaryCard(title: "Cash Available", systemIconName: "banknote.fill", amount: 16681.55, subtitle: "Checking, savings & cash", accentColor: Theme.statusGood)
        AccountSummaryCard(title: "Active Accounts", systemIconName: "person.crop.circle.fill", plainValue: "4", subtitle: "4 accounts", accentColor: Theme.accentSecondary)
    }
    .padding()
    .background(Theme.backgroundGradient)
}
