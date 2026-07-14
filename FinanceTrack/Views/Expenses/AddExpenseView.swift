import SwiftUI
import SwiftData

/// Premium manual entry screen for a single expense, refund, or deposit. Applies the corresponding
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
    @State private var countsTowardWeeklyBudget: Bool
    @State private var countsTowardMonthlySpending: Bool
    @State private var isExcludedFromReports: Bool
    @State private var isPending: Bool
    @State private var isPresentingAddAccount = false
    @State private var hasAttemptedSave = false
    @State private var isPresentingDiscardConfirmation = false
    /// Always starts collapsed on every presentation — deliberately not persisted, so a fresh
    /// `@State` for a newly presented screen is always `false` regardless of what a previous
    /// presentation left it as.
    @State private var isOptionsExpanded = false
    @State private var isPresentingAddDescription = false
    @State private var newDescriptionText = ""
    @State private var isPresentingCalculator = false

    private let preferenceStore = TransactionPreferenceStore()
    private let descriptionStore = DescriptionStore()

    /// The reusable Description choice list, alphabetized the same way `CategoryPickerCard`
    /// alphabetizes categories. Read fresh from `descriptionStore` on every access, so it reflects
    /// an addition immediately without a separate cache to keep in sync.
    private var sortedDescriptions: [String] {
        DescriptionSorting.sortedAlphabetically(descriptionStore.all())
    }

    /// `note` IS the transaction's description — this binding just presents that single existing
    /// property as an optional to `DescriptionPickerCard` (empty string means "no description
    /// selected") rather than introducing a second, duplicate field. Typing directly into the
    /// free-form Note field below updates the exact same value.
    private var descriptionBinding: Binding<String?> {
        Binding(
            get: { note.isEmpty ? nil : note },
            set: { newValue in note = newValue ?? "" }
        )
    }

    /// Opening "Add Expense" from a specific account's own detail/register screen preselects
    /// that account. The four option toggles start from that account's own remembered
    /// preferences for the initial type (`.expense`) if any exist (see
    /// `TransactionPreferenceStore`), otherwise from the account's `defaultCountsTowardMonthlySpending`
    /// plus the screen's own plain defaults — the same resolution `applyRememberedPreferences`
    /// performs on every later account/type change, kept inline here since `init` runs before
    /// `self` exists and can't call an instance method yet.
    init(preselectedAccount: Account? = nil) {
        _selectedAccount = State(initialValue: preselectedAccount)
        let resolved = TransactionPreferenceStore().resolvedPreferences(
            accountID: preselectedAccount?.id,
            type: .expense,
            fallback: TransactionEntryPreferences(
                countsTowardWeeklyBudget: true,
                countsTowardMonthlySpending: preselectedAccount?.defaultCountsTowardMonthlySpending ?? true,
                isExcludedFromReports: false,
                isPending: false
            )
        )
        _countsTowardWeeklyBudget = State(initialValue: resolved.countsTowardWeeklyBudget)
        _countsTowardMonthlySpending = State(initialValue: resolved.countsTowardMonthlySpending)
        _isExcludedFromReports = State(initialValue: resolved.isExcludedFromReports)
        _isPending = State(initialValue: resolved.isPending)
    }

    /// Reloads the four toggles for the current `type` and `account` (or `selectedAccount` if
    /// `account` isn't passed) — called whenever either changes, so entering a different
    /// account/type combination always starts from THAT pair's own remembered preferences (see
    /// `TransactionPreferenceStore.resolvedPreferences`), falling back to the screen's plain
    /// defaults (weekly on, monthly from the account's own default, excluded off, pending off)
    /// when nothing has been remembered yet.
    private func applyRememberedPreferences(type: TransactionType, account: Account? = nil) {
        let resolvedAccount = account ?? selectedAccount
        let resolved = preferenceStore.resolvedPreferences(
            accountID: resolvedAccount?.id,
            type: type,
            fallback: TransactionEntryPreferences(
                countsTowardWeeklyBudget: true,
                countsTowardMonthlySpending: resolvedAccount?.defaultCountsTowardMonthlySpending ?? true,
                isExcludedFromReports: false,
                isPending: false
            )
        )
        countsTowardWeeklyBudget = resolved.countsTowardWeeklyBudget
        countsTowardMonthlySpending = resolved.countsTowardMonthlySpending
        isExcludedFromReports = resolved.isExcludedFromReports
        isPending = resolved.isPending
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

    private var navigationTitle: String {
        switch type {
        case .expense: return "Add Expense"
        case .refund: return "Add Refund"
        case .income: return "Add Deposit"
        case .transfer, .creditCardPayment, .balanceAdjustment: return "Add Expense"
        }
    }

    private var amountSectionTitle: String {
        switch type {
        case .expense: return "Expense Amount"
        case .refund: return "Refund Amount"
        case .income: return "Deposit Amount"
        case .transfer, .creditCardPayment, .balanceAdjustment: return "Amount"
        }
    }

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
                VStack(spacing: Theme.Spacing.md) {
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

                    categoryAndDescriptionRow
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
                .padding(.vertical, Theme.Spacing.md)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnBackgroundTap()
            .navigationTitle(navigationTitle)
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
            .sheet(isPresented: $isPresentingCalculator) {
                CalculatorView()
            }
            .alert("Add Description", isPresented: $isPresentingAddDescription) {
                TextField("e.g. Netflix", text: $newDescriptionText)
                Button("Add") {
                    if let added = descriptionStore.add(newDescriptionText) {
                        note = added
                    }
                    newDescriptionText = ""
                }
                Button("Cancel", role: .cancel) {
                    newDescriptionText = ""
                }
            }
            .onChange(of: type) { _, newType in
                applyRememberedPreferences(type: newType)
            }
            .onChange(of: selectedAccount) { _, newAccount in
                applyRememberedPreferences(type: type, account: newAccount)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    /// A normal top-to-bottom `VStack` — a leading calculator-icon row, then the existing centered
    /// label/field — rather than the previous `ZStack(alignment: .topLeading)` overlay. The
    /// overlay approach put the button in normal SwiftUI layout flow but visually failed to render
    /// reliably; a plain sibling row above the amount content guarantees the icon is laid out (and
    /// painted) in its own space rather than depending on `ZStack` layering over the amount field.
    private var amountSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    amountCardCalculatorButton
                    Spacer(minLength: 0)
                }

                VStack(spacing: Theme.Spacing.sm) {
                    Text(amountSectionTitle)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    CurrencyAmountField(
                        amount: $amount,
                        style: .hero,
                        isInvalid: hasAttemptedSave && (amount ?? 0) <= 0,
                        accessibilityLabel: amountSectionTitle
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Opens the same `CalculatorView`/`CalculatorEngine` used everywhere else in the app — this
    /// is a second launch point, not a second implementation. Uses the supplied `CalculatorIcon`
    /// asset (a self-contained rounded-square glyph with its own light background, not an SF
    /// Symbol) so it stays clearly visible regardless of theme; sitting in its own leading row
    /// above the label/field means it can never overlap either.
    private var amountCardCalculatorButton: some View {
        Button {
            isPresentingCalculator = true
        } label: {
            Image("CalculatorIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Calculator")
    }

    private var typeSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Type")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Picker("Type", selection: $type) {
                    ForEach([TransactionType.expense, .refund, .income]) { candidateType in
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
        CardBackground(padding: Theme.Spacing.md) {
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

    private var categoryAndDescriptionRow: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            CategoryPickerCard(categories: activeCategories, selectedCategory: $selectedCategory)
            DescriptionPickerCard(
                descriptions: sortedDescriptions,
                selectedDescription: descriptionBinding,
                onRequestAddDescription: { isPresentingAddDescription = true }
            )
        }
    }

    private var detailsSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
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
        CardBackground(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                optionsHeader

                if isOptionsExpanded {
                    optionsControls
                }
            }
        }
    }

    /// Tap-to-expand row — collapsed shows only the section title and a chevron, expanded reveals
    /// `optionsControls` below it. Toggling this never touches any of the four option values
    /// themselves, so collapsing and re-expanding is always a no-op on the underlying state.
    private var optionsHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOptionsExpanded.toggle()
            }
        } label: {
            HStack {
                Text("Options")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: isOptionsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Options")
        .accessibilityValue(isOptionsExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
    }

    private var optionsControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // A refund is gated by the exact same flags its originating expense would be
            // (see BudgetCalculator) — never unconditional — so both types share these
            // controls rather than refund getting a separate, non-functional branch. A
            // deposit is structurally excluded from every spending total regardless of these
            // flags (see BudgetCalculator's `.income` handling), so showing controls that
            // would have no effect would be misleading — hidden for that type instead.
            if type != .income {
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
                    isOn: $countsTowardMonthlySpending
                )
                Divider().overlay(Theme.cardStroke)
            }

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
        case .income:
            AccountBalanceManager.applyIncome(amount: amount, to: selectedAccount)
        case .transfer, .creditCardPayment, .balanceAdjustment:
            break
        }

        // Only remembered after every step above has succeeded — a cancel, a dismiss, or a
        // validation failure (which returns before reaching this point) must never update what
        // the next visit to this account/type combination starts from.
        preferenceStore.save(
            TransactionEntryPreferences(
                countsTowardWeeklyBudget: countsTowardWeeklyBudget,
                countsTowardMonthlySpending: countsTowardMonthlySpending,
                isExcludedFromReports: isExcludedFromReports,
                isPending: isPending
            ),
            accountID: selectedAccount.id,
            type: type
        )

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
