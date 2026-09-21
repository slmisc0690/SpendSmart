import SwiftUI
import SwiftData

/// Full detail/register screen for a single NON-credit-card Manual Account (checking, savings,
/// cash, other) — the checking/savings/cash/other counterpart to `CreditCardDetailView`. Shows
/// the account's balance, its "Track as part of Monthly Spending?" default, and every manually
/// entered transaction against it, with safe per-transaction deletion.
struct ManualAccountDetailView: View {
    @Bindable var account: Account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PrivacyModeManager.self) private var privacyMode

    /// PERFORMANCE — scoped directly to this account (via `#Predicate`) rather than fetching every
    /// `FinanceTransaction` in the app and filtering in Swift. The unscoped version re-fetched and
    /// re-filtered the ENTIRE app's transaction list on every SwiftData autosave — including the
    /// autosave triggered by toggling a single row's `isPaymentConfirmed` checkbox — which made a
    /// single checkbox tap visibly slow to respond on a real device. Matches
    /// `ManualAccountDeletionService.eligibility`'s own source-or-destination check, so passing
    /// this scoped list to `deleteAccount()` below is equivalent to passing the old app-wide list.
    @Query private var accountTransactions: [FinanceTransaction]

    @State private var isPresentingAddExpense = false
    @State private var isPresentingEdit = false
    @State private var isPresentingCalculator = false
    @State private var isPresentingPayBills = false
    @State private var transactionPendingDeletion: FinanceTransaction?
    @State private var transactionPendingBillTagEdit: FinanceTransaction?
    @State private var transactionPendingAmountEdit: FinanceTransaction?
    @State private var transactionPendingCheckNumberEdit: FinanceTransaction?
    @State private var transactionPendingFullEdit: FinanceTransaction?
    @State private var isPresentingDeletionError = false
    @State private var isPresentingAccountDeletionConfirmation = false
    @State private var accountDeletionBlockedMessage: String?

    /// BULK DELETE (2026-09-17, Scott's own explicit request) — mirrors the exact same
    /// Select/Cancel + checkbox-per-row + bottom action-bar pattern `ExpenseListView`'s "Activity
    /// Register Import" feature already established, rather than inventing a second selection UI.
    @State private var isSelectingTransactions = false
    @State private var selectedTransactionIDs: Set<UUID> = []
    @State private var isPresentingBulkDeletionConfirmation = false
    @State private var bulkDeletionFailureCount = 0

    init(account: Account) {
        self.account = account
        let accountID = account.id
        _accountTransactions = Query(
            filter: #Predicate<FinanceTransaction> { transaction in
                transaction.account?.id == accountID || transaction.transferDestinationAccount?.id == accountID
            },
            sort: \FinanceTransaction.date,
            order: .reverse
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    summaryCard
                        .padding(.horizontal, Theme.Spacing.lg)

                    actionsRow
                        .padding(.horizontal, Theme.Spacing.lg)

                    registerSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    accountOptionsMenu
                }
            }
            .sheet(isPresented: $isPresentingAddExpense) {
                AddExpenseView(preselectedAccount: account)
            }
            .sheet(isPresented: $isPresentingCalculator) {
                CalculatorView()
            }
            .sheet(isPresented: $isPresentingEdit) {
                AddAccountView(account: account)
            }
            .sheet(isPresented: $isPresentingPayBills) {
                // PAY BILLS THIRD CORRECTION — THE VERIFIED-DIFFERENT ANCESTOR: unlike a minimal
                // reproduction of Pay Bills' own ForEach/ScrollView/CurrencyAmountField structure
                // (which survives repeated editing fine in isolation — see this fix's own
                // regression test), THIS screen presents Pay Bills via `.sheet(isPresented:)` from
                // a parent that observes `@Bindable var account` AND a live
                // `@Query private var accountTransactions` — any re-render of THIS view (for any
                // reason, not necessarily caused by Pay Bills itself) re-evaluates this sheet's
                // content closure. `.id(...)` pins the presented view's identity explicitly, so
                // SwiftUI can never treat a parent re-render as a reason to tear down and recreate
                // Pay Bills' view hierarchy (and, with it, the in-progress `CurrencyUITextField`
                // and its first-responder state) while the sheet is open.
                PayBillsView(account: account)
                    .id(account.id)
            }
            .sheet(item: $transactionPendingBillTagEdit) { transaction in
                TransactionBillTagEditView(transaction: transaction)
            }
            .sheet(item: $transactionPendingAmountEdit) { transaction in
                TransactionAmountEditView(transaction: transaction)
            }
            .sheet(item: $transactionPendingCheckNumberEdit) { transaction in
                CheckNumberEditView(transaction: transaction)
            }
            .sheet(item: $transactionPendingFullEdit) { transaction in
                AddExpenseView(editing: transaction)
            }
            .confirmationDialog(
                transactionPendingDeletion.map { ManualTransactionDeletionService.confirmationCopy(for: $0).title } ?? "Delete?",
                isPresented: Binding(
                    get: { transactionPendingDeletion != nil },
                    set: { isPresented in if !isPresented { transactionPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let transaction = transactionPendingDeletion {
                    Button(ManualTransactionDeletionService.confirmationCopy(for: transaction).destructiveActionTitle, role: .destructive) {
                        let succeeded = ManualTransactionDeletionService.delete(transaction, context: modelContext)
                        transactionPendingDeletion = nil
                        if !succeeded { isPresentingDeletionError = true }
                    }
                }
                Button("Cancel", role: .cancel) { transactionPendingDeletion = nil }
            } message: {
                if let transaction = transactionPendingDeletion {
                    Text(ManualTransactionDeletionService.confirmationCopy(for: transaction).message)
                }
            }
            .alert("Couldn't Delete", isPresented: $isPresentingDeletionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This transaction couldn't be safely deleted, so nothing was changed.")
            }
            .confirmationDialog(
                "Delete \(selectedTransactionIDs.count) Transaction\(selectedTransactionIDs.count == 1 ? "" : "s")?",
                isPresented: $isPresentingBulkDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteSelectedTransactions() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every selected transaction will be removed from the register and its balance effect reversed. This cannot be undone.")
            }
            .alert("Couldn't Delete Everything", isPresented: Binding(
                get: { bulkDeletionFailureCount > 0 },
                set: { isPresented in if !isPresented { bulkDeletionFailureCount = 0 } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(bulkDeletionFailureCount) selected transaction\(bulkDeletionFailureCount == 1 ? "" : "s") couldn't be safely deleted and were left untouched. Everything else selected was removed.")
            }
            .confirmationDialog(
                "Delete Account Register?",
                isPresented: $isPresentingAccountDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    deleteAccount()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete this account register and its manually entered account entries. This cannot be undone.")
            }
            .alert(
                "Can't Delete Account",
                isPresented: Binding(
                    get: { accountDeletionBlockedMessage != nil },
                    set: { isPresented in if !isPresented { accountDeletionBlockedMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accountDeletionBlockedMessage ?? "")
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectingTransactions, !selectedTransactionIDs.isEmpty {
                    selectedActionBar
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// BULK DELETE — loops the same `ManualTransactionDeletionService.delete(_:context:)` every
    /// single-transaction delete already uses, one call per selected transaction. Safe to loop:
    /// each call reverses balance using ONLY that transaction's own stored fields, never the
    /// account's current live balance, so the order transactions are deleted in never matters (see
    /// this service's own header). Any transaction that turns out ineligible (e.g. a Plaid import
    /// somehow still selected) is simply skipped, counted, and reported — never a partial/silent
    /// failure.
    private func deleteSelectedTransactions() {
        let targets = accountTransactions.filter { selectedTransactionIDs.contains($0.id) }
        var failures = 0
        for transaction in targets {
            if !ManualTransactionDeletionService.delete(transaction, context: modelContext) {
                failures += 1
            }
        }
        isSelectingTransactions = false
        selectedTransactionIDs = []
        bulkDeletionFailureCount = failures
    }

    private func deleteAccount() {
        let eligibility = ManualAccountDeletionService.eligibility(for: account, transactions: accountTransactions)
        guard eligibility == .eligible else {
            accountDeletionBlockedMessage = ManualAccountDeletionService.blockedMessage(for: eligibility)
            return
        }
        let succeeded = ManualAccountDeletionService.delete(account, transactions: accountTransactions, context: modelContext)
        if succeeded {
            dismiss()
        } else {
            accountDeletionBlockedMessage = "This account couldn't be safely deleted, so nothing was changed."
        }
    }

    // MARK: - Sections

    private var summaryCard: some View {
        CardBackground(tint: Color(hex: account.colorHex) ?? Theme.accent) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.institutionName ?? account.type.label)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                        if let lastFour = account.lastFourDigits, !lastFour.isEmpty {
                            Text("\u{2022}\u{2022}\u{2022}\u{2022} \(lastFour)")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer()
                    manualBadge
                }

                PrivacyAmountView(
                    amount: account.currentBalance,
                    isPrivacyModeEnabled: privacyMode.isEnabled,
                    font: Theme.amountFont(),
                    color: Theme.textPrimary
                )

                HStack(spacing: 6) {
                    Image(systemName: account.defaultCountsTowardMonthlySpending ? "checkmark.circle.fill" : "circle.slash")
                        .font(.system(size: 12, weight: .semibold))
                    Text(account.defaultCountsTowardMonthlySpending
                        ? "New expenses count toward Monthly Spending by default"
                        : "New expenses do NOT count toward Monthly Spending by default")
                        .font(Theme.captionFont)
                }
                .foregroundStyle(account.defaultCountsTowardMonthlySpending ? Theme.statusGood : Theme.textTertiary)
            }
        }
    }

    private var manualBadge: some View {
        Text("Manual")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(0.15)))
    }

    /// Neither `addTransactionButton` nor `editButton` uses `PremiumActionButton` (whose
    /// `.frame(maxWidth: .infinity)` forces it to stretch and consume all remaining row width,
    /// which is exactly why "Add Transaction" was rendering far too wide) — both are
    /// content-sized pills built from `compactPillButton`, so the row lays out left-to-right at
    /// natural width with a trailing `Spacer` absorbing any leftover space instead of one button
    /// swallowing it.
    private var actionsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            addTransactionButton
            payBillsButton
            editButton
            calculatorButton
            Spacer(minLength: 0)
        }
    }

    private var addTransactionButton: some View {
        compactPillButton(title: "Add Transaction", systemIconName: "plus") {
            isPresentingAddExpense = true
        }
    }

    /// PAY BILLS BATCH ENTRY — an additional action alongside the existing Add Transaction/Edit
    /// pills, never a replacement for them. Presents `PayBillsView` as a compact modal over this
    /// register, matching the exact same `.sheet(isPresented:)` pattern every other action here
    /// already uses.
    private var payBillsButton: some View {
        compactPillButton(title: "Pay Bills", systemIconName: "checklist") {
            isPresentingPayBills = true
        }
    }

    private var editButton: some View {
        compactPillButton(title: "Edit", systemIconName: "pencil") {
            isPresentingEdit = true
        }
    }

    /// A smaller, content-hugging pill — mirrors `PremiumActionButton`'s gradient fill, shape, and
    /// shadow so it still reads as the same kind of control, but (unlike `PremiumActionButton`)
    /// never stretches to fill available width. Shared by `addTransactionButton` and `editButton`
    /// so both stay visually identical without a new `PremiumActionButton` mode that would affect
    /// every other call site of that shared component.
    private func compactPillButton(title: String, systemIconName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: systemIconName)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.accentGradient)
            )
            .shadow(color: Theme.accent.opacity(0.35), radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// Icon-only, at the far right of the row (after `editButton`). Uses the supplied
    /// `CalculatorIcon` asset (a self-contained rounded-square glyph with its own light
    /// background, not an SF Symbol) so it stays clearly visible next to these two bright
    /// gradient pills regardless of theme. The visible glyph is 32×32, centered inside a 44×44 tap
    /// target so the touch area doesn't shrink.
    private var calculatorButton: some View {
        Button {
            isPresentingCalculator = true
        } label: {
            Image("CalculatorIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Calculator")
    }

    /// The consolidated, clearly-visible account-actions control — replaces relying on a tiny
    /// bare glyph anywhere in this screen with a properly sized (44×44), high-contrast, labeled
    /// tap target.
    private var accountOptionsMenu: some View {
        Menu {
            Button("Edit Account", systemImage: "pencil", action: { isPresentingEdit = true })
            Button("Add Transaction", systemImage: "plus", action: { isPresentingAddExpense = true })
            Button("Pay Bills", systemImage: "checklist", action: { isPresentingPayBills = true })
            Divider()
            Button("Delete Account", systemImage: "trash", role: .destructive) {
                isPresentingAccountDeletionConfirmation = true
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Account Options")
    }

    private var hasEligibleManualTransactions: Bool {
        accountTransactions.contains { ManualTransactionDeletionService.eligibility(for: $0) == .eligible }
    }

    private var registerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Register")

            if accountTransactions.isEmpty {
                Text("No transactions yet")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else {
                if hasEligibleManualTransactions {
                    selectControlRow
                    if !isSelectingTransactions {
                        Text("Use the options button or press and hold a manual entry to delete it.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(accountTransactions.enumerated()), id: \.element.id) { index, transaction in
                            transactionRow(transaction)
                            if index < accountTransactions.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    /// BULK DELETE — Select/Cancel, exactly the same control shape
    /// `ExpenseListView.selectControlRow` already established for its own multi-select feature.
    /// Only offered when at least one transaction here is even eligible to delete (a register that
    /// is entirely Plaid-imported, if that were ever possible, would have nothing to select).
    private var selectControlRow: some View {
        HStack {
            Button(isSelectingTransactions ? "Cancel" : "Select") {
                isSelectingTransactions.toggle()
                if !isSelectingTransactions {
                    selectedTransactionIDs = []
                }
            }
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.accent)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    /// Pinned above the bottom safe area via `.safeAreaInset(edge: .bottom)` in `body`, matching
    /// `ExpenseListView.selectedActionBar`'s own placement so it never covers this screen's own
    /// "Done" toolbar/tab chrome.
    private var selectedActionBar: some View {
        HStack {
            Text("\(selectedTransactionIDs.count) Selected")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Delete", role: .destructive) {
                isPresentingBulkDeletionConfirmation = true
            }
            .font(Theme.bodyFont.weight(.semibold))
            .foregroundStyle(Theme.statusOver)
        }
        .padding(Theme.Spacing.md)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func transactionRow(_ transaction: FinanceTransaction) -> some View {
        let isEligibleForDeletion = ManualTransactionDeletionService.eligibility(for: transaction) == .eligible
        HStack(spacing: 0) {
            if isSelectingTransactions {
                // BULK DELETE — a Plaid-imported (ineligible) transaction can still be SHOWN in
                // this register (e.g. `.creditCardPayment` paid FROM this account) but must never
                // be selectable, matching the exact same eligibility gate the single-delete path
                // already enforces — never offer a selection that would silently no-op.
                Button {
                    guard isEligibleForDeletion else { return }
                    if selectedTransactionIDs.contains(transaction.id) {
                        selectedTransactionIDs.remove(transaction.id)
                    } else {
                        selectedTransactionIDs.insert(transaction.id)
                    }
                } label: {
                    Image(systemName: selectedTransactionIDs.contains(transaction.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isEligibleForDeletion ? (selectedTransactionIDs.contains(transaction.id) ? Theme.accent : Theme.textTertiary) : Theme.textTertiary.opacity(0.4))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEligibleForDeletion)
                .padding(.trailing, Theme.Spacing.xs)
                .accessibilityLabel(selectedTransactionIDs.contains(transaction.id) ? "Deselect" : "Select")
            } else {
                // REGISTER PAID CHECKBOX — a purely local "I actually sent/paid this" tracking
                // flag, independent of everything else this transaction represents (see
                // `FinanceTransaction.isPaymentConfirmed`'s own header for the full "never affects
                // any calculation" guarantee). Mirrors Pay Bills' own established checkbox visual
                // (`checkmark.circle.fill`/`circle`) for consistency, never a new visual language.
                Button {
                    transaction.isPaymentConfirmed.toggle()
                } label: {
                    Image(systemName: transaction.isPaymentConfirmed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(transaction.isPaymentConfirmed ? Theme.accent : Theme.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, Theme.Spacing.xs)
                .accessibilityLabel(transaction.isPaymentConfirmed ? "Mark as not yet paid" : "Mark as paid")
            }

            TransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled, showsTypeBadge: true)
                .contextMenu {
                    if !isSelectingTransactions, isEligibleForDeletion {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            transactionPendingDeletion = transaction
                        }
                    }
                }
            if !isSelectingTransactions, isEligibleForDeletion {
                transactionOptionsMenu(for: transaction)
            }
        }
    }

    private func transactionOptionsMenu(for transaction: FinanceTransaction) -> some View {
        Menu {
            // FULL TRANSACTION EDIT (2026-09-17, Scott's own explicit request) — the general
            // editor, offered first since it's the most complete option; the narrower Edit Bill
            // Tag/Amount/Check Number entries below remain as faster single-field shortcuts for
            // the common case, not replaced. Gated to only the types `AddExpenseView` can actually
            // represent — see `AddExpenseView.isEligibleForFullEdit(_:)`'s own header for why a
            // `.balanceAdjustment`/`.creditCardPayment`/`.transfer` entry must never reach it.
            if AddExpenseView.isEligibleForFullEdit(transaction) {
                Button("Edit Transaction", systemImage: "square.and.pencil") {
                    transactionPendingFullEdit = transaction
                }
            }
            // DEPOSIT-TAGGING GAP FIX — a deposit can never be a bill payment (see
            // `TransactionBillTagEditView.showsBillTagPicker`'s own header); hidden here rather
            // than shown-but-disabled inside the sheet.
            if transaction.type == .expense {
                Button("Edit Bill Tag", systemImage: "checklist") {
                    transactionPendingBillTagEdit = transaction
                }
            }
            // AMOUNT EDITING — a deposit has no bill tag to correct, but can still be
            // mis-entered; this is the fix for that (see `TransactionAmountEditView.isEligible`
            // for exactly which types qualify).
            if TransactionAmountEditView.isEligible(transaction) {
                Button("Edit Amount", systemImage: "pencil") {
                    transactionPendingAmountEdit = transaction
                }
            }
            // CHECK PAYMENT PHASE — only offered for a transaction that already has a check
            // number (see `CheckNumberEditView.isEligible`) — never shown for an ordinary
            // expense/deposit/transfer.
            if CheckNumberEditView.isEligible(transaction) {
                Button("Edit Check Number", systemImage: "number") {
                    transactionPendingCheckNumberEdit = transaction
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                transactionPendingDeletion = transaction
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Transaction Options")
    }
}

#Preview {
    ManualAccountDetailView(account: Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55, defaultCountsTowardMonthlySpending: true))
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}
