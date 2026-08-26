import SwiftUI
import SwiftData

/// PAY BILLS BATCH ENTRY — lets the user pick a Monthly Plan bill-timing group (Beginning of
/// Month / Mid-Month / End of Month) and create one normal Manual Account withdrawal per checked
/// bill in that group, in a single batch. Monthly Plan itself is read-only from this screen: bill
/// name/amount/timing/active-state are only ever READ (via the same `FixedBillsTimingFilter`
/// Monthly Plan's own Fixed Bills section already uses), never written — an edited payment amount
/// here applies only to the transaction created for THIS batch, never back to the
/// `RecurringExpense` it was read from. Reuses the exact same transaction-creation/balance-update
/// authority (`ManualTransactionCreationService`) a normal single Add Withdrawal produces.
struct PayBillsView: View {
    let account: Account

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var allRecurringExpenses: [RecurringExpense]

    @State private var selectedTiming: PlanTiming?
    @State private var rows: [PayBillsRow] = []
    @State private var paymentDate: Date = .now
    @State private var isSubmitting = false
    @State private var hasAttemptedSubmit = false
    @State private var isPresentingSaveError = false

    /// Beginning/Mid/End only — the Monthly Plan bill-timing groups this feature pays from.
    /// `.weekly`/`.customDate` are real `PlanTiming` cases but are not "Monthly Plan bill-timing
    /// groups" in the sense this feature describes, so they're intentionally excluded here.
    private static let timingGroups: [PlanTiming] = [.beginningMonth, .midMonth, .endMonth]

    private var activeRecurringExpenses: [RecurringExpense] {
        allRecurringExpenses.filter { $0.isActive }
    }

    private func bills(for timing: PlanTiming) -> [RecurringExpense] {
        FixedBillsTimingFilter.apply(activeRecurringExpenses, timing: timing)
    }

    private var selectedBillsTotal: Decimal {
        rows.filter(\.isSelected).reduce(Decimal(0)) { $0 + ($1.amount ?? 0) }
    }

    private var hasAnySelection: Bool {
        rows.contains { $0.isSelected }
    }

    private var hasInvalidSelectedAmount: Bool {
        rows.contains { $0.isSelected && !(($0.amount ?? 0) > 0) }
    }

