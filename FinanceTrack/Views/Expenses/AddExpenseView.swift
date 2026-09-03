import SwiftUI
import SwiftData

/// Premium manual entry screen for a single expense, refund, or deposit. Applies the corresponding
/// `AccountBalanceManager` mutation on save so the account balance and the new
/// `FinanceTransaction` record never drift out of sync.
struct AddExpenseView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(PlaidConnectionManager.self) private var plaidConnection

    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    @Query(sort: \Category.name) private var allCategories: [Category]
    @Query(sort: \RecurringExpense.name) private var allRecurringExpenses: [RecurringExpense]
    /// CHECK PAYMENT PHASE — read only to scope the duplicate-check-number warning to the SAME
    /// Manual Account (never across accounts) — see `duplicateCheckNumberWarningMessage`'s own
    /// header. Never written to directly by this screen.
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var allTransactions: [FinanceTransaction]

    @State private var amount: Decimal?
    @State private var note: String = ""
    @State private var date: Date = .now
    @State private var type: TransactionType = .expense
    @State private var selectedAccount: Account?
    /// Only used when `isManualAccountEntry` is false — the Plaid `account_id` this general Manual
    /// Transaction optionally identifies as "the card/account used." Never a Manual Account, never
    /// written to `FinanceTransaction.account`; stored on `plaidAccountId` instead (see
    /// `ConnectedAccountOptionPresenter`'s own doc comment for why that field is safe to reuse
    /// here without confusing this transaction for a Plaid-imported one).
    @State private var selectedConnectedAccountId: String?
    @State private var selectedCategory: Category?
    @State private var countsTowardWeeklyBudget: Bool
    @State private var countsTowardMonthlySpending: Bool
    @State private var isExcludedFromReports: Bool
    @State private var isPending: Bool
    @State private var isPresentingAddAccount = false
    @State private var hasAttemptedSave = false
    @State private var isPresentingDiscardConfirmation = false
    /// CHECK PAYMENT PHASE — "Check" is a user-facing MENU CHOICE, never a `TransactionType` case
    /// (see `FinanceTransaction.checkNumber`'s own header for why): selecting it sets `type =
    /// .expense` and this flag together, so the transaction flows through the exact same
    /// `.expense` save/balance/calculator path as any other expense, with only an extra
    /// `checkNumber` detail attached. Cleared (along with `checkNumber` below) the moment the user
    /// picks any OTHER Type menu choice — see that Menu's own button actions.
    @State private var isCheckPayment = false
    /// Deliberately `String`, never a numeric type — a check number's leading zeros (e.g.
    /// `"001284"`) are significant and must never be silently stripped. Trimmed only at save time
    /// (`trimmedCheckNumber`), never while the user is still typing.
    @State private var checkNumber = ""
    @State private var isPresentingDuplicateCheckWarning = false
    /// Always starts collapsed on every presentation — deliberately not persisted, so a fresh
    /// `@State` for a newly presented screen is always `false` regardless of what a previous
    /// presentation left it as.
    @State private var isOptionsExpanded = false
    @State private var isPresentingAddDescription = false
    @State private var newDescriptionText = ""
    @State private var isPresentingCalculator = false

    /// BILL PAYMENT TAGGING — only meaningful for `isManualAccountEntry && type == .expense`
    /// (see `billTagSection`'s own doc comment for why). `.existingBill`/`.newMonthlyBill` are
    /// only ever set together with `selectedExistingBillID`/`newBillTiming` respectively — see
    /// each row's own action for exactly when.
    private enum BillTagChoice {
        case notABill
        case existingBill
        case newMonthlyBill
        case oneTimeEntry
        /// NOT INCLUDED IN MONTHLY — for a payment that's real spending you already track
        /// elsewhere in your budgeting (e.g. paying off a credit card whose OWN purchases already
        /// counted as spending when you made them) — never linked to a bill, never compared
        /// planned-vs-actual, and never counted toward Weekly/Monthly totals at all. Distinct from
        /// "One Time Entry" (which DOES count normally) — this is for register-only tracking.
        /// Persists as `isExcludedFromReports = true` at save time (see `attemptSave()`).
        case notIncludedInMonthly
    }
    @State private var billTagChoice: BillTagChoice = .notABill
    @State private var selectedExistingBillID: UUID?
    /// The timing category tapped for `.existingBill` — always set alongside
    /// `selectedExistingBillID`, but ALSO kept when `selectedExistingBillID` is `nil` (zero or
    /// multiple active bills share that timing): in that case Save falls back to a label-only
    /// `billTiming` tag instead of a precise `linkedRecurringExpense` — see `save()`'s own header.
    @State private var selectedExistingBillTiming: PlanTiming?
    @State private var newBillTiming: PlanTiming?
    @State private var isPresentingNewBillAddConfirmation = false
    @State private var isPresentingNewBillTimingChoice = false

    /// TRANSFER TRACKING — one side of a Transfer WD/Transfer Dep entry's From/To pair. Either a
    /// Manual Account we hold a real relationship to, or a Connected/Plaid account referenced only
    /// by its stable id (a reference tag, never a local balance to mutate — see
    /// `FinanceTransaction.transferCounterpartyPlaidAccountId`'s own header).
    private enum TransferAccountSelection: Equatable {
        case none
        case manual(Account)
        case connected(id: String, label: String)

        var label: String? {
            switch self {
            case .none: return nil
            case .manual(let account): return account.name
            case .connected(_, let label): return label
            }
        }
    }
    @State private var transferFromSelection: TransferAccountSelection = .none
    @State private var transferToSelection: TransferAccountSelection = .none

    private func isSelectedAccount(_ selection: TransferAccountSelection) -> Bool {
        if case .manual(let account) = selection, account.id == selectedAccount?.id { return true }
        return false
    }

    /// The far side of the transfer relative to `selectedAccount` (the register this screen was
    /// opened from) — whichever of From/To does NOT resolve to `selectedAccount` itself. Falls
    /// back to `transferToSelection` in the edge case where neither side matches (e.g. the user
    /// picked two accounts that are both different from `selectedAccount`), so a counterparty is
    /// always resolved to SOME concrete choice rather than silently dropped.
    private var transferCounterpartySelection: TransferAccountSelection {
        if isSelectedAccount(transferFromSelection) { return transferToSelection }
        if isSelectedAccount(transferToSelection) { return transferFromSelection }
        return transferToSelection
    }

    private func manualAccount(from selection: TransferAccountSelection) -> Account? {
        if case .manual(let account) = selection { return account }
        return nil
    }

    private func connectedAccountId(from selection: TransferAccountSelection) -> String? {
        if case .connected(let id, _) = selection { return id }
        return nil
    }

    private let preferenceStore = TransactionPreferenceStore()
    private let descriptionStore = DescriptionStore()

    /// The reusable Description choice list, alphabetized the same way `CategoryPickerCard`
    /// alphabetizes categories. Read fresh from `descriptionStore` on every access, so it reflects
    /// an addition immediately without a separate cache to keep in sync.
    private var sortedDescriptions: [String] {
        DescriptionSorting.sortedAlphabetically(descriptionStore.all())
    }

    /// True when this screen was opened from a specific Manual Account's own detail/register
    /// screen (`preselectedAccount` was passed) — that flow keeps its exact existing behavior
    /// unchanged: a required `Account`, the full `AccountPickerCard`, and an
    /// `AccountBalanceManager` balance update on save. `false` means this is the general
    /// Dashboard/Activity "Add Expense" flow, where no Manual Account can be selected at all (see
    /// `connectedAccountSection`) — set once at `init` and never changed afterward, so which mode
    /// this screen is in can never drift from how it was actually opened.
    private let isManualAccountEntry: Bool

    /// Opening "Add Expense" from a specific account's own detail/register screen preselects
    /// that account. The four option toggles start from that account's own remembered
    /// preferences for the initial type (`.expense`) if any exist (see
    /// `TransactionPreferenceStore`), otherwise from the account's `defaultCountsTowardMonthlySpending`
    /// plus the screen's own plain defaults — the same resolution `applyRememberedPreferences`
    /// performs on every later account/type change, kept inline here since `init` runs before
    /// `self` exists and can't call an instance method yet.
    init(preselectedAccount: Account? = nil) {
        isManualAccountEntry = preselectedAccount != nil
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

    /// BILL PAYMENT TAGGING — only active bills are offered; an archived/paused bill was
    /// deliberately taken out of Fixed Bills, so it should never appear as a payment target here
    /// either. Mirrors `PayBillsView.activeRecurringExpenses`'s own filter exactly.
    private var activeRecurringExpensesForBillTag: [RecurringExpense] {
        allRecurringExpenses.filter { $0.isActive }
    }

    /// TAG-SIMPLIFICATION CORRECTION — the bill-tag picker shows only the three timing
    /// categories (Beginning/Mid/End of Month), never an individual bill's own name — see
    /// `billTagSection`'s own header. This resolves a timing category to the ONE active bill it
    /// unambiguously refers to, `nil` when zero or more than one active bill shares that timing
    /// (never guessed — matches this codebase's established "never silently pick between
    /// ambiguous matches" convention, e.g. `TransactionCSVImportService`'s account-name matching).
    private func uniqueActiveBill(timing: PlanTiming) -> RecurringExpense? {
        let matches = activeRecurringExpensesForBillTag.filter { $0.timing == timing }
        return matches.count == 1 ? matches.first : nil
    }

    /// Only shown for `isManualAccountEntry && type == .expense` — a Fixed Bill payment is
    /// structurally always money leaving a Manual Account register; tagging a refund or deposit
    /// this way would have no sensible meaning (see `BudgetCalculator.spendingDelta`'s own
    /// exclusion, which only ever applies to a `linkedRecurringExpense`, not a type).
    private var showsBillTagSection: Bool {
        isManualAccountEntry && type == .expense
    }

    /// TRANSFER TRACKING — Transfer WD/Transfer Dep/Transfer To Savings are a Manual Account
    /// register concept only (see `TransactionType.transferWithdrawal`'s own header), so they're
    /// only offered as Type choices, and only replace the normal Account picker with From/To
    /// dropdowns, in the Manual Account flow.
    private var isTransferType: Bool {
        type == .transferWithdrawal || type == .transferDeposit || type == .transferToSavings
    }

    private var showsTransferAccountPickers: Bool {
        isManualAccountEntry && isTransferType
    }

    /// SAVED-TRACKING — Transfer To Savings is only offered when there's at least one verifiable
    /// savings account to transfer into (a Manual Account typed `.savings`, or a Connected/Plaid
    /// account whose own reported subtype is `"savings"` — see `transferToOptions`'s own header);
    /// offering it with nowhere to select as "To" would be a dead end.
    private var hasSavingsAccount: Bool {
        activeAccounts.contains { $0.type == .savings }
            || connectedAccountOptions.contains { $0.subtype?.lowercased() == "savings" }
    }

    /// The Type choices this screen offers — Transfer WD/Dep/To Savings only in the Manual
    /// Account flow, and Transfer To Savings only when a Savings account exists to receive it.
    private var availableTypes: [TransactionType] {
        guard isManualAccountEntry else { return [.expense, .refund, .income] }
        var types: [TransactionType] = [.expense, .refund, .income, .transferWithdrawal, .transferDeposit]
        if hasSavingsAccount { types.append(.transferToSavings) }
        return types
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
        } else if (amount ?? 0) < 0 {
            // ZERO-AMOUNT CORRECTION — 0 is explicitly allowed, so an entry can be logged before
            // its real amount is known and filled in later (see `TransactionAmountEditView`).
            // Only a genuinely negative amount (which the field itself never produces, since
            // `allowsNegative` defaults to `false`) is rejected here.
            messages.append("Amount cannot be negative.")
        }
        if showsTransferAccountPickers {
            if transferFromSelection == .none {
                messages.append("From account is required.")
            }
            if transferToSelection == .none {
                messages.append("To account is required.")
            }
        } else if isManualAccountEntry, selectedAccount == nil {
            // Only the Manual Account flow requires an account — the general Dashboard/Activity
            // flow never requires one; a connected account is an optional reference tag, never
            // mandatory (see Phase 6's "No connected account selected" requirement).
            messages.append("Account is required.")
        }
        // CHECK PAYMENT PHASE — a blank check number is never silently saved as an empty/fabricated
        // value; Scott must either enter one or switch away from Check. Never blocks typing itself
        // (this only runs at save time, driven by `hasAttemptedSave`'s existing display gate below).
        if isCheckPayment, trimmedCheckNumber.isEmpty {
            messages.append("Enter a check number.")
        }
        return messages
    }

    /// CHECK PAYMENT PHASE — trimmed only here, at the boundary between the live-typing field and
    /// validation/save; the raw `checkNumber` `@State` itself is never mutated mid-edit, so
    /// backspacing/retyping behaves exactly like any other text field (no `Pay Bills`-style
    /// editing bug reintroduced).
    private var trimmedCheckNumber: String {
        checkNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// CHECK PAYMENT PHASE — every OTHER check number already used on THIS SAME Manual Account
    /// (never a different account, never a Plaid/general-flow transaction) — compared as
    /// normalized, trimmed strings, exactly matching how `trimmedCheckNumber` itself is derived.
    /// `nil` when there's nothing to warn about, or no account/number to compare yet.
    private var duplicateCheckNumberWarningMessage: String? {
        guard isCheckPayment, !trimmedCheckNumber.isEmpty, let selectedAccount else { return nil }
        let existingNumbers = allTransactions
            .filter { $0.account?.id == selectedAccount.id }
            .compactMap { $0.checkNumber?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard existingNumbers.contains(trimmedCheckNumber) else { return nil }
        return "Check \(trimmedCheckNumber) already exists in this register."
    }

    private var isValid: Bool { validationMessages.isEmpty }

    private var navigationTitle: String {
        switch type {
        case .expense: return "Add Expense"
        case .refund: return "Add Refund"
        case .income: return "Add Deposit"
        case .transferWithdrawal: return "Add Transfer WD"
        case .transferDeposit: return "Add Transfer Dep"
        case .transferToSavings: return "Add Transfer To Savings"
        case .transfer, .creditCardPayment, .balanceAdjustment: return "Add Expense"
        }
    }

    private var amountSectionTitle: String {
        switch type {
        case .expense: return "Expense Amount"
        case .refund: return "Refund Amount"
        case .income: return "Deposit Amount"
        case .transferWithdrawal, .transferDeposit, .transferToSavings: return "Transfer Amount"
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
            || selectedConnectedAccountId != nil
            || selectedCategory != nil
    }
    private var shouldConfirmDiscard: Bool { hasMeaningfulInput }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    amountSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    optionsSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    typeAndDateSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    if isCheckPayment {
                        checkNumberSection
                            .padding(.horizontal, Theme.Spacing.lg)
                    }

                    if showsTransferAccountPickers {
                        transferAccountSection
                            .padding(.horizontal, Theme.Spacing.lg)
                    } else if isManualAccountEntry {
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
                            accountDropdownSection
                                .padding(.horizontal, Theme.Spacing.lg)
                        }
                    } else {
                        // General Dashboard/Activity flow — never lists a Manual Account (see
                        // `isManualAccountEntry`'s own doc comment); optionally tags this
                        // transaction with a connected Plaid account instead.
                        connectedAccountSection
                            .padding(.horizontal, Theme.Spacing.lg)
                    }

                    if showsBillTagSection {
                        billTagSection
                            .padding(.horizontal, Theme.Spacing.lg)
                    }

                    CategoryPickerCard(categories: activeCategories, selectedCategory: $selectedCategory)
                        .padding(.horizontal, Theme.Spacing.lg)

                    detailsSection
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
                // BILL PAYMENT TAGGING — a bill tag only makes sense for an expense (see
                // `showsBillTagSection`'s own header); switching away from `.expense` clears any
                // in-progress selection rather than leaving a stale, now-hidden choice that would
                // otherwise still silently apply at save.
                if newType != .expense {
                    billTagChoice = .notABill
                    selectedExistingBillID = nil
                    selectedExistingBillTiming = nil
                    newBillTiming = nil
                    // CHECK PAYMENT PHASE — defensive fallback alongside the Type Menu's own
                    // buttons (which already clear these directly): a check number is only ever
                    // meaningful for an expense (Part 10's own scope), so it can never survive a
                    // switch to Deposit/Transfer/Balance Adjustment/etc.
                    isCheckPayment = false
                    checkNumber = ""
                }
                // TRANSFER TRACKING — default one side of From/To to the account whose register
                // this screen was opened from, since that's the far more common starting point
                // than an empty picker; the user can still freely change either side. Cleared
                // entirely when switching away from a transfer type, so a stale selection can
                // never silently carry over into an unrelated save.
                if newType == .transferWithdrawal {
                    transferFromSelection = selectedAccount.map { .manual($0) } ?? .none
                    transferToSelection = .none
                } else if newType == .transferDeposit {
                    transferToSelection = selectedAccount.map { .manual($0) } ?? .none
                    transferFromSelection = .none
                } else {
                    transferFromSelection = .none
                    transferToSelection = .none
                }
            }
            .onChange(of: selectedAccount) { _, newAccount in
                applyRememberedPreferences(type: type, account: newAccount)
            }
            .onChange(of: note) { _, newNote in
                // NOT INCLUDED IN MONTHLY DEFAULT — an American Express payment is a credit-card
                // payoff, not a fixed bill with a predictable planned amount (its purchases already
                // counted as spending when made), so comparing it planned-vs-actual as a Bill
                // produces a large, meaningless Bill Payment Variance swing every cycle. Defaults
                // to this tag automatically so the common case needs no manual step — only when
                // `billTagChoice` is still untouched (`.notABill`), never overriding a choice the
                // user already made themselves.
                guard showsBillTagSection, billTagChoice == .notABill else { return }
                if newNote.localizedCaseInsensitiveContains("American Express") {
                    billTagChoice = .notIncludedInMonthly
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
            // CHECK PAYMENT PHASE — a WARNING, never a hard block (Part 5's own explicit
            // requirement — legitimate duplicates can exist from corrections/imports). The message
            // itself is computed fresh from `duplicateCheckNumberWarningMessage` at the moment
            // `attemptSave()` detects a match, so it always names the actual conflicting number.
            .confirmationDialog(
                duplicateCheckNumberWarningMessage ?? "",
                isPresented: $isPresentingDuplicateCheckWarning,
                titleVisibility: .visible
            ) {
                Button("Save Anyway") { performSave() }
                Button("Cancel", role: .cancel) {}
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

                VStack(spacing: Theme.Spacing.xs) {
                    Text(amountSectionTitle)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    CurrencyAmountField(
                        amount: $amount,
                        style: .compact,
                        isInvalid: hasAttemptedSave && (amount ?? 0) < 0,
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

    /// Type (dropdown, left) and Date (right) share one row/card — placed right after Options,
    /// near the top of the form, so changing either doesn't require scrolling past account/
    /// category first.
    private var typeAndDateSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    Menu {
                        ForEach(availableTypes) { candidateType in
                            Button(candidateType.label) {
                                type = candidateType
                                // CHECK PAYMENT PHASE — picking any OTHER Type choice always
                                // leaves Check mode, even when `type` itself doesn't actually
                                // change value (e.g. explicitly re-picking "Expense" while Check
                                // was active) — `.onChange(of: type)` alone wouldn't fire in that
                                // case, so this is set directly here, not only in that handler.
                                isCheckPayment = false
                                checkNumber = ""
                            }
                        }
                        // CHECK PAYMENT PHASE — a user-facing MENU CHOICE only, never a
                        // `TransactionType` case (see `FinanceTransaction.checkNumber`'s own
                        // header) — stays `type == .expense` under the hood, so every calculator
                        // and the save path below need zero changes. Manual Account register
                        // entries only, matching this feature's own scope.
                        if isManualAccountEntry {
                            Button("Check") {
                                type = .expense
                                isCheckPayment = true
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isCheckPayment ? "Check" : type.label)
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Date")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .tint(Theme.accent)
                }
            }
        }
    }

    /// CHECK PAYMENT PHASE — shown ONLY while `isCheckPayment` is true (Part 10's own "Deposit/
    /// Transfer/Balance Adjustment never show this" scope) — a plain `TextField` bound directly to
    /// the `String` `checkNumber` state, matching `detailsSection`'s own Notes field styling
    /// exactly. `.keyboardType(.numberPad)` is a keyboard PREFERENCE only — the underlying value
    /// stays a free-form `String`, never parsed/reformatted, so leading zeros and normal
    /// backspacing/retyping behave exactly like any other text field (no numeric formatter that
    /// would strip them, no `CurrencyAmountField`-style state machine to reintroduce the Pay Bills
    /// editing bug into).
    private var checkNumberSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
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
    }

    // MARK: - Account (dropdown) / Transfer From-To

    /// The Manual Account picker as a dropdown rather than `AccountPickerCard`'s list of rows —
    /// matches the Type/Is-this-a-Bill dropdown treatment elsewhere on this screen.
    private var accountDropdownSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manual Account")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Menu {
                    ForEach(activeAccounts) { account in
                        Button(account.name) { selectedAccount = account }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedAccount?.name ?? "Select Account")
                            .font(Theme.bodyFont)
                            .foregroundStyle(selectedAccount == nil ? Theme.textTertiary : Theme.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    /// TRANSFER TRACKING — every Manual Account plus every Connected/Plaid account, offered as
    /// selectable From/To counterparties. A Connected account is a reference tag only (see
    /// `TransferAccountSelection.connected`'s own header) — its balance is never locally mutated.
    private var transferAccountOptions: [TransferAccountSelection] {
        activeAccounts.map { .manual($0) } + connectedAccountOptions.map { .connected(id: $0.id, label: $0.label) }
    }

    /// SAVED-TRACKING — for a Transfer To Savings entry, the "To" side must be VERIFIABLY a
    /// savings account, never a non-savings account (which would make the "Saved" Quick Stat
    /// meaningless) — restricted here rather than left to the user to pick correctly. Includes
    /// both a Manual Account typed `.savings` AND a Connected/Plaid account whose own reported
    /// `subtype` is `"savings"` (Plaid's own classification, read via
    /// `ConnectedAccountOption.subtype` — see that type's own header for why this is trustworthy:
    /// it's Plaid's data, not a guess). A Connected account picked here still behaves exactly like
    /// any other Transfer WD/Dep Connected counterparty — a reference tag only, its balance is
    /// never locally mutated (Plaid owns that).
    private var transferToOptions: [TransferAccountSelection] {
        guard type == .transferToSavings else { return transferAccountOptions }
        let manualSavings = activeAccounts.filter { $0.type == .savings }.map { TransferAccountSelection.manual($0) }
        let connectedSavings = connectedAccountOptions
            .filter { $0.subtype?.lowercased() == "savings" }
            .map { TransferAccountSelection.connected(id: $0.id, label: $0.label) }
        return manualSavings + connectedSavings
    }

    private var transferAccountSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                transferAccountDropdown(title: "From", selection: $transferFromSelection, options: transferAccountOptions)
                Divider().overlay(Theme.cardStroke)
                transferAccountDropdown(
                    title: type == .transferToSavings ? "To (Savings Account)" : "To",
                    selection: $transferToSelection,
                    options: transferToOptions
                )
            }
        }
    }

    private func transferAccountDropdown(title: String, selection: Binding<TransferAccountSelection>, options: [TransferAccountSelection]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button(option.label ?? "") { selection.wrappedValue = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue.label ?? "Select Account")
                        .font(Theme.bodyFont)
                        .foregroundStyle(selection.wrappedValue.label == nil ? Theme.textTertiary : Theme.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Connected account tag (general Dashboard/Activity flow only)

    private var connectedAccountOptions: [ConnectedAccountOption] {
        ConnectedAccountOptionPresenter.options(for: plaidConnection.connections)
    }

    /// Optional "which card/account did you use" tag for a general Manual Transaction — never a
    /// Manual Account (those are never listed here), never required. Hidden entirely when nothing
    /// is connected yet, so a household with no Plaid connections sees no empty/dead section.
    @ViewBuilder
    private var connectedAccountSection: some View {
        if !connectedAccountOptions.isEmpty {
            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Paid With")
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)

                    VStack(spacing: Theme.Spacing.sm) {
                        connectedAccountOptionRow(id: nil, label: "No connected account selected")
                        ForEach(connectedAccountOptions) { option in
                            connectedAccountOptionRow(id: option.id, label: option.label)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func connectedAccountOptionRow(id: String?, label: String) -> some View {
        let isSelected = selectedConnectedAccountId == id
        Button {
            selectedConnectedAccountId = id
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: id == nil ? "minus.circle" : "creditcard.fill")
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

    // MARK: - Bill payment tagging (Manual Account expense entries only)

    /// BILL PAYMENT TAGGING — lets a Manual Account register entry indicate it's paying a Fixed
    /// Bill, so it never counts twice toward Weekly/Monthly Spending (Fixed Bills already prices
    /// it in) — see `BudgetCalculator.spendingDelta`'s own header. Pay Bills never needs this: it
    /// already knows exactly which bill it's paying and links automatically (see
    /// `ManualTransactionCreationService.createExpense`). This picker is for a bill paid outside
    /// that flow — directly in the account's own register.
    /// The current bill-tag choice's display label — mirrors `billTagRow`'s labels exactly so the
    /// dropdown's collapsed state always matches what a menu selection would show.
    private var billTagCurrentLabel: String {
        switch billTagChoice {
        case .notABill: return "Not a Bill"
        case .existingBill: return selectedExistingBillTiming.map { "\($0.label) Bill" } ?? "Not a Bill"
        case .newMonthlyBill: return "New Monthly Bill"
        case .oneTimeEntry: return "One Time Entry"
        case .notIncludedInMonthly: return "Not Included in Monthly"
        }
    }

    private var billTagSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Is this a Bill?")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Menu {
                    Button("Not a Bill") {
                        billTagChoice = .notABill
                        selectedExistingBillID = nil
                        selectedExistingBillTiming = nil
                        newBillTiming = nil
                    }

                    // TAG-SIMPLIFICATION CORRECTION — always offers all three timing choices,
                    // never hidden for ambiguity: when `uniqueActiveBill(timing:)` can't resolve
                    // to exactly one active bill, `selectedExistingBillID` stays `nil` and
                    // `save()` falls back to a label-only `billTiming` tag instead of a precise
                    // link.
                    ForEach([PlanTiming.beginningMonth, .midMonth, .endMonth], id: \.self) { timing in
                        let bill = uniqueActiveBill(timing: timing)
                        Button("\(timing.label) Bill") {
                            billTagChoice = .existingBill
                            selectedExistingBillID = bill?.id
                            selectedExistingBillTiming = timing
                            newBillTiming = nil
                        }
                    }

                    Button("New Monthly Bill") {
                        isPresentingNewBillAddConfirmation = true
                    }

                    Button("One Time Entry") {
                        billTagChoice = .oneTimeEntry
                        selectedExistingBillID = nil
                        selectedExistingBillTiming = nil
                        newBillTiming = nil
                    }

                    Button("Not Included in Monthly") {
                        billTagChoice = .notIncludedInMonthly
                        selectedExistingBillID = nil
                        selectedExistingBillTiming = nil
                        newBillTiming = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(billTagCurrentLabel)
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    /// DESCRIPTION REDESIGN PHASE — replaces the old two-control layout (a `Menu`-only
    /// `DescriptionPickerCard`, which BLOCKED direct typing, sitting above a separately-labeled
    /// free-form "Notes" `TextField`) with ONE plain, always-typeable `TextField` bound directly to
    /// `note` plus a "Select" button beside it. Both old controls already edited the exact same
    /// `note` value, so this is a pure UI consolidation, never a change to what gets saved: `note`
    /// is still the one and only value written to
    /// `FinanceTransaction.note` at save time. `DescriptionPickerCard.swift` is left in place,
    /// unused, rather than deleted (matches this codebase's own "leave intact, don't delete
    /// dead-but-harmless code" convention elsewhere).
    ///
    /// The "Select" `Menu` reuses the EXACT SAME canonical choices/source
    /// (`sortedDescriptions`/`descriptionStore`) and "Add Description" alert flow the old picker
    /// used — no second description library. Choosing an option sets `note` directly (never a
    /// separate "locked selection" state), so the `TextField` above it remains immediately editable
    /// afterward — typing, selecting, then re-editing all just mutate the same plain `String`.
    private var detailsSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Details")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    TextField("Enter a description...", text: $note)
                        .padding(Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.cardSurface)
                        )
                        .foregroundStyle(Theme.textPrimary)

                    Menu {
                        if sortedDescriptions.isEmpty {
                            Text("No saved descriptions yet")
                        } else {
                            ForEach(sortedDescriptions, id: \.self) { description in
                                Button(description) { note = description }
                            }
                        }
                        Divider()
                        Button {
                            isPresentingAddDescription = true
                        } label: {
                            Label("Add Description", systemImage: "plus")
                        }
                    } label: {
                        Text("Select")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.accent)
                    }
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
            // would have no effect would be misleading — hidden for that type instead. Same
            // reasoning for Transfer To Savings — `BudgetCalculator.countsToward` forces both
            // flags to `false` for that type structurally, so it can never affect Monthly
            // Remaining or Projected Available regardless of what these toggles would say.
            if type != .income && type != .transferToSavings {
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

    /// The Save button's own entry point — runs validation, then (Check transactions only) the
    /// duplicate-check-number WARNING gate, before ever creating a `FinanceTransaction`. A
    /// detected duplicate stops here and shows `isPresentingDuplicateCheckWarning` instead of
    /// saving immediately; `performSave()` below does the actual creation, reached either directly
    /// (no duplicate) or via that dialog's "Save Anyway" button.
    private func attemptSave() {
        hasAttemptedSave = true
        guard isValid else { return }
        if duplicateCheckNumberWarningMessage != nil {
            isPresentingDuplicateCheckWarning = true
            return
        }
        performSave()
    }

    private func performSave() {
        guard isValid, let amount else { return }
        // Only the Manual Account flow requires selectedAccount (enforced by `validationMessages`
        // above); the general flow never sets it, by construction (no Manual Account is ever
        // offered — see `connectedAccountSection`). A transfer entry uses From/To instead of
        // `selectedAccount` directly — its own presence is validated separately above.
        guard !isManualAccountEntry || showsTransferAccountPickers || selectedAccount != nil else { return }

        // TRANSFER TRACKING — `transactionAccount` is always the Manual Account this row lives in
        // (the register this screen was opened from); `counterpartyAccount`/`counterpartyPlaidId`
        // is whichever of From/To is the FAR side, resolved once here so both the transaction's
        // own fields and the balance mutation below stay in agreement.
        let transactionAccount = showsTransferAccountPickers ? (selectedAccount ?? manualAccount(from: transferFromSelection) ?? manualAccount(from: transferToSelection)) : selectedAccount
        let counterpartyAccount = showsTransferAccountPickers ? manualAccount(from: transferCounterpartySelection) : nil
        let counterpartyPlaidId = showsTransferAccountPickers ? connectedAccountId(from: transferCounterpartySelection) : nil

        // BILL PAYMENT TAGGING — resolved once, right before creating the transaction, so a
        // "New Monthly Bill" only ever creates its `RecurringExpense` on a genuine Save (never on
        // mere selection, and never if the whole entry is later discarded). Only reachable when
        // `showsBillTagSection` was true at the time of selection (Manual Account expense) — the
        // `.onChange(of: type)` reset above already guarantees `billTagChoice` can't be stale for
        // a non-expense/general-flow save.
        var linkedRecurringExpense: RecurringExpense?
        var isOneTimeBillEntry = false
        var billTiming: PlanTiming?
        switch billTagChoice {
        case .notABill:
            break
        case .existingBill:
            linkedRecurringExpense = activeRecurringExpensesForBillTag.first { $0.id == selectedExistingBillID }
            // No unique bill for this timing (see the row's own comment) — fall back to a
            // label-only tag rather than leaving this Save silently equivalent to "Not a Bill."
            if linkedRecurringExpense == nil {
                billTiming = selectedExistingBillTiming
            }
        case .newMonthlyBill:
            if let timing = newBillTiming {
                let newBill = RecurringExpense(name: note.isEmpty ? "New Bill" : note, amount: amount, category: selectedCategory, timing: timing)
                modelContext.insert(newBill)
                linkedRecurringExpense = newBill
            }
        case .oneTimeEntry:
            isOneTimeBillEntry = true
        case .notIncludedInMonthly:
            break
        }

        // NOT INCLUDED IN MONTHLY — never linked to a bill (no planned-vs-actual comparison, see
        // `BillTagChoice.notIncludedInMonthly`'s own header), and forced excluded from Weekly/
        // Monthly totals regardless of the Options toggle, so this choice always means exactly
        // what its label says — register-only tracking, zero effect on any total.
        let effectiveIsExcludedFromReports = isExcludedFromReports || billTagChoice == .notIncludedInMonthly

        let transaction = FinanceTransaction(
            amount: amount,
            date: date,
            type: type,
            source: .manual,
            note: note,
            countsTowardWeeklyBudget: countsTowardWeeklyBudget,
            countsTowardMonthlySpending: countsTowardMonthlySpending,
            isExcludedFromReports: effectiveIsExcludedFromReports,
            isPending: isPending,
            // `plaidAccountId` here is only ever the optional "card/account used" reference tag
            // from `connectedAccountSection` (nil in the Manual Account flow) — never confused
            // with a Plaid-imported transaction's own `plaidAccountId`, since `source` stays
            // `.manual` regardless.
            plaidAccountId: isManualAccountEntry ? nil : selectedConnectedAccountId,
            account: showsTransferAccountPickers ? transactionAccount : selectedAccount,
            category: selectedCategory,
            linkedRecurringExpense: linkedRecurringExpense,
            isOneTimeBillEntry: isOneTimeBillEntry,
            billTiming: billTiming,
            transferCounterpartyAccount: counterpartyAccount,
            transferCounterpartyPlaidAccountId: counterpartyPlaidId,
            checkNumber: isCheckPayment ? trimmedCheckNumber : nil
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

        // Only the Manual Account flow ever has a local Account to update — the general flow's
        // optional connected-account tag is a reference-only identifier, never a local balance to
        // mutate (that already happens server-side, via Plaid, for the real connected account).
        if isManualAccountEntry, let effectiveAccount = transaction.account {
            switch type {
            case .expense:
                AccountBalanceManager.applyExpense(amount: amount, to: effectiveAccount)
            case .refund:
                AccountBalanceManager.applyRefund(amount: amount, to: effectiveAccount)
            case .income:
                AccountBalanceManager.applyIncome(amount: amount, to: effectiveAccount)
            case .transferWithdrawal, .transferToSavings:
                // Money leaves `effectiveAccount`; only reverse the counterparty's balance if it's
                // a Manual Account we actually own locally — a Connected/Plaid counterparty is a
                // reference tag only (see `transferCounterpartyPlaidAccountId`'s own header).
                // `.transferToSavings` applies identically — its counterparty is always a Manual
                // Account (see `transferToOptions`), so this branch always credits it.
                AccountBalanceManager.applyExpense(amount: amount, to: effectiveAccount)
                if let counterpartyAccount { AccountBalanceManager.applyIncome(amount: amount, to: counterpartyAccount) }
            case .transferDeposit:
                AccountBalanceManager.applyIncome(amount: amount, to: effectiveAccount)
                if let counterpartyAccount { AccountBalanceManager.applyExpense(amount: amount, to: counterpartyAccount) }
            case .transfer, .creditCardPayment, .balanceAdjustment:
                break
            }

            // Only remembered after every step above has succeeded — a cancel, a dismiss, or a
            // validation failure (which returns before reaching this point) must never update
            // what the next visit to this account/type combination starts from. Only meaningful
            // for the Manual Account flow, which is the only one `TransactionPreferenceStore` has
            // ever keyed by account.
            preferenceStore.save(
                TransactionEntryPreferences(
                    countsTowardWeeklyBudget: countsTowardWeeklyBudget,
                    countsTowardMonthlySpending: countsTowardMonthlySpending,
                    isExcludedFromReports: isExcludedFromReports,
                    isPending: isPending
                ),
                accountID: effectiveAccount.id,
                type: type
            )
        }

        dismiss()
    }
}

#Preview("General Flow (Dashboard/Activity)") {
    AddExpenseView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}

#Preview("Manual Account Flow — Populated") {
    AddExpenseView(preselectedAccount: {
        let account = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55)
        return account
    }())
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}

#Preview("No Accounts (Manual Account Flow Empty State)") {
    // Not inserted into the container — exercises the "no accounts exist yet" empty state
    // (isManualAccountEntry stays true because a preselectedAccount was passed, even though it
    // isn't a real persisted row in this preview's container).
    AddExpenseView(preselectedAccount: Account(name: "Preview Only", type: .checking))
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}

#Preview("No Categories") {
    AddExpenseView(preselectedAccount: {
        let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55)
        return checking
    }())
        .modelContainer({
            let container = SampleData.emptyPreviewContainer()
            let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55)
            container.mainContext.insert(checking)
            return container
        }())
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}
