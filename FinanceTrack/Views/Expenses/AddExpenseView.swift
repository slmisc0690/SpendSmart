import SwiftUI
import SwiftData

/// Premium manual entry screen for a single expense or refund. Applies the corresponding
/// `AccountBalanceManager` mutation on save so the account balance and the new
/// `FinanceTransaction` record never drift out of sync.
struct AddExpenseView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode

    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    @Query(sort: \Category.name) private var allCategories: [Category]

    @State private var amount: Decimal?
    @State private var note: String = ""
    @State private var date: Date = .now
    @State private var type: TransactionType = .expense
    @State private var selectedAccount: Account?
    @State private var selectedCategory: Category?
    @State private var countsTowardWeeklyBudget: Bool = true
    /// Defaults to `true` — "no account selected" preserves today's always-counts behavior, and
    /// this also covers cash/unsupported-payment-method purchases that never get an account at
    /// all. Overwritten by `selectedAccount`'s own default the moment an account is picked,
    /// unless the user has already touched the toggle themselves this session (see
    /// `hasManuallyChangedMonthlySpendingToggle`).
    @State private var countsTowardMonthlySpending: Bool = true
    /// True once the user directly taps the "Count toward Monthly Spending" toggle — from then
    /// on, changing `selectedAccount` must never silently overwrite their explicit choice.
    @State private var hasManuallyChangedMonthlySpendingToggle = false
    @State private var isExcludedFromReports: Bool = false
    @State private var isPending: Bool = false
    @State private var isPresentingAddAccount = false
    @State private var hasAttemptedSave = false
    @State private var isPresentingDiscardConfirmation = false

    /// Opening "Add Expense" from a specific account's own detail/register screen preselects
    /// that account and seeds the monthly-spending toggle from its default — equivalent to the
    /// user picking that account by hand, just done up front.
    init(preselectedAccount: Account? = nil) {
        _selectedAccount = State(initialValue: preselectedAccount)
        _countsTowardMonthlySpending = State(initialValue: preselectedAccount?.defaultCountsTowardMonthlySpending ?? true)
    }

    private var activeAccounts: [Account] {
        allAccounts.filter { !$0.isArchived }
    }

    /// Archived categories must never appear as a choice for a *new* expense — they stay visible
    /// only on transactions that already reference them.
    private var activeCategories: [Category] {
        allCategories.filter { !$0.isArchived }
    }

    /// Clean, plain-English validation messages — never a crash, always an actionable next step.
    private var validationMessages: [String] {
        var messages: [String] = []
        if amount == nil {
            messages.append("Amount is required.")
        } else if (amount ?? 0) <= 0 {
            messages.append("Amount must be greater than 0.")
        }
        if selectedAccount == nil {
            messages.append("Account is required.")
        }
        return messages
    }

    private var isValid: Bool { validationMessages.isEmpty }

    /// This screen intentionally does not autosave — it creates a `FinanceTransaction` and
    /// applies a balance change via `AccountBalanceManager`, and autosaving that on every
    /// keystroke risks applying the same expense more than once. Instead, unsaved edits are
    /// protected with a confirm-on-dismiss prompt rather than silently discarded.
    private var hasMeaningfulInput: Bool {
        amount != nil
            || !note.trimmingCharacters(in: .whitespaces).isEmpty
            || selectedAccount != nil
            || selectedCategory != nil
    }
    private var shouldConfirmDiscard: Bool { hasMeaningfulInput }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    amountSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    typeSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    dateSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    if activeAccounts.isEmpty {
                        EmptyStateCard(
                            systemIconName: "creditcard.fill",
                            message: "Add a manually tracked account before logging an expense. Connected banks and credit cards are managed in Connected Accounts.",
                            actionTitle: "Add Manual Tracked Account"
                        ) {
                            isPresentingAddAccount = true
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    } else {
                        AccountPickerCard(
                            accounts: activeAccounts,
                            selectedAccount: $selectedAccount,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                        .padding(.horizontal, Theme.Spacing.lg)
                    }

                    CategoryPickerCard(categories: activeCategories, selectedCategory: $selectedCategory)
                        .padding(.horizontal, Theme.Spacing.lg)

                    detailsSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    optionsSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    if hasAttemptedSave, !validationMessages.isEmpty {
                        validationCard
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnBackgroundTap()
            .navigationTitle(type == .expense ? "Add Expense" : "Add Refund")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if shouldConfirmDiscard {
                            isPresentingDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        attemptSave()
                    }
                    .disabled(!isValid)
                }
            }
            .interactiveDismissDisabled(shouldConfirmDiscard)
            .confirmationDialog(
                "Discard unfinished entry?",
                isPresented: $isPresentingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .sheet(isPresented: $isPresentingAddAccount) {
                AddAccountView()
            }
            .onChange(of: type) { _, _ in
                // Expense and refund both default to counting toward the weekly budget;
                // the user can still turn it off after switching.
                countsTowardWeeklyBudget = true
            }
            .onChange(of: selectedAccount) { _, newAccount in
                // Only apply the newly-selected account's own default if the user hasn't already
                // made an explicit choice this session — an explicit choice must survive an
                // account change, never get silently overwritten by it.
                guard !hasManuallyChangedMonthlySpendingToggle else { return }
                countsTowardMonthlySpending = newAccount?.defaultCountsTowardMonthlySpending ?? true
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var amountSection: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                Text(type == .expense ? "Expense Amount" : "Refund Amount")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                CurrencyAmountField(
                    amount: $amount,
                    style: .hero,
                    isInvalid: hasAttemptedSave && (amount ?? 0) <= 0,
                    accessibilityLabel: type == .expense ? "Expense amount" : "Refund amount"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var typeSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Type")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Picker("Type", selection: $type) {
                    ForEach([TransactionType.expense, .refund]) { candidateType in
                        Text(candidateType.label).tag(candidateType)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    /// Placed right after Type, near the top of the form, so changing the date away from today
    /// (the default) doesn't require scrolling past account/category first.
    private var dateSection: some View {
        CardBackground {
            HStack {
                Text("Date")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
        }
    }

    private var detailsSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Details")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note (optional)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    TextField("e.g. Trader Joe's", text: $note)
                        .padding(Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.cardSurface)
                        )
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private var optionsSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Options")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                // A refund is gated by the exact same flags its originating expense would be
                // (see BudgetCalculator) — never unconditional — so both types share these
                // controls rather than refund getting a separate, non-functional branch.
                TransactionToggleRow(
                    title: "Counts Toward Weekly Budget",
                    subtitle: type == .expense
                        ? "Turn off to log this without affecting your weekly limit"
                        : "Turn off if the original purchase never affected your weekly limit either",
                    isOn: $countsTowardWeeklyBudget
                )
                Divider().overlay(Theme.cardStroke)
                TransactionToggleRow(
                    title: "Count toward Monthly Spending",
                    subtitle: type == .expense
                        ? "Turn off for a register-only entry that shouldn't affect your monthly totals"
                        : "Turn off if the original purchase never affected your monthly totals either",
                    isOn: monthlySpendingToggleBinding
                )
                Divider().overlay(Theme.cardStroke)

                TransactionToggleRow(
                    title: "Exclude From Reports",
                    subtitle: "Hide this from weekly and monthly totals entirely",
                    isOn: $isExcludedFromReports
                )

                Divider().overlay(Theme.cardStroke)

                TransactionToggleRow(
                    title: "Pending",
                    subtitle: "Follows your \"Include Pending Transactions\" setting",
                    isOn: $isPending
                )
            }
        }
    }

    /// Wraps `$countsTowardMonthlySpending` so any DIRECT user interaction with the toggle marks
    /// `hasManuallyChangedMonthlySpendingToggle`, permanently protecting that choice from being
    /// overwritten by a later account change — a plain `$countsTowardMonthlySpending` binding
    /// wouldn't distinguish "the account-change handler set this" from "the user tapped this."
    private var monthlySpendingToggleBinding: Binding<Bool> {
        Binding(
            get: { countsTowardMonthlySpending },
            set: { newValue in
                countsTowardMonthlySpending = newValue
                hasManuallyChangedMonthlySpendingToggle = true
            }
        )
    }

    private var validationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(validationMessages, id: \.self) { message in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.statusOver)
                    Text(message)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.statusOver)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.statusOver.opacity(0.12))
        )
    }

    // MARK: - Save

    private func attemptSave() {
        hasAttemptedSave = true
        guard isValid, let amount, let selectedAccount else { return }

        let transaction = FinanceTransaction(
            amount: amount,
            date: date,
            type: type,
            source: .manual,
            note: note,
            countsTowardWeeklyBudget: countsTowardWeeklyBudget,
            countsTowardMonthlySpending: countsTowardMonthlySpending,
            isExcludedFromReports: isExcludedFromReports,
            isPending: isPending,
            account: selectedAccount,
            category: selectedCategory
        )
        #if DEBUG
        // A single `print` call (one write, effectively atomic) rather than four separate calls —
        // four discrete calls issued in the same tick were observed to occasionally lose a line
        // over a physical-device console connection (the console pipe/relay isn't guaranteed to
        // deliver a rapid burst of independent writes as a unit). This changes nothing about what
        // is computed or when — only how the same four lines reach the console.
        let monthlyIncluded = BudgetCalculator.isCounted(transaction, includePending: true, context: .monthly)
        let weeklyIncluded = BudgetCalculator.isCounted(transaction, includePending: true, context: .weekly)
        print("""
        [MonthlySpendDebug] expense saved monthlyFlag=\(transaction.countsTowardMonthlySpending)
        [MonthlySpendDebug] expense saved weeklyFlag=\(transaction.countsTowardWeeklyBudget)
        [MonthlySpendDebug] monthly calculator included=\(monthlyIncluded)
        [MonthlySpendDebug] weekly calculator included=\(weeklyIncluded)
        """)
        #endif
        modelContext.insert(transaction)

        switch type {
        case .expense:
            AccountBalanceManager.applyExpense(amount: amount, to: selectedAccount)
        case .refund:
            AccountBalanceManager.applyRefund(amount: amount, to: selectedAccount)
        case .income, .transfer, .creditCardPayment, .balanceAdjustment:
            break
        }

        dismiss()
    }
}

#Preview("Populated") {
    AddExpenseView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}

#Preview("No Accounts") {
    AddExpenseView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
}

#Preview("No Categories") {
    AddExpenseView()
        .modelContainer({
            let container = SampleData.emptyPreviewContainer()
            let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55)
            container.mainContext.insert(checking)
            return container
        }())
        .environment(PrivacyModeManager())
}
