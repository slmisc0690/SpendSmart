import SwiftUI
import SwiftData

/// EDITABLE BILL TAGGING — lets the user correct/set an ALREADY-SAVED Manual Account register
/// transaction's bill classification after the fact (e.g. retroactively tagging a Pay Bills
/// payment made before this feature existed, when the automatic backfill in
/// `BillPaymentBackfillService` couldn't confidently match it). Deliberately scoped to ONLY the
/// bill-tag fields (`linkedRecurringExpense`/`isOneTimeBillEntry`) — amount, date, note, category,
/// and the account balance are never touched here; this is not a general transaction editor
/// (no such screen exists yet in this app). Reuses the exact same four-choice picker shape and
/// "New Monthly Bill" confirm/timing flow `AddExpenseView.billTagSection` uses at creation time.
struct TransactionBillTagEditView: View {
    @Bindable var transaction: FinanceTransaction
    @Query private var allRecurringExpenses: [RecurringExpense]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum BillTagChoice {
        case notABill
        case existingBill
        case newMonthlyBill
        case oneTimeEntry
        /// See `AddExpenseView.BillTagChoice.notIncludedInMonthly`'s own header — identical
        /// meaning here: never linked to a bill, forced `isExcludedFromReports = true` at save.
        case notIncludedInMonthly
    }

    @State private var billTagChoice: BillTagChoice
    @State private var selectedExistingBillID: UUID?
    /// See `AddExpenseView`'s own identically-named property for why this is kept distinct from
    /// `selectedExistingBillID` — it stays set even when a unique bill couldn't be resolved.
    @State private var selectedExistingBillTiming: PlanTiming?
    @State private var newBillTiming: PlanTiming?
    @State private var isPresentingNewBillAddConfirmation = false
    @State private var isPresentingNewBillTimingChoice = false

    init(transaction: FinanceTransaction) {
        self.transaction = transaction
        if let bill = transaction.linkedRecurringExpense {
            _billTagChoice = State(initialValue: .existingBill)
            _selectedExistingBillID = State(initialValue: bill.id)
            _selectedExistingBillTiming = State(initialValue: bill.timing)
        } else if let timing = transaction.billTiming {
            _billTagChoice = State(initialValue: .existingBill)
            _selectedExistingBillTiming = State(initialValue: timing)
        } else if transaction.isOneTimeBillEntry {
            _billTagChoice = State(initialValue: .oneTimeEntry)
        } else if transaction.isExcludedFromReports {
            _billTagChoice = State(initialValue: .notIncludedInMonthly)
        } else {
            _billTagChoice = State(initialValue: .notABill)
        }
    }

    private var activeRecurringExpenses: [RecurringExpense] {
        allRecurringExpenses.filter(\.isActive)
    }

    /// TAG-SIMPLIFICATION CORRECTION — see `AddExpenseView.uniqueActiveBill(timing:)`'s own
    /// header; this is the identical rule, duplicated here since this view has no shared base
    /// with that one. `nil` (zero or multiple active bills sharing that timing) is never guessed.
    private func uniqueActiveBill(timing: PlanTiming) -> RecurringExpense? {
        let matches = activeRecurringExpenses.filter { $0.timing == timing }
        return matches.count == 1 ? matches.first : nil
    }

