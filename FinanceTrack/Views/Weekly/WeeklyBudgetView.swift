import SwiftUI
import SwiftData

struct WeeklyBudgetView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]

    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaidConnectionManager.self) private var plaidConnection
    /// SECONDARY PARITY — same already-refreshed instance every other Secondary-aware screen
    /// reads (`DashboardView`/`ExpenseListView`), purely to determine role and the Primary-shared
    /// account list. Never mutated from this view.
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel

    @State private var isPresentingEditLimit = false
    @State private var selectedFilter: WeeklyBreakdownFilter = .manualTransactions
    /// nil means "no explicit choice yet" — falls back to the first available connected account,
    /// same pattern `ExpenseListView`/`DashboardView` use for their own tab selection.
    @State private var selectedConnectedAccountId: String?
    /// SECONDARY PARITY — the Primary's authoritative shared Dashboard aggregate, reused here
    /// verbatim for the hero card (Spent/Limit/Remaining) rather than a second reconstruction —
    /// same instance-management pattern as `DashboardView.dashboardSummaryViewModel`.
    @State private var dashboardSummaryViewModel: SharedDashboardSummaryViewModel?
    /// SECONDARY PARITY — every Primary-shared Connected Account's transaction feed, loaded once
    /// per discovered account list, filtered client-side to this week for the daily breakdown.
    /// Manual Accounts are deliberately excluded from this screen's `load()` call for now (no
    /// shared Manual Account daily/category feed exists yet) — see this screen's own Secondary
    /// daily breakdown section for the explicit "not yet available" messaging that follows from
    /// that omission.
    @State private var sharedActivityViewModel = SharedActivityViewModel()

    private var settings: BudgetSettings? { settingsList.first }

    private var isSecondary: Bool {
        accountRelatedOptionsViewModel.response?.role == .secondary
    }

    private var accountRelatedOptionsLoaded: Bool {
        if case .loaded = accountRelatedOptionsViewModel.state { return true }
        return false
    }

    /// Mirrors `DashboardView.secondaryOutlookAuthorized` exactly — the same single gate this
    /// screen's hero card and Account-sourced daily breakdown are both authorized by.
    private var secondaryOutlookAuthorized: Bool {
        accountRelatedOptionsLoaded && isSecondary && accountRelatedOptionsViewModel.response?.primaryMonthlyPlanShared == true
    }

    private var secondaryOutlookPrimaryUserId: UUID? {
        guard secondaryOutlookAuthorized else { return nil }
        return accountRelatedOptionsViewModel.response?.primaryUserId
    }

    private var secondaryDashboardSummaryLoadKey: String {
        guard let primaryUserId = secondaryOutlookPrimaryUserId else { return "unauthorized" }
        return primaryUserId.uuidString
    }

    @MainActor
    private func loadDashboardSummaryIfNeeded() async {
        guard let primaryUserId = secondaryOutlookPrimaryUserId else {
            dashboardSummaryViewModel = nil
            return
        }
        let viewModel: SharedDashboardSummaryViewModel
        if let existing = dashboardSummaryViewModel, existing.primaryUserId == primaryUserId {
            viewModel = existing
        } else {
            viewModel = SharedDashboardSummaryViewModel(primaryUserId: primaryUserId)
            dashboardSummaryViewModel = viewModel
        }
        await viewModel.load()
    }

    private var sharedDashboardSummary: SharedDashboardSummaryDTO? {
        guard case .loaded(let summary?) = dashboardSummaryViewModel?.state else { return nil }
        return summary
    }

    private var sharedConnectedAccounts: [SharedConnectedAccountDTO] {
        accountRelatedOptionsViewModel.response?.primarySharedConnectedAccounts ?? []
    }

    private var sharedConnectedAccountsKey: [UUID] {
        sharedConnectedAccounts.map(\.id)
    }

    @MainActor
    private func loadSharedActivityIfNeeded() async {
        guard secondaryOutlookAuthorized else { return }
        await sharedActivityViewModel.load(connectedAccounts: sharedConnectedAccounts, manualAccounts: [])
    }

    /// This week's shared entries, day-grouped — same `genericGroups` bucketing
    /// `ExpenseListView`'s own shared Activity list uses, scoped to this screen's `weekInterval`.
    private var sharedDailyGroups: [DailyTransactionTotals.GenericDayGroup<SharedActivityViewModel.Entry>] {
        let entries = sharedActivityViewModel.entries.filter { entry in
            guard let date = entry.date else { return false }
            return weekInterval.contains(date)
        }
        return DailyTransactionTotals.genericGroups(for: entries, date: { $0.date ?? .distantPast }, delta: { $0.amount })
    }

    /// MONTH-ALIGNED FOUR-WEEK CORRECTION — matches `DashboardView`'s own identically-corrected
    /// `weekInterval` exactly, so Weekly Budget and Dashboard can never disagree about which days
    /// make up "this week." See `DateRangeHelper.fourWeekBlocks(in:)`'s own header.
    private var weekInterval: DateInterval {
        DateRangeHelper.currentFourWeekBlock()
    }

    private var includePending: Bool {
        settings?.includePendingTransactions ?? true
    }

    /// AUTO-TRACKED CONNECTED-ACCOUNT BUDGETING — see `DashboardView.autoTrackedAccountIds`'s own
    /// header for why this is a plain read-only computed property, not a `@State` snapshot.
    private var autoTrackedAccountIds: Set<String> {
        Set(settings?.autoCalculateConnectedAccountIds ?? [])
    }

    /// EXCLUDE TRANSACTIONS — see `DashboardView.excludedTransactionIDs`'s own header for the
    /// master-toggle gating this respects.
    private var excludedTransactionIDs: Set<UUID> {
        guard settings?.excludeTransactionsEnabled ?? false else { return [] }
        return Set(settings?.excludedTransactionIDs ?? [])
    }

    private var spentThisWeek: Decimal {
        BudgetCalculator.weeklyActualSpending(transactions, in: weekInterval, includePending: includePending, autoTrackedAccountIds: autoTrackedAccountIds, excludedTransactionIDs: excludedTransactionIDs)
    }

    /// WEEKLY SPENDING UNIFICATION (Part 5) — computed live from the SAME authoritative
    /// `MonthlyPlanCalculator.effectivePlannedWeeklySpending` formula Monthly Plan/Dashboard use
    /// (custom override when set, otherwise Flexible Spending Available ÷ 4), never
    /// `BudgetSettings.weeklySpendingLimit` directly — that field is a synced snapshot only
    /// refreshed when Monthly Plan/Settings screens are visited, so reading it here could show a
    /// stale number if this screen is opened first. Editing continues to edit the same
    /// `MonthlyPlanSettings.plannedWeeklySpendingOverride` Monthly Plan's own editor writes — see
    /// `WeeklyLimitEditView`, which now receives this exact value rather than reading
    /// `BudgetSettings` itself.
    private var effectivePlannedWeeklySpending: Decimal {
        let month = DateRangeHelper.currentMonthRange()
        let monthlyPlanSettings = monthlyPlanSettingsList.first
        let income = MonthlyPlanCalculator.estimatedMonthlyIncome(incomeSources, in: month)
        let fixedExpenses = MonthlyPlanCalculator.estimatedMonthlyFixedExpenses(recurringExpenses, in: month)
        let goal = monthlyPlanSettings?.monthlySavingsGoal ?? 0
        let buffer = monthlyPlanSettings?.bufferAmount ?? 0
        let flexible = MonthlyPlanCalculator.flexibleSpendingAvailable(income: income, fixedExpenses: fixedExpenses, savingsGoal: goal, bufferAmount: buffer)
        return MonthlyPlanCalculator.effectivePlannedWeeklySpending(override: monthlyPlanSettings?.plannedWeeklySpendingOverride, flexibleSpendingAvailable: flexible)
    }

    private var weeklyLimit: Decimal {
        effectivePlannedWeeklySpending
    }

    private var status: SpendingStatus {
        BudgetCalculator.status(
            spent: spentThisWeek,
            limit: weeklyLimit,
            warningThreshold: settings?.warningThreshold ?? 0.70
        )
    }

    private var categoryTotals: [BudgetCalculator.CategoryTotal] {
        BudgetCalculator.categoryTotals(transactions, in: weekInterval, includePending: includePending, context: .weekly)
    }

    /// Every transaction dated within the current week, regardless of type or filter — the base
    /// set both the daily totals and the filter chips draw from.
    private var transactionsThisWeek: [FinanceTransaction] {
        transactions.filter { weekInterval.contains($0.date) }
    }

    /// This week's qualifying general Manual Transactions — locally entered (`source != .plaid`),
    /// never owned by a manually created Manual Account (`account == nil`, the same rule
    /// `ActivityTabPresenter` uses), and eligible per the existing weekly budget rules. Preserves
    /// the population/behavior the former "All Counted" filter represented, corrected to exclude
    /// Manual Account-owned rows (which `isCounted` alone never filtered out).
    private var manualTransactionsThisWeek: [FinanceTransaction] {
        transactionsThisWeek.filter { $0.account == nil && BudgetCalculator.isCounted($0, includePending: includePending, context: .weekly) }
    }

    /// Every connected-account tab actually represented by this week's transactions — reuses
    /// `ActivityTabPresenter` rather than re-deriving the same account list a second way.
    private var connectedAccountTabs: [ActivityTab] {
        ActivityTabPresenter.tabs(transactions: transactionsThisWeek, connections: plaidConnection.connections)
            .filter { if case .connectedAccount = $0 { return true }; return false }
    }

    /// The connected account Account Pending/Account All currently show — the user's explicit
    /// choice if it's still valid, otherwise the first available connected account, otherwise
    /// `nil` (no connected activity this week at all).
    private var effectiveConnectedAccountTab: ActivityTab? {
        if let selectedConnectedAccountId, let match = connectedAccountTabs.first(where: { $0.id == selectedConnectedAccountId }) {
            return match
        }
        return connectedAccountTabs.first
    }

    /// This week's imported transactions for the currently selected connected account only —
    /// never another connected account, never a locally entered Manual Transaction (even one
    /// "Paid With" this same account — that's attribution metadata, not account membership).
    private var accountAllTransactionsThisWeek: [FinanceTransaction] {
        guard let tab = effectiveConnectedAccountTab else { return [] }
        return ActivityTabPresenter.transactions(for: tab, in: transactionsThisWeek)
    }

    private var accountPendingTransactionsThisWeek: [FinanceTransaction] {
        accountAllTransactionsThisWeek.filter { $0.isPending }
    }

    /// One entry per day for the selected filter's population.
    ///
    /// Manual Transactions keeps the existing `BudgetCalculator`-derived total (net
    /// expense-minus-refund, gated by the weekly budget flag) — its sign/eligibility behavior is
    /// unchanged. Account Pending/Account All use `DailyTransactionTotals` instead: imported rows
    /// always have `countsTowardWeeklyBudget == false` by design, so a `BudgetCalculator` total
    /// over them is always $0.00 regardless of how many rows are visible — these two use an exact
    /// sum of the displayed rows instead, so the heading can never disagree with what's listed.
    private var dailyGroups: [(day: Date, transactions: [FinanceTransaction], total: Decimal)] {
        switch selectedFilter {
        case .manualTransactions:
            let calendar = Calendar.current
            let days = Set(manualTransactionsThisWeek.map { calendar.startOfDay(for: $0.date) }).sorted(by: >)
            return days.map { day in
                let rows = manualTransactionsThisWeek
                    .filter { calendar.isDate($0.date, inSameDayAs: day) }
                    .sorted { $0.date > $1.date }
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let total = BudgetCalculator.weeklySpent(rows, in: DateInterval(start: day, end: dayEnd), includePending: includePending)
                return (day, rows, total)
            }
        case .accountPending:
            return DailyTransactionTotals.groups(for: accountPendingTransactionsThisWeek).map { ($0.day, $0.transactions, $0.total) }
        case .accountAll:
            return DailyTransactionTotals.groups(for: accountAllTransactionsThisWeek).map { ($0.day, $0.transactions, $0.total) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header
                    heroSection
                    if isSecondary {
                        secondaryRefreshButton
                        secondaryDailyBreakdownSection
                    } else {
                        pendingToggleSection
                        categoryBreakdownSection
                        dailyBreakdownSection
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $isPresentingEditLimit) {
                WeeklyLimitEditView(limit: weeklyLimit)
            }
            .task(id: secondaryDashboardSummaryLoadKey) {
                await loadDashboardSummaryIfNeeded()
            }
            .task(id: sharedConnectedAccountsKey) {
                await loadSharedActivityIfNeeded()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly Budget")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Sunday through Saturday")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            InfoButton(title: "About Weekly Budget", explanation: Self.infoExplanation)
                .padding(.top, 6)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    static let infoExplanation = """
        A closer look at just this week's spending — how much you've spent, how it breaks down \
        by category, and day by day.

        The top card shows your Spent, Limit, and Remaining for the week, the same figures shown \
        on the Dashboard's "This Week" card. Below that, the category breakdown shows which kinds \
        of purchases (groceries, gas, dining, etc.) made up your spending, and the daily breakdown \
        shows exactly what you bought each day.

        Example: your weekly limit is $500 and the category breakdown shows $180 on groceries, \
        $90 on gas, and $50 on dining — together with anything else you bought, that adds up to \
        your total Spent for the week.
        """

    // MARK: - Hero

    /// URGENT REGRESSION FIX — always renders the normal hero card, in both Automatic and Custom
    /// weekly mode. The removed local unconfigured-gate (limit greater than zero) incorrectly hid
    /// it behind a setup prompt whenever a deliberate custom zero override was active — a real,
    /// legitimate weekly limit, not an unconfigured state (see `MonthlyPlanCalculator.
    /// effectivePlannedWeeklySpending`'s own zero-semantics rule). Automatic mode's own value
    /// (Flexible Spending Available ÷ 4) is likewise a real number the moment income/bills exist,
    /// never something requiring setup first.
    @ViewBuilder
    private var heroSection: some View {
        if isSecondary {
            // SECONDARY PARITY — reads the Primary's own authoritative shared aggregate
            // (`sharedDashboardSummary`), the exact same numbers `DashboardView`'s own This Week
            // card shows for a Secondary — never a second independent reconstruction. Tapping
            // does nothing (no `WeeklyLimitEditView` — a Secondary never edits the Primary's own
            // weekly limit).
            if secondaryOutlookAuthorized, let summary = sharedDashboardSummary {
                WeeklyBudgetHeroCard(
                    weekInterval: weekInterval,
                    spent: summary.actualSpentThisWeek,
                    limit: summary.weeklySpendingLimit,
                    status: BudgetCalculator.status(spent: summary.actualSpentThisWeek, limit: summary.weeklySpendingLimit, warningThreshold: settings?.warningThreshold ?? 0.70),
                    isPrivacyModeEnabled: privacyMode.isEnabled
                ) {}
                .padding(.horizontal, Theme.Spacing.lg)
            }
            // else: not authorized, or shared data not yet loaded — nothing, never a fake local
            // "set a budget" prompt for a Secondary.
        } else {
            WeeklyBudgetHeroCard(
                weekInterval: weekInterval,
                spent: spentThisWeek,
                limit: weeklyLimit,
                status: status,
                isPrivacyModeEnabled: privacyMode.isEnabled
            ) {
                isPresentingEditLimit = true
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// SECONDARY PARITY — explicit, on-demand re-pull of the Primary's shared Dashboard aggregate
    /// AND shared Connected Account activity, matching the styling Scott requested for the
    /// Dashboard's own equivalent control.
    private var secondaryRefreshButton: some View {
        Button {
            Task {
                await loadDashboardSummaryIfNeeded()
                await loadSharedActivityIfNeeded()
            }
        } label: {
            HStack(spacing: 6) {
                if dashboardSummaryViewModel?.isRefreshing == true || sharedActivityViewModel.isLoading {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("Refresh Weekly Budget")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 10)
            .background(Theme.accent, in: Capsule())
        }
        .disabled(dashboardSummaryViewModel?.isRefreshing == true || sharedActivityViewModel.isLoading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Secondary daily breakdown

    /// SECONDARY PARITY — day-grouped shared Connected Account activity for the week, reusing the
    /// same `SharedActivityTransactionRow` presentation `ExpenseListView`'s own shared Activity
    /// list already uses. No filter chips (Manual Transactions/Account Pending/Account All have
    /// no shared equivalent to switch between yet) and no category breakdown — the shared feed
    /// carries no category data (see `plaid_transactions`'s own by-design omission).
    private var secondaryDailyBreakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Daily Breakdown")

            if !secondaryOutlookAuthorized {
                Text("Not shared yet")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else if sharedActivityViewModel.isLoading && sharedDailyGroups.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.md)
            } else if sharedDailyGroups.isEmpty {
                Text("No transactions this week yet")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else {
                VStack(spacing: Theme.Spacing.lg) {
                    ForEach(sharedDailyGroups) { group in
                        secondaryDaySection(group)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    private func secondaryDaySection(_ group: DailyTransactionTotals.GenericDayGroup<SharedActivityViewModel.Entry>) -> some View {
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

    // MARK: - Include pending toggle

    private var pendingToggleSection: some View {
        CardBackground {
            TransactionToggleRow(
                title: "Include Pending Transactions",
                subtitle: "When off, pending transactions won't count toward your totals",
                isOn: Binding(
                    get: { includePending },
                    set: { newValue in
                        if let settings {
                            settings.includePendingTransactions = newValue
                            settings.updatedAt = .now
                        } else {
                            let created = BudgetSettings(includePendingTransactions: newValue)
                            modelContext.insert(created)
                        }
                    }
                )
            )
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Category breakdown

    private var categoryBreakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Category Breakdown")

            if categoryTotals.isEmpty {
                CardBackground {
                    VStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "chart.pie.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                        Text("No spending tracked this week yet.")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        Text("Add expenses from the Dashboard.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(categoryTotals.enumerated()), id: \.element.id) { index, categoryTotal in
                            CategoryBreakdownRow(
                                categoryTotal: categoryTotal,
                                periodTotal: spentThisWeek,
                                isPrivacyModeEnabled: privacyMode.isEnabled
                            )
                            if index < categoryTotals.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Daily breakdown

    private var dailyBreakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Daily Breakdown")

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(WeeklyBreakdownFilter.allCases) { filter in
                    FilterChip(title: filter.rawValue, isSelected: selectedFilter == filter) {
                        selectedFilter = filter
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if selectedFilter != .manualTransactions, connectedAccountTabs.count > 1 {
                connectedAccountSelector
            }

            if selectedFilter != .manualTransactions, connectedAccountTabs.isEmpty {
                Text("No connected account activity this week yet")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else if dailyGroups.isEmpty {
                Text("No transactions this week yet")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else {
                VStack(spacing: Theme.Spacing.lg) {
                    ForEach(dailyGroups, id: \.day) { group in
                        DailyTransactionGroup(
                            day: group.day,
                            transactions: group.transactions,
                            dailyTotal: group.total,
                            isPrivacyModeEnabled: privacyMode.isEnabled,
                            connectedAccountLabel: selectedFilter == .manualTransactions
                                ? { ConnectedAccountOptionPresenter.label(forAccountId: $0.plaidAccountId, in: plaidConnection.connections) }
                                : { _ in nil }
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    /// Only shown for Account Pending/Account All when more than one connected account has
    /// activity this week — with a single connected account there's nothing to choose between.
    private var connectedAccountSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(connectedAccountTabs) { tab in
                    FilterChip(title: tab.label, isSelected: tab.id == effectiveConnectedAccountTab?.id) {
                        selectedConnectedAccountId = tab.id
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

#Preview("Populated") {
    WeeklyBudgetView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}

#Preview("No Budget") {
    WeeklyBudgetView()
        .modelContainer({
            let container = SampleData.emptyPreviewContainer()
            let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 1000)
            container.mainContext.insert(checking)
            return container
        }())
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}

#Preview("No Accounts") {
    WeeklyBudgetView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}
