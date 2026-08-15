import SwiftUI
import SwiftData

/// EDITABLE AMOUNT — lets the user correct a Manual Account register entry's amount after the
/// fact (e.g. a typo on a deposit) without deleting and re-adding it. Scoped to ONLY the amount
/// field and the account balance it drives — date, note, category, account, and bill tagging are
/// never touched here; like `TransactionBillTagEditView`, this is not a general transaction
/// editor. Restricted to `.expense`/`.refund`/`.income` — the three single-account-effect types
/// this app's own Manual Account entry flows ever create (`.transfer`/`.creditCardPayment` move
/// money between TWO accounts and are out of scope; `.balanceAdjustment` already sets the balance
/// directly rather than applying a delta) — see `isEligible`.
struct TransactionAmountEditView: View {
    @Bindable var transaction: FinanceTransaction
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Decimal?

    init(transaction: FinanceTransaction) {
        self.transaction = transaction
        _amount = State(initialValue: transaction.amount)
    }

    static func isEligible(_ transaction: FinanceTransaction) -> Bool {
        switch transaction.type {
        case .expense, .refund, .income: return true
        // Transfer WD/Dep move money between TWO accounts (this one and its counterparty), same
        // reason `.transfer`/`.creditCardPayment` are already out of scope for this single-account
        // editor — see this view's own header.
        case .transfer, .creditCardPayment, .balanceAdjustment, .transferWithdrawal, .transferDeposit:
            return false
        }
    }

    private var isValid: Bool {
        guard let amount else { return false }
        return amount > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Amount")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: $amount,
                                style: .hero,
                                isInvalid: !isValid,
                                accessibilityLabel: "Amount"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    PremiumActionButton(title: "Save", systemIconName: "checkmark") {
                        save()
                    }
                    .disabled(!isValid)
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Edit Amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Reverses the transaction's CURRENT amount's balance effect, stores the new amount, then
    /// reapplies it at the new amount — never a raw `account.currentBalance = ...` overwrite,
    /// so the account's balance authority stays entirely inside `AccountBalanceManager`, exactly
    /// like every other mutation path in this app.
    private func save() {
        guard let newAmount = amount, newAmount > 0, let account = transaction.account,
              Self.isEligible(transaction) else { return }

        Self.applyDelta(type: transaction.type, amount: -transaction.amount, to: account)
        transaction.amount = newAmount
        transaction.updatedAt = .now
        Self.applyDelta(type: transaction.type, amount: newAmount, to: account)

        try? modelContext.save()
        dismiss()
    }

    private static func applyDelta(type: TransactionType, amount: Decimal, to account: Account) {
        switch type {
        case .expense: AccountBalanceManager.applyExpense(amount: amount, to: account)
        case .refund: AccountBalanceManager.applyRefund(amount: amount, to: account)
        case .income: AccountBalanceManager.applyIncome(amount: amount, to: account)
        case .transfer, .creditCardPayment, .balanceAdjustment, .transferWithdrawal, .transferDeposit: break
        }
    }
}

#Preview {
    let account = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55)
    let transaction = FinanceTransaction(amount: 100, type: .income, note: "Deposit", account: account)
    return TransactionAmountEditView(transaction: transaction)
        .modelContainer(SampleData.previewContainer)
}