    private var isValid: Bool {
        hasAnySelection && !hasInvalidSelectedAmount
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selectedTiming {
                    billListView(for: selectedTiming)
                } else {
                    groupPickerView
                }
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(selectedTiming.map { "Pay Bills \u{2014} \($0.label)" } ?? "Pay Bills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .alert("Couldn't Save", isPresented: $isPresentingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("These bills couldn't be saved, so nothing in this batch was changed. Please try again.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Group picker

    private var groupPickerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Which bills are you paying?")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.Spacing.lg)

                CardBackground {
                    VStack(spacing: 0) {
                        ForEach(Array(Self.timingGroups.enumerated()), id: \.element) { index, timing in
                            Button {
                                selectTiming(timing)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(timing.label)
                                            .font(Theme.bodyFont)
                                            .foregroundStyle(Theme.textPrimary)
                                        let count = bills(for: timing).count
                                        Text(count == 1 ? "1 bill" : "\(count) bills")
                                            .font(Theme.captionFont)
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.vertical, Theme.Spacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < Self.timingGroups.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    /// Rebuilds `rows` fresh from Monthly Plan's CURRENT bill amounts every time a group is
    /// selected — reopening Pay Bills (or picking a group again after Cancel) always reloads
    /// whatever Monthly Plan currently says, never a stale amount from a prior batch.
    private func selectTiming(_ timing: PlanTiming) {
        rows = bills(for: timing).map { bill in
            PayBillsRow(bill: bill, isSelected: false, amount: FixedBillsTimingFilter.displayAmount(for: bill))
        }
        paymentDate = .now
        hasAttemptedSubmit = false
        selectedTiming = timing
    }

    // MARK: - Bill list

    @ViewBuilder
    private func billListView(for timing: PlanTiming) -> some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No Bills",
                systemImage: "list.bullet.rectangle",
                description: Text("There are no active \(timing.label) bills in Monthly Plan.")
            )
        } else {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    dateSection
                    billRowsSection
                    totalSection

                    if hasAttemptedSubmit && hasInvalidSelectedAmount {
                        invalidAmountBanner
                    }

                    PremiumActionButton(title: "Pay Selected Bills", systemIconName: "checkmark") {
                        submit()
                    }
                    .disabled(!isValid || isSubmitting)
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
        }
    }

    private var dateSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            HStack {
                Text("Payment Date")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                DatePicker("Payment Date", selection: $paymentDate, displayedComponents: .date)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var billRowsSection: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.md) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    billRow(index: index)
                    if index < rows.count - 1 {
                        Divider().overlay(Theme.cardStroke)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func billRow(index: Int) -> some View {
        let row = rows[index]
        return HStack(spacing: Theme.Spacing.sm) {
            Button {
                rows[index].isSelected.toggle()
            } label: {
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(row.isSelected ? Theme.accent : Theme.textTertiary)
            }
            .buttonStyle(.plain)

            Text(row.bill.name)
                .font(Theme.bodyFont)
                .foregroundStyle(row.isSelected ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.sm)

            CurrencyAmountField(
                amount: $rows[index].amount,
                style: .inline,
                isDisabled: !row.isSelected,
                isInvalid: hasAttemptedSubmit && row.isSelected && !((row.amount ?? 0) > 0),
                accessibilityLabel: "\(row.bill.name) payment amount"
            )
            .frame(width: 110)
        }
    }

    private var totalSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            HStack {
                Text("Selected Bills Total")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                PrivacyAmountView(
                    amount: selectedBillsTotal,
                    isPrivacyModeEnabled: false,
                    font: Theme.headlineFont,
                    color: Theme.textPrimary
                )
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var invalidAmountBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.statusOver)
            Text("Every selected bill needs an amount greater than $0.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.statusOver)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.statusOver.opacity(0.12)))
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Submit

    /// Creates exactly one `FinanceTransaction` per checked row via
    /// `ManualTransactionCreationService` (same shape/balance-update a normal single Add
    /// Withdrawal produces), then a single explicit `context.save()` for the whole batch.
    ///
    /// FAILURE/RECOVERY CORRECTION — `ModelContext.rollback()` was investigated first (per this
    /// task's own preferred narrow solution). At the time, it was empirically found to NOT restore
    /// an in-place property mutation on an already-tracked `@Model` object; on a later SDK this
    /// behavior was found to have changed (see
    /// `testRollbackBehaviorOnCurrentSDKRestoresBalanceButProductionDoesNotDependOnIt`'s own doc
    /// comment for the full history) — but this code was never revised back to depend on it either
    /// way, since relying on undocumented, SDK-version-dependent framework behavior for a money
    /// balance would be fragile regardless of which direction it currently happens to go. Instead,
    /// the original balance is captured before the loop and every transaction this attempt creates
    /// is tracked; on a `save()` failure, exactly those transactions are deleted and the balance is
    /// reset to its captured original value — both directly on this same live context, so the
    /// register list and balance the user is looking at update immediately, without a second
    /// save() attempt (which could fail again for the same underlying reason). This is the
    /// smallest explicit recovery this task's own scope calls for, not a general rollback
    /// framework.
    private func submit() {
        hasAttemptedSubmit = true
        guard isValid, !isSubmitting else { return }
        isSubmitting = true

        let originalBalance = account.currentBalance
        var createdTransactions: [FinanceTransaction] = []

        for row in rows where row.isSelected {
            guard let amount = row.amount, amount > 0 else { continue }
            let transaction = ManualTransactionCreationService.createExpense(
                amount: amount,
                date: paymentDate,
                note: row.bill.name,
                account: account,
                category: row.bill.category,
                linkedRecurringExpense: row.bill,
                context: modelContext
            )
            createdTransactions.append(transaction)
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            for transaction in createdTransactions {
                modelContext.delete(transaction)
            }
            account.currentBalance = originalBalance
            isSubmitting = false
            isPresentingSaveError = true
        }
    }
}

/// One draft row in the Pay Bills batch — a local, temporary edit of a `RecurringExpense`'s
/// display amount/selection state. Never written back to the `RecurringExpense` itself; discarded
/// entirely if the user taps Cancel.
private struct PayBillsRow: Identifiable {
    let bill: RecurringExpense
    var isSelected: Bool
    var amount: Decimal?
    var id: UUID { bill.id }
}

#Preview {
    PayBillsView(account: Account(name: "Everyday Checking", type: .checking, currentBalance: 5000))
        .modelContainer(SampleData.previewContainer)
}
