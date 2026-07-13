import SwiftUI

/// One row in an account spending breakdown: icon, name/type, net amount, and a
/// percent-of-total bar. Takes a `BudgetCalculator.AccountTotal` directly so the view never
/// recomputes spending math. Used by the Monthly screen's "Spending by Account" section.
struct AccountBreakdownRow: View {
    let accountTotal: BudgetCalculator.AccountTotal
    /// The period's total net spend, used only to size the percent bar/label.
    let periodTotal: Decimal
    var isPrivacyModeEnabled: Bool = false

    private var percent: Double {
        guard periodTotal > 0 else { return 0 }
        let ratio = NSDecimalNumber(decimal: accountTotal.total / periodTotal).doubleValue
        return min(max(ratio, 0), 1)
    }

    private var tint: Color {
        Color(hex: accountTotal.account.colorHex) ?? Theme.accent
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: accountTotal.account.type.systemIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.16)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(accountTotal.account.name)
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text(accountTotal.account.type.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    PrivacyAmountView(
                        amount: accountTotal.total,
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: Theme.bodyFont,
                        color: Theme.textPrimary
                    )
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(geometry.size.width * percent, percent > 0 ? 4 : 0))
                    }
                }
                .frame(height: 6)

                Text("\(Int(percent * 100))% of monthly spending")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

#Preview {
    let account = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55)
    return AccountBreakdownRow(
        accountTotal: .init(account: account, total: 412.30),
        periodTotal: 1400
    )
    .padding()
    .background(Theme.backgroundGradient)
}
