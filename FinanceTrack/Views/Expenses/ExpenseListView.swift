import SwiftUI
import SwiftData

/// A date range the Activity screen can filter its history to. Purely a display filter — never
/// changes what `BudgetCalculator` counts elsewhere, only what's shown in this list.
enum ActivityDateFilter: String, CaseIterable, Identifiable {
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case lastMonth = "Last Month"
    case quarter = "Quarter"
    case year = "Year"
    case custom = "Custom"

    var id: String { rawValue }
}

/// One selectable Activity source: User B's own `ActivityTab` (Manual Transactions or one of
/// their own connected accounts), or one Primary-shared account. Deliberately a SEPARATE type
/// from `ActivityTab` itself — that enum is also used by `DashboardView`'s Recent Activity widget
/// and `WeeklyBudgetView`'s weekly-spend account filter, neither of which may ever be able to
/// select shared data (shared activity must never affect weekly/monthly spending), so extending
/// `ActivityTab` itself would force those unrelated, calculation-sensitive screens to account for
/// cases that must never reach them. This type exists only to drive `ExpenseListView`'s own tab
/// bar, matching Part B's "same normal account-selection UI" requirement without touching
/// `ActivityTab`/`ActivityTabPresenter`'s existing, tested behavior at all.
private enum ActivitySource: Identifiable, Equatable {
    case owned(ActivityTab)
    case sharedConnected(SharedConnectedAccountDTO)
    case sharedManual(SharedManualAccountDTO)

    var id: String {
        switch self {
        case .owned(let tab): return "owned-\(tab.id)"
        case .sharedConnected(let account): return "shared-connected-\(account.id.uuidString)"
        case .sharedManual(let account): return "shared-manual-\(account.id.uuidString)"
        }
    }

    var label: String {
        switch self {
        case .owned(let tab): return tab.label
        case .sharedConnected(let account): return account.name ?? "Connected Account"
        case .sharedManual(let account): return account.name
        }
    }

    static func == (lhs: ActivitySource, rhs: ActivitySource) -> Bool { lhs.id == rhs.id }
}

/// Transaction history — manual transactions and, separately, each connected Plaid account's
/// activity, selected via a source tab (see `ActivityTabPresenter`). Grouped by day within
/// whichever tab is selected, filterable to a date range. This is a history screen, not where
/// accounts or categories are managed.
///
/// POST-PHASE-10 CORRECTION — Primary-shared Connected/Manual Accounts now appear as additional
/// tabs in the SAME `sourceTabSection` bar as User B's own accounts (Part B: "same normal
/// account-selection UI", not a separate dumped-together list), day-grouped with the same
/// `DailyTransactionTotals` day-bucketing logic (generalized, see that type's own header) and
/// rendered with the same day-header/total/card-list layout as owned connected-account activity.
/// `filteredTransactions`/`dailyGroups` below remain scoped ONLY to User B's own `@Query`-backed
/// `FinanceTransaction` rows, completely unchanged — shared entries flow through a fully separate
/// `sharedEntries`/`sharedDailyGroups` computed pair, sourced from `SharedActivityViewModel`
/// (never SwiftData, never a `FinanceTransaction`), so shared data can never reach
/// `BudgetCalculator`/weekly/monthly spending/budgets/Spend Sense/reports — those all consume
/// `transactions`/`filteredTransactions`, never `sharedEntries`.
struct ExpenseListView: View {
    static let infoExplanation = """
        This is your full transaction history — every expense, deposit, and refund across your \
        accounts, in one searchable list.

        Use the tabs at the top to switch between your own Manual entries and any connected bank \
        or card accounts. Use the filters to narrow the list down to a specific week, month, or \
        custom date range. Tap the + button to add a new entry by hand.

        This screen is a record-keeping view — it shows everything that happened, whether or not \
        it counts toward your Weekly or Monthly spending totals elsewhere in the app. A bill \
        payment or an excluded transaction still shows up here, even though it's left out of \
        those other totals.

        Example: you paid your electric bill and bought groceries on the same day. Both show up \
        here as a complete record, even though the bill payment doesn't count toward your Weekly \
        spending (it's already priced into your Monthly Plan) while the groceries do.
        """

    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(PlaidConnectionManager.self) private var plaidConnection
    @Environment(\.modelContext) private var modelContext
    /// Same already-refreshed instance as everywhere else; read-only here, purely to surface the
    /// Primary-shared account lists that now drive the shared tabs below.
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel

