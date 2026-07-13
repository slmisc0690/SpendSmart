import SwiftUI

/// Full account row for the Accounts list: icon, name, type/last-4/institution, balance, and
/// (for credit cards) utilization, limit, available credit, due date, and minimum payment.
/// Tapping the card opens its detail/edit surface; the trailing menu offers Edit, Adjust Balance,
/// and Archive.
struct AccountCard: View {
    let account: Account
    var isPrivacyModeEnabled: Bool = false
    var onSelect: () -> Void
    var onEdit: () -> Void
    var onAdjustBalance: () -> Void
    var onArchive: () -> Void

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

    private var availableCredit: Decimal? {
        CreditUtilizationCalculator.availableCredit(balance: account.currentBalance, limit: account.creditLimit)
    }

    var body: some View {
        Button(action: onSelect) {
            CardBackground(tint: tint) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    header

                    PrivacyAmountView(
                        amount: account.currentBalance,
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: Theme.amountFont(24),
                        color: Theme.textPrimary
                    )

                    if account.type == .creditCard {
                        creditCardDetails
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .top) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: account.type.systemIconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(tint.opacity(0.18)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitleParts.joined(separator: " \u{00B7} "))
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Menu {
                Button("Edit Account", systemImage: "pencil", action: onEdit)
                Button("Adjust Balance", systemImage: "slider.horizontal.3", action: onAdjustBalance)
                Divider()
                Button("Archive Account", systemImage: "archivebox", role: .destructive, action: onArchive)
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Account Options")
        }
    }

    private var creditCardDetails: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            CreditUtilizationView(balance: account.currentBalance, limit: account.creditLimit)

            HStack {
                if let limit = account.creditLimit {
                    labeledAmount(title: "Limit", amount: limit)
                }
                Spacer()
                if let availableCredit {
                    labeledAmount(title: "Available", amount: availableCredit)
                }
            }

            if account.paymentDueDate != nil || account.minimumPayment != nil {
                HStack {
                    if let dueDate = account.paymentDueDate {
                        labeledValue(title: "Payment Due", value: dueDate.formatted(date: .abbreviated, time: .omitted))
                    }
                    Spacer()
                    if let minimumPayment = account.minimumPayment {
                        labeledAmount(title: "Min. Payment", amount: minimumPayment)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func labeledValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func labeledAmount(title: String, amount: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.bodyFont,
                color: Theme.textSecondary
            )
        }
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.md) {
        AccountCard(
            account: Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55, institutionName: "Chase"),
            onSelect: {}, onEdit: {}, onAdjustBalance: {}, onArchive: {}
        )
        AccountCard(
            account: Account(name: "Amex Gold", type: .creditCard, currentBalance: 812.40, institutionName: "American Express", lastFourDigits: "4821", creditLimit: 8000, minimumPayment: 35, colorHex: "#C7A15A"),
            onSelect: {}, onEdit: {}, onAdjustBalance: {}, onArchive: {}
        )
    }
    .padding()
    .background(Theme.backgroundGradient)
}
