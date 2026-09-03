import SwiftUI
import SwiftData

/// CHECK PAYMENT PHASE — lets Scott correct a Check transaction's check number after the fact,
/// following the exact same narrow-scope pattern as `TransactionAmountEditView`/
/// `TransactionBillTagEditView`: ONLY `checkNumber` is touched here — amount, balance, date,
/// category, and every other field are never modified by this screen. Only ever presented for a
/// transaction that already has a check number (see `isEligible`) — this app has no general
/// "change the transaction type" editor anywhere, so the Part 7 "type changes away from Check"
/// scenario this feature's own brief anticipated cannot actually arise post-creation today.
struct CheckNumberEditView: View {
    @Bindable var transaction: FinanceTransaction
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var allTransactions: [FinanceTransaction]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var checkNumber: String
    @State private var isPresentingDuplicateCheckWarning = false

    init(transaction: FinanceTransaction) {
        self.transaction = transaction
        _checkNumber = State(initialValue: transaction.checkNumber ?? "")
    }

    static func isEligible(_ transaction: FinanceTransaction) -> Bool {
        transaction.checkNumber != nil
    }

    private var trimmedCheckNumber: String {
        checkNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool { !trimmedCheckNumber.isEmpty }

    /// Same "same Manual Account only, trimmed comparison, excluding this transaction itself"
    /// scoping as `AddExpenseView.duplicateCheckNumberWarningMessage`.
    private var duplicateCheckNumberWarningMessage: String? {
        guard isValid, let account = transaction.account else { return nil }
        let existingNumbers = allTransactions
            .filter { $0.account?.id == account.id && $0.id != transaction.id }
            .compactMap { $0.checkNumber?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard existingNumbers.contains(trimmedCheckNumber) else { return nil }
        return "Check \(trimmedCheckNumber) already exists in this register."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Check Number")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            TextField("e.g. 001284", text: $checkNumber)
                                .keyboardType(.numberPad)
                                .padding(Theme.Spacing.sm)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                        .fill(Theme.cardSurface)
                                )
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    if !isValid {
                        Text("Enter a check number.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.statusOver)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    PremiumActionButton(title: "Save", systemIconName: "checkmark") {
                        attemptSave()
                    }
                    .disabled(!isValid)
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Edit Check Number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .confirmationDialog(
                duplicateCheckNumberWarningMessage ?? "",
                isPresented: $isPresentingDuplicateCheckWarning,
                titleVisibility: .visible
            ) {
                Button("Save Anyway") { save() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }

    private func attemptSave() {
        guard isValid else { return }
        if duplicateCheckNumberWarningMessage != nil {
            isPresentingDuplicateCheckWarning = true
            return
        }
        save()
    }

    /// Amount/balance/date/category/account are never touched — this is exclusively a
    /// `checkNumber` correction, matching `TransactionAmountEditView`'s own "only the one field
    /// this screen owns" guarantee.
    private func save() {
        guard isValid else { return }
        transaction.checkNumber = trimmedCheckNumber
        transaction.updatedAt = .now
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    let account = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55)
    let transaction = FinanceTransaction(amount: 125.40, type: .expense, note: "ABC Electric", account: account, checkNumber: "001284")
    return CheckNumberEditView(transaction: transaction)
        .modelContainer(SampleData.previewContainer)
}
