import SwiftUI

/// Minimal read-only row for a Plaid-imported transaction, used wherever connected-account
/// activity is shown (Dashboard, Activity, and Connected Accounts' "Review Imported
/// Transactions"). Deliberately shows ONLY description, date, and amount — connected activity is
/// a simple reference list for comparison against manually entered transactions, not an
/// editable/reviewable row. Never a category icon, the old unfinished-review-status badge, or an
/// Add/Match/Ignore/Exclude action — those belonged to the unfinished review flow this phase
/// removes from the user-facing connected-transaction UI. Never exposes a Plaid transaction id,
/// account id, or any other internal identifier.
struct ConnectedTransactionRow: View {
    let transaction: FinanceTransaction
    var isPrivacyModeEnabled: Bool = false

    private var signPrefix: String {
        switch transaction.type {
        case .expense: return "-"
        case .refund, .income: return "+"
        case .transfer, .creditCardPayment, .balanceAdjustment: return ""
        }
    }

    private var amountColor: Color {
        switch transaction.type {
        case .expense: return Theme.textPrimary
        case .refund, .income: return Theme.statusGood
        case .transfer, .creditCardPayment, .balanceAdjustment: return Theme.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transaction.displayName)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    // Preserved only because a pending transaction's amount/date can still change
                    // before it posts — omitting this would misrepresent it as final, which the
                    // description/date/amount-only requirement doesn't ask for.
                    if transaction.isPending {
                        Text("Pending")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.statusWarning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.statusWarning.opacity(0.15)))
                    }
                }

                Text(transaction.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
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
        ConnectedTransactionRow(transaction: FinanceTransaction(amount: 42.18, type: .expense, source: .plaid, note: "", originalDescription: "TRADER JOES #123"))
        ConnectedTransactionRow(transaction: FinanceTransaction(amount: 30, type: .expense, source: .plaid, note: "", isPending: true, originalDescription: "PENDING CHARGE"))
    }
    .padding()
    .background(Theme.backgroundGradient)
}