    @State private var isPresentingAdd = false
    @State private var selectedDateFilter: ActivityDateFilter = .thisMonth
    @State private var customRangeStart: Date = .now
    @State private var customRangeEnd: Date = .now
    @State private var transactionPendingDeletion: FinanceTransaction?
    @State private var isPresentingDeletionError = false
    /// nil means "no explicit in-screen choice yet" — `effectiveSource` falls back to whatever
    /// was passed in via `init(initialTab:)`, then to `ActivityTabPresenter.defaultTab`.
    @State private var selectedSource: ActivitySource?
    private let initialTab: ActivityTab?
    /// All currently Primary-shared Connected/Manual Account activity, loaded once per discovered
    /// account list (see `.task(id:)` below) and filtered client-side per selected shared tab —
    /// the same "load everything, filter by tab" pattern `transactions`/`ActivityTabPresenter`
    /// already use for owned data.
    @State private var sharedActivityViewModel = SharedActivityViewModel()

    /// `initialTab` lets a caller (the Dashboard's "More" action) open this screen with a
    /// specific source already selected — never required, so every other existing call site
    /// (the app's own Activity tab) keeps working unchanged with the deterministic default.
    init(initialTab: ActivityTab? = nil) {
        self.initialTab = initialTab
    }

    private var settings: BudgetSettings? { settingsList.first }

    private var ownedTabs: [ActivityTab] {
        ActivityTabPresenter.tabs(transactions: transactions, connections: plaidConnection.connections)
    }

    private var sharedConnectedAccounts: [SharedConnectedAccountDTO] {
        accountRelatedOptionsViewModel.response?.primarySharedConnectedAccounts ?? []
    }

    private var sharedManualAccounts: [SharedManualAccountDTO] {
        accountRelatedOptionsViewModel.response?.primarySharedManualAccounts ?? []
    }

    private var sharedAccountKey: [UUID] {
        sharedConnectedAccounts.map(\.id) + sharedManualAccounts.map(\.id)
    }

    /// Owned tabs first (unchanged order/composition — see `ActivityTabPresenter`), then every
    /// currently-shared account, so "American Express / Chase / Manual Transactions" (owned) and
    /// any Primary-shared accounts all appear in the same bar.
    private var sources: [ActivitySource] {
        ownedTabs.map(ActivitySource.owned)
            + sharedConnectedAccounts.map(ActivitySource.sharedConnected)
            + sharedManualAccounts.map(ActivitySource.sharedManual)
    }

    private var effectiveSource: ActivitySource {
        if let selectedSource, sources.contains(selectedSource) { return selectedSource }
        if let initialTab {
            let wrapped = ActivitySource.owned(initialTab)
            if sources.contains(wrapped) { return wrapped }
        }
        return .owned(ActivityTabPresenter.defaultTab(tabs: ownedTabs))
    }

