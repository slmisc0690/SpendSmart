import SwiftUI

/// A single row in a transaction list: category icon, name, category/date/account line, amount,
/// and pending/excluded indicators. Used by the dashboard's Recent Activity list.
struct TransactionRow: View {
    let transaction: FinanceTransaction
    var isPrivacyModeEnabled: Bool = false
    /// Opt-in type badge (Expense/Refund/Credit Card Payment/Balance Adjustment/Transfer),
    /// shown next to the transaction name — used by Activity, where a mixed-type history needs
    /// to be scannable at a glance. Off by default so existing call sites (Dashboard, Weekly)
    /// keep their current, quieter appearance.
    var showsTypeBadge: Bool = false
    /// The safe display label for a connected account this general Manual Transaction is
    /// attributed to via "Paid With" (see `ConnectedAccountOptionPresenter`), resolved by the
    /// caller — this stays a pure view with no `PlaidConnectionManager` dependency. `nil` for a
    /// Plaid-imported row (shown via `ConnectedTransactionRow` instead), a Manual Account-owned
    /// row, or a legacy Manual Transaction with no attribution — the extra line is simply
    /// omitted, never a placeholder.
    var connectedAccountLabel: String? = nil

    private var accentColor: Color {
        Theme.categoryColor(named: transaction.category?.colorName ?? "")
    }

    private var typeBadgeColor: Color {
        switch transaction.type {
        case .expense: return Theme.statusOver
        case .refund, .income: return Theme.statusGood
        case .creditCardPayment: return Theme.accent
        case .transfer: return Theme.accentSecondary
        case .balanceAdjustment: return Theme.textTertiary
        }
    }

    private var signPrefix: String {
        switch transaction.type {
        case .expense: return "-"
        case .refund, .income: return "+"
        case .transfer, .creditCardPayment, .balanceAdjustment: return ""
        }
    }

    private var amountColor: Color {
        switch transaction.type {
        case .expense: return Theme.textSecondary
        case .refund, .income: return Theme.statusGood
        case .transfer, .creditCardPayment, .balanceAdjustment: return Theme.textTertiary
        }
    }

    private var subtitleParts: [String] {
        var parts: [String] = []
        if let categoryName = transaction.category?.name { parts.append(categoryName) }
        parts.append(transaction.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        if let accountName = transaction.account?.name { parts.append(accountName) }
        return parts
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: transaction.category?.iconName ?? "circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(accentColor.opacity(0.16)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transaction.displayName)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if transaction.isPending {
                        Text("Pending")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.statusWarning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.statusWarning.opacity(0.15)))
                    }

                    if transaction.isExcludedFromReports {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    if showsTypeBadge {
                        Text(transaction.type.label)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(typeBadgeColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(typeBadgeColor.opacity(0.15)))
                            .lineLimit(1)
                    }
                }

                Text(subtitleParts.joined(separator: " \u{00B7} "))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)

                if let connectedAccountLabel {
                    Text(connectedAccountLabel)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            PrivacyAmountView(
                amount: transaction.amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.bodyFont,
                color: amountColor,
                prefix: signPrefix
            )
        }
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.md) {
        TransactionRow(transaction: FinanceTransaction(amount: 42.18, type: .expense, note: "Trader Joe's"))
        TransactionRow(transaction: FinanceTransaction(amount: 30, type: .refund, note: "Shoes refund", isPending: true))
    }
    .padding()
    .background(Theme.backgroundGradient)
}