    /// DEPOSIT-TAGGING GAP FIX — a deposit (or any non-expense type) can never be a bill payment;
    /// this view previously showed the full bill-tag picker regardless of `transaction.type`,
    /// unlike `AddExpenseView.showsBillTagSection`'s own `type == .expense` gate. Matches that
    /// same restriction now.
    private var showsBillTagPicker: Bool {
        transaction.type == .expense
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if showsBillTagPicker {
                        CardBackground {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                Text("Is this a Bill?")
                                    .font(Theme.headlineFont)
                                    .foregroundStyle(Theme.textPrimary)

                                VStack(spacing: Theme.Spacing.sm) {
                                    tagRow(icon: "minus.circle", label: "Not a Bill", isSelected: billTagChoice == .notABill) {
                                        billTagChoice = .notABill
                                        selectedExistingBillID = nil
                                        selectedExistingBillTiming = nil
                                        newBillTiming = nil
                                    }

                                    // Always shown, never hidden for ambiguity — see
                                    // `AddExpenseView`'s identical comment on its own picker.
                                    ForEach([PlanTiming.beginningMonth, .midMonth, .endMonth], id: \.self) { timing in
                                        let bill = uniqueActiveBill(timing: timing)
                                        tagRow(
                                            icon: "checklist",
                                            label: "\(timing.label) Bill",
                                            isSelected: billTagChoice == .existingBill && selectedExistingBillTiming == timing
                                        ) {
                                            billTagChoice = .existingBill
                                            selectedExistingBillID = bill?.id
                                            selectedExistingBillTiming = timing
                                            newBillTiming = nil
                                        }
                                    }

                                    tagRow(icon: "plus.circle", label: "New Monthly Bill", isSelected: billTagChoice == .newMonthlyBill) {
                                        isPresentingNewBillAddConfirmation = true
                                    }

                                    tagRow(icon: "calendar.badge.exclamationmark", label: "One Time Entry", isSelected: billTagChoice == .oneTimeEntry) {
                                        billTagChoice = .oneTimeEntry
                                        selectedExistingBillID = nil
                                        selectedExistingBillTiming = nil
                                        newBillTiming = nil
                                    }

                                    tagRow(icon: "eye.slash", label: "Not Included in Monthly", isSelected: billTagChoice == .notIncludedInMonthly) {
                                        billTagChoice = .notIncludedInMonthly
                                        selectedExistingBillID = nil
                                        selectedExistingBillTiming = nil
                                        newBillTiming = nil
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    } else {
                        CardBackground {
                            Text("Only an expense can be tagged as a Bill — deposits and other entry types are never eligible.")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }

                    PremiumActionButton(title: "Save", systemIconName: "checkmark") {
                        save()
                    }
                    .disabled(!showsBillTagPicker)
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Edit Bill Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .confirmationDialog(
                "This is not part of your monthly plan, do you want to add it?",
                isPresented: $isPresentingNewBillAddConfirmation,
                titleVisibility: .visible
            ) {
                Button("Yes") { isPresentingNewBillTimingChoice = true }
                Button("No", role: .cancel) {}
            }
            .confirmationDialog(
                "Is this a Mid, End, or Beginning of Month bill?",
                isPresented: $isPresentingNewBillTimingChoice,
                titleVisibility: .visible
            ) {
                Button("Beginning of Month") {
                    newBillTiming = .beginningMonth
                    billTagChoice = .newMonthlyBill
                }
                Button("Mid-Month") {
                    newBillTiming = .midMonth
                    billTagChoice = .newMonthlyBill
                }
                Button("End of Month") {
                    newBillTiming = .endMonth
                    billTagChoice = .newMonthlyBill
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func tagRow(icon: String, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((isSelected ? Theme.accent : Theme.textTertiary).opacity(0.16)))
                Text(label)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        switch billTagChoice {
        case .notABill:
            transaction.linkedRecurringExpense = nil
            transaction.isOneTimeBillEntry = false
            transaction.billTiming = nil
        case .existingBill:
            transaction.linkedRecurringExpense = activeRecurringExpenses.first { $0.id == selectedExistingBillID }
            transaction.isOneTimeBillEntry = false
            // Label-only fallback when the timing couldn't be resolved to exactly one bill — see
            // `AddExpenseView.save()`'s identical fallback for why.
            transaction.billTiming = transaction.linkedRecurringExpense == nil ? selectedExistingBillTiming : nil
        case .newMonthlyBill:
            if let timing = newBillTiming {
                let newBill = RecurringExpense(name: transaction.note.isEmpty ? "New Bill" : transaction.note, amount: transaction.amount, category: transaction.category, timing: timing)
                modelContext.insert(newBill)
                transaction.linkedRecurringExpense = newBill
            }
            transaction.isOneTimeBillEntry = false
            transaction.billTiming = nil
        case .oneTimeEntry:
            transaction.linkedRecurringExpense = nil
            transaction.isOneTimeBillEntry = true
            transaction.billTiming = nil
        case .notIncludedInMonthly:
            transaction.linkedRecurringExpense = nil
            transaction.isOneTimeBillEntry = false
            transaction.billTiming = nil
        }
        if billTagChoice == .notIncludedInMonthly {
            transaction.isExcludedFromReports = true
        }
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    let account = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55)
    let transaction = FinanceTransaction(amount: 100, note: "Rent", account: account)
    return TransactionBillTagEditView(transaction: transaction)
        .modelContainer(SampleData.previewContainer)
}