    private var selectedInterval: DateInterval {
        switch selectedDateFilter {
        case .thisWeek:
            return DateRangeHelper.currentWeekRange(weekStartsOnSunday: settings?.weekStartsOnSunday ?? true)
        case .thisMonth:
            return DateRangeHelper.currentMonthRange()
        case .lastMonth:
            return DateRangeHelper.lastMonthRange()
        case .quarter:
            return DateRangeHelper.currentQuarterRange()
        case .year:
            return DateRangeHelper.currentYearRange()
        case .custom:
            let start = min(customRangeStart, customRangeEnd)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: max(customRangeStart, customRangeEnd)) ?? customRangeEnd
            return DateInterval(start: start, end: end)
        }
    }

    /// Scoped to the selected OWNED tab only — `nil` whenever a shared tab is selected, so this
    /// (and everything derived from it) never has anything to compute for shared data. Unchanged
    /// from before this correction for every owned tab.
    private var filteredTransactions: [FinanceTransaction] {
        guard case .owned(let tab) = effectiveSource else { return [] }
        return ActivityTabPresenter.transactions(for: tab, in: transactions)
            .filter { selectedInterval.contains($0.date) }
    }

    /// One entry per day with at least one transaction in range, newest first. Unchanged from
    /// before this correction — still only ever built from `filteredTransactions` above.
    private var dailyGroups: [(day: Date, transactions: [FinanceTransaction], total: Decimal)] {
        guard case .owned(let tab) = effectiveSource else { return [] }
        switch tab {
        case .manual:
            let calendar = Calendar.current
            let days = Set(filteredTransactions.map { calendar.startOfDay(for: $0.date) }).sorted(by: >)
            return days.map { day in
                let dayTransactions = filteredTransactions
                    .filter { calendar.isDate($0.date, inSameDayAs: day) }
                    .sorted { $0.date > $1.date }
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let total = BudgetCalculator.monthlySpent(dayTransactions, in: DateInterval(start: day, end: dayEnd), includePending: true)
                return (day, dayTransactions, total)
            }
        case .connectedAccount:
            return DailyTransactionTotals.groups(for: filteredTransactions).map { ($0.day, $0.transactions, $0.total) }
        }
    }

    /// Every shared entry belonging to the currently-selected shared tab, within the same
    /// `selectedInterval` owned tabs use — empty whenever an owned tab is selected. `Entry.date`
    /// is optional (a shared row with no known date can't be placed in a specific day); those are
    /// simply excluded here rather than grouped under an arbitrary day.
    private var sharedEntries: [SharedActivityViewModel.Entry] {
        let matchesSource: (SharedActivityViewModel.Entry) -> Bool
        switch effectiveSource {
        case .owned:
            return []
        case .sharedConnected(let account):
            matchesSource = { $0.connectedAccountId == account.id }
        case .sharedManual(let account):
            matchesSource = { $0.manualAccountId == account.id }
        }
        return sharedActivityViewModel.entries.filter { entry in
            guard let date = entry.date else { return false }
            return matchesSource(entry) && selectedInterval.contains(date)
        }
    }

    /// Same day-bucketing algorithm as owned connected-account activity
    /// (`DailyTransactionTotals.genericGroups`), applied to shared entries. Every shared entry's
    /// full `amount` contributes to the day total exactly the way `ConnectedTransactionRow`/
    /// `DailyTransactionTotals.spendingDelta` treat owned Plaid activity (always shown/summed as
    /// spending) — shared rows are read-only reference data, never a budget-eligibility input.
    private var sharedDailyGroups: [DailyTransactionTotals.GenericDayGroup<SharedActivityViewModel.Entry>] {
        DailyTransactionTotals.genericGroups(for: sharedEntries, date: { $0.date ?? .distantPast }, delta: { $0.amount })
    }

    /// The safe "Paid With" label for a general Manual Transaction's optional connected-account
    /// attribution — `nil` for a Plaid-imported row, a Manual Account transaction, or a legacy
    /// Manual Transaction with no attribution.
    private func connectedAccountLabel(for transaction: FinanceTransaction) -> String? {
        ConnectedAccountOptionPresenter.label(forAccountId: transaction.plaidAccountId, in: plaidConnection.connections)
    }

    /// This transaction's contribution to the Activity screen's own filtered Total — deliberately
    /// the SAME signed convention each row already displays (`TransactionRow`/
    /// `ConnectedTransactionRow`'s own `signPrefix`: expense negative, refund/income positive,
    /// transfer/creditCardPayment/balanceAdjustment shown as a plain positive figure), never
    /// `DailyTransactionTotals.spendingDelta`/`BudgetCalculator`'s "amount spent" conventions —
    /// this Total answers "what do these displayed rows arithmetically add up to," not "how much
    /// was spent," so it must never be floored at zero or sign-flipped the way those are.
    private func signedActivityAmount(for transaction: FinanceTransaction) -> Decimal {
        switch transaction.type {
        case .expense, .transferWithdrawal: return -transaction.amount
        case .refund, .income, .transferDeposit: return transaction.amount
        case .transfer, .creditCardPayment, .balanceAdjustment: return transaction.amount
        }
    }

    /// The arithmetic sum of exactly `filteredTransactions` — the same collection `dailyGroups`
    /// itself partitions into day buckets, so this can never disagree with what's on screen and
    /// never double-counts a row (every transaction appears in exactly one day bucket).
    private var filteredTransactionsTotal: Decimal {
        filteredTransactions.reduce(Decimal(0)) { $0 + signedActivityAmount(for: $1) }
    }

    /// The signed sum of exactly the `filteredTransactions` rows where `isPending == false` —
    /// this reads each transaction's own existing `isPending` flag directly, never infers it, and
    /// never independently applies the Budget Settings pending-inclusion toggle (a budgeting-rule
    /// setting, not a display filter): if a pending row is currently visible on screen, it is
    /// simply excluded from this subtotal and counted in `pendingTransactionsTotal` instead —
    /// Activity's own visibility is completely unchanged by this split.
    private var postedTransactionsTotal: Decimal {
        filteredTransactions.filter { !$0.isPending }.reduce(Decimal(0)) { $0 + signedActivityAmount(for: $1) }
    }

    /// The signed sum of exactly the `filteredTransactions` rows where `isPending == true`. Every
    /// `filteredTransactions` row is either posted or pending, never both, so
    /// `postedTransactionsTotal + pendingTransactionsTotal` always equals `filteredTransactionsTotal`
    /// exactly — this is a straight partition of the same array, not two separate computations
    /// that could drift apart.
    private var pendingTransactionsTotal: Decimal {
        filteredTransactions.filter { $0.isPending }.reduce(Decimal(0)) { $0 + signedActivityAmount(for: $1) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if sources.count > 1 {
                        sourceTabSection
                    }
                    filterSection

                    if case .owned = effectiveSource {
                        ownedActivityList
                    } else {
                        sharedActivityList
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    InfoButton(title: "About Activity", explanation: Self.infoExplanation)
                }
                // Only Manual Transactions can be added from here — a connected-account tab
                // (owned or shared) is a read-only reference list (see `ConnectedTransactionRow`'s
                // own doc comment), so adding a new entry from it would have nowhere correct to go.
                if effectiveSource == .owned(.manual) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isPresentingAdd = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $isPresentingAdd) {
                AddExpenseView()
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
        }
        .preferredColorScheme(.dark)
        .task(id: sharedAccountKey) {
            await sharedActivityViewModel.load(connectedAccounts: sharedConnectedAccounts, manualAccounts: sharedManualAccounts)
        }
    }

    // MARK: - Owned activity (unchanged behavior)

    @ViewBuilder
    private var ownedActivityList: some View {
        if dailyGroups.isEmpty {
            ContentUnavailableView(
                "No Activity",
                systemImage: "list.bullet.rectangle",
                description: Text("Nothing was entered in this date range.")
            )
            .padding(.top, Theme.Spacing.xl)
        } else {
            VStack(spacing: Theme.Spacing.lg) {
                ForEach(dailyGroups, id: \.day) { group in
                    daySection(group)
                }
                activityTotalRow
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// The filtered-result totals, shown once at the very bottom of the currently displayed rows
    /// (after the final day group) — hidden entirely whenever `dailyGroups` is empty, since
    /// `ownedActivityList` already shows a clean `ContentUnavailableView` in that case and a
    /// $0.00 totals card would just add a redundant, misleading-looking line beneath it.
    ///
    /// Posted Transactions + Pending Transactions always reconciles exactly to Total — all three
    /// are computed from the SAME `filteredTransactions` array (Posted/Pending are a straight
    /// partition of it by `isPending`, Total is the unfiltered sum), never a second query, and
    /// never independently re-applies the Budget Settings pending-inclusion toggle — this is a
    /// display reconciliation of what's already on screen, not a budgeting-rule change.
    private var activityTotalRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            activityAmountRow(label: "Posted Transactions", amount: postedTransactionsTotal, emphasized: false)
            activityAmountRow(label: "Pending Transactions", amount: pendingTransactionsTotal, emphasized: false)
            Divider().overlay(Theme.cardStroke)
            activityAmountRow(label: "Total", amount: filteredTransactionsTotal, emphasized: true)
        }
        .padding(.top, Theme.Spacing.xs)
    }

    @ViewBuilder
    private func activityAmountRow(label: String, amount: Decimal, emphasized: Bool) -> some View {
        HStack {
            Text(label)
                .font(Theme.headlineFont)
                .foregroundStyle(emphasized ? Theme.textPrimary : Theme.textSecondary)
            Spacer()
            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: privacyMode.isEnabled,
                font: Theme.headlineFont,
                color: emphasized ? Theme.textPrimary : Theme.textSecondary
            )
        }
    }

    // MARK: - Shared activity (same normal day-grouped presentation, separate data path)

    @ViewBuilder
    private var sharedActivityList: some View {
        if sharedActivityViewModel.isLoading && sharedEntries.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xl)
        } else if sharedDailyGroups.isEmpty {
            ContentUnavailableView(
                "No Activity",
                systemImage: "list.bullet.rectangle",
                description: Text("Nothing was entered in this date range.")
            )
            .padding(.top, Theme.Spacing.xl)
        } else {
            VStack(spacing: Theme.Spacing.lg) {
                ForEach(sharedDailyGroups) { group in
                    sharedDaySection(group)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Source tabs (Manual Transactions, each owned connected account, each shared account)

    private var sourceTabSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(sources) { source in
                    FilterChip(title: source.label, isSelected: source == effectiveSource) {
                        selectedSource = source
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Filters

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(ActivityDateFilter.allCases) { filter in
                        FilterChip(title: filter.rawValue, isSelected: selectedDateFilter == filter) {
                            selectedDateFilter = filter
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }

            if selectedDateFilter == .custom {
                CardBackground {
                    VStack(spacing: Theme.Spacing.sm) {
                        DatePicker("From", selection: $customRangeStart, displayedComponents: .date)
                            .tint(Theme.accent)
                            .foregroundStyle(Theme.textPrimary)
                        DatePicker("To", selection: $customRangeEnd, displayedComponents: .date)
                            .tint(Theme.accent)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Day section (owned)

    @ViewBuilder
    private func daySection(_ group: (day: Date, transactions: [FinanceTransaction], total: Decimal)) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                PrivacyAmountView(
                    amount: group.total,
                    isPrivacyModeEnabled: privacyMode.isEnabled,
                    font: Theme.bodyFont,
                    color: Theme.textSecondary
                )
            }

            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(group.transactions.enumerated()), id: \.element.id) { index, transaction in
                        transactionRow(for: transaction)
                        if index < group.transactions.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Day section (shared) — same layout as `daySection` above, entries instead of `FinanceTransaction`

    @ViewBuilder
    private func sharedDaySection(_ group: DailyTransactionTotals.GenericDayGroup<SharedActivityViewModel.Entry>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                PrivacyAmountView(
                    amount: group.total,
                    isPrivacyModeEnabled: privacyMode.isEnabled,
                    font: Theme.bodyFont,
                    color: Theme.textSecondary
                )
            }

            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, entry in
                        SharedActivityTransactionRow(entry: entry, isPrivacyModeEnabled: privacyMode.isEnabled)
                        if index < group.items.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
        }
    }

    /// Connected (Plaid) transactions render via the minimal, read-only `ConnectedTransactionRow`
    /// — no context menu, no options menu, no editing surface of any kind, matching "connected
    /// activity is a simple reference list." Manual transactions keep their exact prior
    /// presentation and behavior (full `TransactionRow`, delete context menu/options menu).
    @ViewBuilder
    private func transactionRow(for transaction: FinanceTransaction) -> some View {
        if transaction.source == .plaid {
            ConnectedTransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled)
        } else {
            HStack(spacing: 0) {
                TransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled, showsTypeBadge: true, connectedAccountLabel: connectedAccountLabel(for: transaction))
                    .contextMenu {
                        if ManualTransactionDeletionService.eligibility(for: transaction) == .eligible {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                transactionPendingDeletion = transaction
                            }
                        }
                    }
                if ManualTransactionDeletionService.eligibility(for: transaction) == .eligible {
                    transactionOptionsMenu(for: transaction)
                }
            }
        }
    }

    private func transactionOptionsMenu(for transaction: FinanceTransaction) -> some View {
        Menu {
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

/// A shared-account transaction row styled identically to `ConnectedTransactionRow` (same fonts,
/// pending badge, "-" prefix, privacy-mode support) — Part B's "same normal account-selection UI"
/// requirement extends to row styling, not just the tab bar. No context menu/options menu, same as
/// `ConnectedTransactionRow` — shared activity is read-only reference data.
private struct SharedActivityTransactionRow: View {
    let entry: SharedActivityViewModel.Entry
    var isPrivacyModeEnabled: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.description)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if entry.isPending {
                        Text("Pending")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.statusWarning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.statusWarning.opacity(0.15)))
                    }
                }
                if let date = entry.date {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            PrivacyAmountView(
                amount: entry.amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.bodyFont,
                color: Theme.textPrimary,
                prefix: "-"
            )
        }
    }
}

#Preview {
    ExpenseListView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
        .environment(AccountRelatedOptionsViewModel())
}

#Preview("Empty") {
    ExpenseListView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
        .environment(AccountRelatedOptionsViewModel())
}
