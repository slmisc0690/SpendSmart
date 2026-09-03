import SwiftUI
import SwiftData

/// CALCULATE TRANSACTIONS PHASE — Settings ▸ Tools ▸ "Calculate Transactions". A READ-ONLY
/// calculator: choose an account, check off individual transactions, see a running subtotal for
/// that account, switch accounts (selections persist), and see one combined grand total across
/// every selected transaction from every account. Never mutates a transaction, account balance,
/// budget, Monthly Plan, exclusion, register entry, or Plaid data — see
/// `CalculateTransactionsCalculator`'s own header for where all the actual math/selection logic
/// lives (pure, stateless, directly testable). Selections live only in this view's own `@State`
/// for the lifetime of this screen's presentation — deliberately NOT persisted to SwiftData/
/// UserDefaults; reopening the calculator later starting empty is expected and preferred.
///
/// PERFORMANCE PHASE — the O(accounts × transactions) preparation work now happens exactly once,
/// in `CalculateTransactionsViewModel.prepare(...)`, called from `.task` below (fires once per
/// screen presentation) rather than as a computed property re-evaluated on every `body` pass — see
/// that type's own header for the verified root cause this replaces.
struct CalculateTransactionsView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var allTransactions: [FinanceTransaction]
    @Query(sort: \Account.name) private var manualAccounts: [Account]
    @Query private var budgetSettingsList: [BudgetSettings]
    @Environment(PlaidConnectionManager.self) private var plaidConnection
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = CalculateTransactionsViewModel()
    @State private var selectedAccountID: String?
    @State private var dateFilter: CalculateTransactionsDateFilter = .all
    /// EXCLUDED-ONLY MODE PHASE — a MODE switch, off by default, purely local to this screen —
    /// never reads/writes `BudgetSettings` itself beyond the read-only `budgetExcludedIDs` lookup
    /// below. OFF: normal, account-scoped view (Budget Excluded rows are shown alongside everything
    /// else, never hidden). ON: overrides/ignores the selected account entirely and shows ONLY
    /// Budget Excluded transactions, gathered across every eligible account. This replaced an
    /// earlier "include excluded transactions too" interpretation that Scott confirmed was wrong —
    /// see this file's git history/session notes for that correction.
    @State private var excludedTransactionsOnly = false
    /// The ONE global selection set this whole screen keys off of — stable `FinanceTransaction.id`
    /// membership, never a row index, never scoped to a single account. This is what makes
    /// selections survive an account switch, date-filter change, or Excluded Transactions toggle
    /// (Part 5's own locked requirement).
    @State private var selectedTransactionIDs: Set<UUID> = []
    @State private var totalMode: CalculateTransactionsCalculator.TotalMode = .signed

    /// CANONICAL BUDGET EXCLUSION MEMBERSHIP — reads the EXACT SAME `BudgetSettings` fields
    /// `BudgetCalculator`/`ExcludeTransactionsView` already own, never a second exclusion concept.
    /// See `CalculateTransactionsCalculator.budgetExcludedIDs(...)`'s own header for the exact
    /// gating rule (the master toggle must also be on, not just a non-empty ID list).
    private var budgetExcludedIDs: Set<UUID> {
        let settings = budgetSettingsList.first
        return CalculateTransactionsCalculator.budgetExcludedIDs(
            excludeTransactionsEnabled: settings?.excludeTransactionsEnabled,
            excludedTransactionIDs: settings?.excludedTransactionIDs
        )
    }

    private var selectedAccountOption: CalculateTransactionsCalculator.AccountOption? {
        viewModel.accountOptions.first { $0.id == selectedAccountID } ?? viewModel.accountOptions.first
    }

    /// The current account's FULL transaction set, unfiltered by date/exclusion — O(1) precomputed
    /// lookup (see `CalculateTransactionsViewModel`), never a fresh table scan.
    private var currentAccountAllTransactions: [FinanceTransaction] {
        guard let selectedAccountOption else { return [] }
        return viewModel.transactions(forAccountOptionID: selectedAccountOption.id)
    }

    /// The VISIBLE list. OFF: the selected account's own transactions, date-filtered — Budget
    /// Excluded rows are never hidden here (a subtle "Excluded" caption marks them instead). ON:
    /// EXCLUDED-ONLY MODE — the selected account no longer applies; instead this gathers every
    /// Budget Excluded transaction across all eligible accounts (`viewModel.allEligibleTransactions`),
    /// then applies the SAME date filter. Never an additive "also include" list — a mode switch.
    private var visibleTransactions: [FinanceTransaction] {
        if excludedTransactionsOnly {
            let excludedAcrossAccounts = CalculateTransactionsCalculator.excludedOnly(from: viewModel.allEligibleTransactions, excludedIDs: budgetExcludedIDs)
            return CalculateTransactionsCalculator.visibleTransactions(from: excludedAcrossAccounts, dateInterval: dateFilter.interval())
        } else {
            return CalculateTransactionsCalculator.visibleTransactions(from: currentAccountAllTransactions, dateInterval: dateFilter.interval())
        }
    }

    /// Activity-style date grouping — reuses `DailyTransactionTotals.groups(for:)` directly
    /// (Part 3's own "reuse Activity's date grouping" requirement), never a second day-bucketing
    /// implementation.
    private var groupedVisibleTransactions: [DailyTransactionTotals.DayGroup] {
        DailyTransactionTotals.groups(for: visibleTransactions)
    }

    private var currentAccountSelectedTransactions: [FinanceTransaction] {
        CalculateTransactionsCalculator.selected(from: currentAccountAllTransactions, selectedIDs: selectedTransactionIDs)
    }

    private var currentAccountSubtotal: Decimal {
        CalculateTransactionsCalculator.total(of: currentAccountSelectedTransactions, mode: totalMode)
    }

    /// EXCLUDED-ONLY MODE — every SELECTED transaction that is currently Budget Excluded, across
    /// ALL eligible accounts (never scoped to one account, since the account filter is overridden
    /// while this mode is on). Independent of the date filter, matching Account Subtotal's own
    /// "counts a selection even if a later filter change hides it" convention.
    private var excludedSelectedTransactions: [FinanceTransaction] {
        let excludedIDs = budgetExcludedIDs
        return CalculateTransactionsCalculator.selected(from: viewModel.allEligibleTransactions, selectedIDs: selectedTransactionIDs)
            .filter { excludedIDs.contains($0.id) }
    }

    private var excludedSubtotal: Decimal {
        CalculateTransactionsCalculator.total(of: excludedSelectedTransactions, mode: totalMode)
    }

    /// The count/amount shown by `subtotalCard` and the selection-controls row — Account Subtotal
    /// while OFF, Excluded Subtotal while ON. A single source of truth so the two views can never
    /// drift out of sync with each other.
    private var currentModeSelectedCount: Int {
        excludedTransactionsOnly ? excludedSelectedTransactions.count : currentAccountSelectedTransactions.count
    }

    private var currentModeSubtotal: Decimal {
        excludedTransactionsOnly ? excludedSubtotal : currentAccountSubtotal
    }

    /// O(selectedCount) via the precomputed `transactionsByID` index — never a full-table scan.
    private var allSelectedTransactions: [FinanceTransaction] {
        viewModel.selectedTransactions(selectedIDs: selectedTransactionIDs)
    }

    private var grandTotal: Decimal {
        CalculateTransactionsCalculator.total(of: allSelectedTransactions, mode: totalMode)
    }

    private var selectedSummaries: [CalculateTransactionsCalculator.SelectedAccountSummary] {
        CalculateTransactionsCalculator.selectedSummaries(
            options: viewModel.accountOptions,
            accountTransactionsByOptionID: viewModel.accountTransactionsByOptionID,
            selectedIDs: selectedTransactionIDs,
            mode: totalMode
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    grandTotalCard

                    if viewModel.isPreparing {
                        loadingState
                    } else if viewModel.accountOptions.isEmpty {
                        emptyAccountsState
                    } else {
                        accountPickerSection
                        dateFilterSection
                        excludedTransactionsToggleSection
                        selectionControlsSection
                        transactionListSection
                        if !selectedSummaries.isEmpty {
                            selectedSummarySection
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Calculate Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            // PERFORMANCE PHASE — runs exactly once per presentation (`.task` without an `id:`
            // fires on first appearance only), never per render/selection change. This IS the
            // fix: the O(accounts × transactions) work that used to happen on every `body` pass
            // now happens here, a single time.
            .task {
                viewModel.prepare(manualAccounts: manualAccounts, allTransactions: allTransactions, connections: plaidConnection.connections)
                if selectedAccountID == nil {
                    selectedAccountID = viewModel.accountOptions.first?.id
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Grand Total (kept prominent, always visible at the top)

    private var grandTotalCard: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Grand Total")
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Picker("Total Mode", selection: $totalMode) {
                        ForEach(CalculateTransactionsCalculator.TotalMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                signedAmountView(grandTotal, font: Theme.amountFont(28))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(totalAccessibilityLabel(prefix: "Grand Total", amount: grandTotal))

                Button("Clear All") {
                    selectedTransactionIDs.removeAll()
                }
                .font(Theme.captionFont)
                .foregroundStyle(selectedTransactionIDs.isEmpty ? Theme.textTertiary : Theme.statusOver)
                .disabled(selectedTransactionIDs.isEmpty)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Loading shell (Part 6 — screen shell first, transactions populate after)

    private var loadingState: some View {
        CardBackground {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("Loading transactions…")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Account picker

    /// EXCLUDED-ONLY MODE PHASE — while `excludedTransactionsOnly` is on, the account filter is
    /// overridden, so the real `Picker` is replaced with a static "All Accounts — Excluded" row
    /// plus an explanatory caption. Crucially, `selectedAccountID` itself is never touched here —
    /// the Picker (and the account it was on) reappears exactly as it was the moment the toggle
    /// goes back off (Part 5's own "do not reset to the first account unnecessarily" requirement).
    private var accountPickerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Account")
            CardBackground {
                if excludedTransactionsOnly {
                    Text("All Accounts — Excluded")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("Account", selection: Binding(
                        get: { selectedAccountOption?.id ?? "" },
                        set: { selectedAccountID = $0 }
                    )) {
                        ForEach(viewModel.accountOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if excludedTransactionsOnly {
                Text("Showing excluded transactions from all accounts")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Date filter

    private var dateFilterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(CalculateTransactionsDateFilter.allCases) { filter in
                    Button {
                        dateFilter = filter
                    } label: {
                        Text(filter.label)
                            .font(Theme.captionFont)
                            .foregroundStyle(dateFilter == filter ? Color.white : Theme.textSecondary)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(dateFilter == filter ? Theme.accent : Theme.cardSurface)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Excluded Transactions option

    /// EXCLUDED-ONLY MODE PHASE — directly beneath the period controls, before the
    /// selected-count/action row (Part 4's own exact placement requirement). This is a MODE
    /// switch: ON replaces the whole list with cross-account Budget Excluded transactions, it does
    /// not merely add them to the current account's list.
    private var excludedTransactionsToggleSection: some View {
        CardBackground(padding: Theme.Spacing.md) {
            Toggle(isOn: $excludedTransactionsOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Excluded Transactions")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Show only Budget Excluded transactions, from every account")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Selection controls

    /// EXCLUDED-ONLY MODE PHASE — "Clear Account" only makes sense while OFF (the list IS one
    /// account). While ON, the list spans every account, so this becomes "Clear Excluded" and only
    /// ever removes selected transactions that are actually Budget Excluded — it must never be
    /// presented as if it controls one account's selections while cross-account rows are showing
    /// (Part 9's own explicit requirement).
    private var selectionControlsSection: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("Selected: \(currentModeSelectedCount)")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Select All") { selectAllVisible() }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.accent)
                .disabled(visibleTransactions.isEmpty)
            if excludedTransactionsOnly {
                Button("Clear Excluded") { clearExcluded() }
                    .font(Theme.captionFont)
                    .foregroundStyle(excludedSelectedTransactions.isEmpty ? Theme.textTertiary : Theme.statusOver)
                    .disabled(excludedSelectedTransactions.isEmpty)
            } else {
                Button("Clear Account") { clearCurrentAccount() }
                    .font(Theme.captionFont)
                    .foregroundStyle(currentAccountSelectedTransactions.isEmpty ? Theme.textTertiary : Theme.statusOver)
                    .disabled(currentAccountSelectedTransactions.isEmpty)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Transaction list (Activity-style date grouping)

    @ViewBuilder
    private var transactionListSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            DashboardSectionHeader(title: "Transactions")
                .padding(.bottom, -Theme.Spacing.sm)

            if visibleTransactions.isEmpty {
                Text(emptyTransactionsMessage)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(groupedVisibleTransactions) { group in
                        daySection(group)
                    }
                }
            }

            subtotalCard
        }
    }

    /// EXCLUDED-ONLY MODE PHASE — ON's empty state must never imply an account has no history at
    /// all (there may be plenty of ordinary transactions — there just aren't any Budget Excluded
    /// ones in range). OFF's empty state is the normal per-account message.
    private var emptyTransactionsMessage: String {
        excludedTransactionsOnly
            ? "No excluded transactions found for this range."
            : "No transactions found for this account and range."
    }

    /// Mirrors `ExpenseListView.daySection`/Activity's own header+CardBackground structure
    /// exactly (Part 3's own "group by date in the same general style as Activity" requirement).
    private func daySection(_ group: DailyTransactionTotals.DayGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                PrivacyAmountView(amount: group.total, isPrivacyModeEnabled: privacyMode.isEnabled, font: Theme.bodyFont, color: Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.lg)

            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(group.transactions.enumerated()), id: \.element.id) { index, transaction in
                        transactionRow(transaction)
                        if index < group.transactions.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// ACTIVITY PARITY — reuses the canonical `TransactionRow` (never a second, independent row
    /// design) with a leading selectable checkbox wrapped around it, exactly the
    /// `[checkbox] [Activity-style transaction content]` shape this phase's own brief describes.
    /// `showsTypeBadge`/`showsCategoryIcon`/`showsExcludedFromReportsIcon` are all turned OFF here
    /// specifically (Activity's own call site is untouched and keeps them) — see
    /// `TransactionRow`'s own header for why the calculator diverges: a second circular icon plus
    /// a near-universal "Expense" badge next to the checkbox left little room for the merchant
    /// name, which was Scott's own physical-device complaint.
    private func transactionRow(_ transaction: FinanceTransaction) -> some View {
        let isSelected = selectedTransactionIDs.contains(transaction.id)
        return HStack(spacing: 0) {
            Button {
                toggleSelection(transaction)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, Theme.Spacing.xs)
            .accessibilityLabel(transactionAccessibilityLabel(transaction, isSelected: isSelected))

            TransactionRow(
                transaction: transaction,
                isPrivacyModeEnabled: privacyMode.isEnabled,
                showsTypeBadge: false,
                showsCategoryIcon: false,
                showsExcludedFromReportsIcon: false,
                budgetExcludedCaption: transactionRowCaption(transaction)
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(transaction) }
    }

    /// OFF: a subtle "Excluded" caption on rows that happen to be Budget Excluded (never hidden).
    /// ON (Part 6): every row IS excluded, so a bare "Excluded" caption on every single row would
    /// be redundant — instead each row identifies its SOURCE account, reusing the same
    /// `AccountOption.displayName` the picker itself already shows (never a second account-label
    /// system).
    private func transactionRowCaption(_ transaction: FinanceTransaction) -> String? {
        if excludedTransactionsOnly {
            return viewModel.accountDisplayName(forTransactionID: transaction.id)
        }
        return budgetExcludedIDs.contains(transaction.id) ? "Excluded" : nil
    }

    // MARK: - Subtotal (Account Subtotal while OFF, Excluded Subtotal while ON — never both)

    private var subtotalCard: some View {
        CardBackground {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(excludedTransactionsOnly ? "Excluded Subtotal" : "Account Subtotal")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(currentModeSelectedCount) selected")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                signedAmountView(currentModeSubtotal, font: Theme.amountFont(18))
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(totalAccessibilityLabel(prefix: excludedTransactionsOnly ? "Excluded Subtotal" : "Account Subtotal", amount: currentModeSubtotal))
    }

    // MARK: - Selected Transactions summary (across all accounts)

    private var selectedSummarySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Selected Transactions")
            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(selectedSummaries.enumerated()), id: \.element.id) { index, summary in
                        Button {
                            selectedAccountID = summary.option.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.option.displayName)
                                        .font(Theme.bodyFont)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("\(summary.selectedCount) selected")
                                        .font(Theme.captionFont)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                signedAmountView(summary.subtotal, font: Theme.bodyFont)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < selectedSummaries.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Empty state

    private var emptyAccountsState: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "function")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.accentGradient)
                Text("No Transactions to Calculate")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Text("Once an account has at least one transaction, it will appear here.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Actions (selection only — never a data mutation)

    private func toggleSelection(_ transaction: FinanceTransaction) {
        if selectedTransactionIDs.contains(transaction.id) {
            selectedTransactionIDs.remove(transaction.id)
        } else {
            selectedTransactionIDs.insert(transaction.id)
        }
    }

    /// Respects the Excluded Transactions mode automatically — `visibleTransactions` IS the
    /// correct set for whichever mode is active (the current account's rows while OFF, only
    /// cross-account Budget Excluded rows while ON), so Select All can never select a row that
    /// doesn't belong in the currently-active mode (Part 8's own explicit requirement).
    private func selectAllVisible() {
        for transaction in visibleTransactions {
            selectedTransactionIDs.insert(transaction.id)
        }
    }

    private func clearCurrentAccount() {
        let ids = Set(currentAccountAllTransactions.map(\.id))
        selectedTransactionIDs.subtract(ids)
    }

    /// EXCLUDED-ONLY MODE PHASE — removes only the selected transactions that are actually Budget
    /// Excluded, regardless of which account they belong to (Part 9's own "Clear Excluded" action).
    /// Never touches a selected transaction that isn't excluded, and never mutates
    /// `BudgetSettings` itself.
    private func clearExcluded() {
        selectedTransactionIDs.subtract(budgetExcludedIDs)
    }

    // MARK: - Display helpers

    /// Renders a possibly-negative total using this app's own established convention (a positive
    /// magnitude plus an explicit "+"/"-" prefix, matching `TransactionRow`/`ConnectedTransactionRow`),
    /// never Foundation's own implicit negative-number formatting.
    private func signedAmountView(_ amount: Decimal, font: Font) -> some View {
        let prefix = amount > 0 ? "+" : (amount < 0 ? "-" : "")
        return PrivacyAmountView(
            amount: abs(amount),
            isPrivacyModeEnabled: privacyMode.isEnabled,
            font: font,
            color: amount < 0 ? Theme.statusOver : Theme.textPrimary,
            prefix: prefix
        )
    }

    private func totalAccessibilityLabel(prefix: String, amount: Decimal) -> String {
        let magnitude = CurrencyFormat.string(from: abs(amount)).replacingOccurrences(of: "$", with: "")
        let sign = amount < 0 ? "negative " : ""
        return "\(prefix), \(sign)\(magnitude) dollars"
    }

    private func transactionAccessibilityLabel(_ transaction: FinanceTransaction, isSelected: Bool) -> String {
        let dateText = transaction.date.formatted(.dateTime.month(.abbreviated).day())
        let amountText = CurrencyFormat.string(from: transaction.amount).replacingOccurrences(of: "$", with: "")
        let signWord = CalculateTransactionsCalculator.signedAmount(for: transaction) < 0 ? "negative " : ""
        let selectionWord = isSelected ? "selected" : "not selected"
        return "\(transaction.displayName), \(dateText), \(signWord)\(amountText) dollars, \(selectionWord)"
    }
}

#Preview {
    CalculateTransactionsView()
        .modelContainer(SampleData.previewContainer)
        .environment(PlaidConnectionManager())
        .environment(PrivacyModeManager())
}
