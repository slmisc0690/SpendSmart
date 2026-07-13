import SwiftUI

/// A card listing selectable account rows (name, type, balance, last 4 digits, institution).
struct AccountPickerCard: View {
    let accounts: [Account]
    @Binding var selectedAccount: Account?
    var isPrivacyModeEnabled: Bool = false

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Account")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(accounts) { account in
                        AccountPickerRow(
                            account: account,
                            isSelected: selectedAccount?.id == account.id,
                            isPrivacyModeEnabled: isPrivacyModeEnabled
                        ) {
                            selectedAccount = account
                        }
                    }
                }
            }
        }
    }
}

private struct AccountPickerRow: View {
    let account: Account
    let isSelected: Bool
    var isPrivacyModeEnabled: Bool
    var action: () -> Void

    private var tint: Color { Color(hex: account.colorHex) ?? Theme.accent }

    private var subtitleParts: [String] {
        var parts = [account.type.label]
        if let lastFour = account.lastFourDigits, !lastFour.isEmpty {
            parts.append("\u{2022}\u{2022}\u{2022}\u{2022} \(lastFour)")
        }
        if let institution = account.institutionName, !institution.isEmpty {
            parts.append(institution)
        }
        return parts
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: account.type.systemIconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.opacity(0.16)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitleParts.joined(separator: " \u{00B7} "))
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Spacing.sm)

                PrivacyAmountView(
                    amount: account.currentBalance,
                    isPrivacyModeEnabled: isPrivacyModeEnabled,
                    font: Theme.captionFont,
                    color: Theme.textSecondary
                )

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary.opacity(0.5))
            }
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.12) : Theme.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AccountPickerCard(
        accounts: [
            Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55, institutionName: "Chase"),
            Account(name: "Amex Gold", type: .creditCard, currentBalance: 812.40, institutionName: "American Express", lastFourDigits: "4821"),
        ],
        selectedAccount: .constant(nil)
    )
    .padding()
    .background(Theme.backgroundGradient)
}
