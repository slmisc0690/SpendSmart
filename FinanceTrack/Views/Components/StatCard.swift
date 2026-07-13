import SwiftUI

/// One tile in the dashboard's Quick Stats grid: an icon, a large amount, a label, and a
/// small helper subtitle.
struct StatCard: View {
    let title: String
    let systemIconName: String
    let amount: Decimal
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

            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.amountFont(19),
                color: Theme.textPrimary
            )
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
        StatCard(title: "Credit Card", systemIconName: "creditcard.fill", amount: 812.40, subtitle: "1 account", accentColor: Theme.statusOver)
        StatCard(title: "Cash Balance", systemIconName: "banknote.fill", amount: 16681.55, subtitle: "Checking & savings", accentColor: Theme.statusGood)
    }
    .padding()
    .background(Theme.backgroundGradient)
}
