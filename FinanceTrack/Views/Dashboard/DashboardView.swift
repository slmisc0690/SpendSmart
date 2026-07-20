import SwiftUI
import SwiftData

struct DashboardView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]

    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(PlaidConnectionManager.self) private var plaidConnection

    @State private var isPresentingSetBudget = false
    @State private var isPresentingAddExpense = false
    @State private var isPresentingSettings = false
    @State private var isPresentingMonthlySummary = false
    @State private var isPresentingActivity = false
    @State private var selectedWeekIndex: Int?
    /// nil means "no explicit choice yet" — `effectiveActivityTab` below falls back to
    /// `ActivityTabPresenter.defaultTab`, same pattern as `selectedWeekIndex`/`effectiveWeekIndex`.
    @State private var selectedActivityTab: ActivityTab?
    /// Keyed by `ConnectedAccountsDashboardPresenter.Display.id` — tracks which single connected
    /// account's Refresh button is mid-request, so tapping one account's button never disables or
    /// otherwise affects any other account's button.
    @State private var refreshingAccountKeys: Set<String> = []
    /// Keyed the same way — set only after a real 429 from `refresh-connected-account` (or a
    /// mirrored `remaining == 0` from a prior successful response), never guessed client-side from
    /// a fresh calendar day. The server remains authoritative regardless: a stale-enabled button
    /// simply gets a graceful 429 on tap, handled the same way as any other failed refresh.
    @State private var rateLimitedAccountKeys: Set<String> = []

    private var settings: BudgetSettings? { settingsList.first }

    private var weekInterval: DateInterval {
        DateRangeHelper.currentWeekRange(weekStartsOnSunday: settings?.weekStartsOnSunday ?? true)
    }

    private var monthInterval: DateInterval {
        DateRangeHelper.currentMonthRange()
    }

    private var includePending: Bool {
        settings?.includePendingTransactions ?? true
    }

    private var spentThisWeek: Decimal {
        BudgetCalculator.weeklySpent(transactions, in: weekInterval, includePending: includePending)
    }

    private var spentThisMonth: Decimal {
        BudgetCalculator.monthlySpent(transactions, in: monthInterval, includePending: includePending)
    }

    private var weeklyLimit: Decimal {
        settings?.weeklySpendingLimit ?? 0
    }

    /// A budget only "exists" for dashboard purposes once a positive weekly limit has been set.
    private var hasWeeklyBudget: Bool {
        weeklyLimit > 0
    }

    private var status: SpendingStatus {
        BudgetCalculator.status(
            spent: spentThisWeek,
            limit: weeklyLimit,
            warningThreshold: settings?.warningThreshold ?? 0.70
        )
    }

    private var remainingThisWeek: Decimal {
        BudgetCalculator.remaining(limit: weeklyLimit, spent: spentThisWeek)
    }

    /// Every selectable Recent Activity source — one per connected Plaid account actually
    /// referenced by a locally stored transaction, plus Manual Transactions. See
    /// `ActivityTabPresenter` for why this reads only persisted state, never Plaid.
    private var activityTabs: [ActivityTab] {
        ActivityTabPresenter.tabs(transactions: transactions, connections: plaidConnection.connections)
    }

    /// Same fallback pattern as `effectiveWeekIndex` below: `selectedActivityTab` is nil until the
    /// user explicitly picks one, and falls back to `ActivityTabPresenter.defaultTab` — which also
    /// covers the case where a previously selected connected account was since disconnected.
    private var effectiveActivityTab: ActivityTab {
        if let selectedActivityTab, activityTabs.contains(selectedActivityTab) { return selectedActivityTab }
        return ActivityTabPresenter.defaultTab(tabs: activityTabs)
    }

    /// The single source of truth for what Recent Activity shows — scoped to `effectiveActivityTab`
    /// FIRST, then opted-out Manual Accounts are filtered out, then the 5-item limit is applied to
    /// what remains, so a hidden account's transactions never silently consume a slot an eligible
    /// transaction should have gotten. `transactions` is already date-descending (see the `@Query`
    /// sort above), so filtering preserves that order.
    private var recentTransactions: [FinanceTransaction] {
        Array(
            ActivityTabPresenter.transactions(for: effectiveActivityTab, in: transactions)
                .filter(isEligibleForRecentActivity)
                .prefix(5)
        )
    }

    /// A transaction with no account, or one belonging to a Plaid-linked account (no opt-out
    /// concept exists for those today), is always eligible — this only ever excludes a Manual
    /// Account's transactions, and only when that account's own `showsInRecentActivity` is
    /// explicitly `false`.
    private func isEligibleForRecentActivity(_ transaction: FinanceTransaction) -> Bool {
        transaction.account?.showsInRecentActivity ?? true
    }

    /// Everything needed for the Monthly Outlook and Week-by-Week sections, computed once via
    /// the shared `MonthlyPlanCalculator` — never reimplemented here. Only status-level fields
    /// (projected savings, status, recommended limit, week-by-week comparisons) are ever read
    /// from this on the Dashboard; income/bill totals and lists stay private to Settings >
    /// Monthly Plan.
    private var monthlyPlanSummary: MonthlyPlanCalculator.Summary {
        MonthlyPlanCalculator.summary(
            month: monthInterval,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: monthlyPlanSettingsList.first,
            weeklyBudgetLimit: weeklyLimit,
            transactions: transactions,
            weekInterval: weekInterval,
            weekStartsOnSunday: settings?.weekStartsOnSunday ?? true,
            includePending: includePending,
            warningThreshold: settings?.warningThreshold ?? 0.70
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header

                    PremiumActionButton(title: "Add Expense", systemIconName: "plus") {
                        isPresentingAddExpense = true
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    weeklyCardSection
                    quickStatsSection
                    connectedAccountsSection
                    monthlyOutlookSection
                    weekByWeekSection
                    recentActivitySection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $isPresentingSetBudget) {
                WeeklyLimitEditView(settings: settings)
            }
            .sheet(isPresented: $isPresentingAddExpense) {
                AddExpenseView()
            }
            .sheet(isPresented: $isPresentingSettings) {
                SettingsView(isModal: true)
            }
            .sheet(isPresented: $isPresentingMonthlySummary) {
                MonthlySummaryView()
            }
            .sheet(isPresented: $isPresentingActivity) {
                // Reuses the existing full Activity screen (ExpenseListView) rather than building
                // a second one — presented modally, matching every other Dashboard destination in
                // this file, and opened with whatever tab is currently selected here.
                ExpenseListView(initialTab: effectiveActivityTab)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(DateRangeHelper.monthDisplayText(for: monthInterval))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Text("SpendSmart")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your spending at a glance")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: Theme.Spacing.sm) {
                HeaderIconButton(systemName: privacyMode.isEnabled ? "eye.slash.fill" : "eye.fill") {
                    privacyMode.toggle()
                }
                HeaderIconButton(systemName: "gearshape.fill") {
                    isPresentingSettings = true
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Weekly hero card

    @ViewBuilder
    private var weeklyCardSection: some View {
        if hasWeeklyBudget {
            SpendingCardView(
                spent: spentThisWeek,
                limit: weeklyLimit,
                status: status,
                weekInterval: weekInterval,
                isPrivacyModeEnabled: privacyMode.isEnabled
            )
            .padding(.horizontal, Theme.Spacing.lg)
        } else {
            NoBudgetCard {
                isPresentingSetBudget = true
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Quick stats

    private var quickStatsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Quick Stats")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.sm), GridItem(.flexible())], spacing: Theme.Spacing.sm) {
                Button {
                    isPresentingMonthlySummary = true
                } label: {
                    StatCard(
                        title: "Monthly Spending",
                        systemIconName: "chart.pie.fill",
                        amount: spentThisMonth,
                        subtitle: DateRangeHelper.monthDisplayText(for: monthInterval),
                        accentColor: Theme.accent,
                        isPrivacyModeEnabled: privacyMode.isEnabled
                    )
                }
                .buttonStyle(.plain)
                StatCard(
                    title: "Available This Week",
                    systemIconName: "target",
                    amount: remainingThisWeek,
                    subtitle: hasWeeklyBudget ? "Left to spend" : "Set a weekly budget",
                    accentColor: hasWeeklyBudget ? (status == .over ? Theme.statusOver : Theme.accentSecondary) : Theme.textTertiary,
                    isPrivacyModeEnabled: privacyMode.isEnabled
                )
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Connected accounts (locally cached balances — refresh delegates to
    // PlaidConnectionManager, never calls Plaid/the backend directly from this view)

    /// See `ConnectedAccountsDashboardPresenter` for the actual mapping logic — kept out of this
    /// view entirely so it's unit-testable without SwiftUI/environment involvement.
    private var connectedAccountBalanceDisplays: [ConnectedAccountsDashboardPresenter.Display] {
        ConnectedAccountsDashboardPresenter.displays(for: plaidConnection.connections)
    }

    @ViewBuilder
    private var connectedAccountsSection: some View {
        if !connectedAccountBalanceDisplays.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                DashboardSectionHeader(title: "Connected Accounts")
                CardBackground {
                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(Array(connectedAccountBalanceDisplays.enumerated()), id: \.element.id) { index, display in
                            ConnectedAccountBalanceRow(
                                display: display,
                                isPrivacyModeEnabled: privacyMode.isEnabled,
                                isRefreshing: refreshingAccountKeys.contains(display.id),
                                isRateLimited: rateLimitedAccountKeys.contains(display.id),
                                onRefresh: { refreshConnectedAccount(display) }
                            )
                            if index < connectedAccountBalanceDisplays.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    /// Fires exactly one account's server-rate-limited manual refresh via
    /// `PlaidConnectionManager.refreshAccountBalance` — this view never names the backend service
    /// type or any Plaid sync/refresh helper directly (see
    /// `testDashboardStillNeverCallsPlaidDirectlyAfterRawBalanceRestore`); all networking happens
    /// behind that one already-injected environment object. `display.accountId` is only `nil` for
    /// the no-balance-cached-yet placeholder row, which never renders a Refresh button in the
    /// first place (see `ConnectedAccountBalanceRow`), so a nil here means the button that fired
    /// this call is stale and there is nothing to refresh — a silent no-op, not an error.
    private func refreshConnectedAccount(_ display: ConnectedAccountsDashboardPresenter.Display) {
        guard let accountId = display.accountId else { return }
        guard !refreshingAccountKeys.contains(display.id) else { return }
        refreshingAccountKeys.insert(display.id)
        Task {
            defer { refreshingAccountKeys.remove(display.id) }
            do {
                _ = try await plaidConnection.refreshAccountBalance(connectionId: display.connectionId, accountId: accountId)
                rateLimitedAccountKeys.remove(display.id)
            } catch PlaidBackendError.rateLimited {
                rateLimitedAccountKeys.insert(display.id)
            } catch {
                // Any other failure (network, environment mismatch, reauth-required, etc.) — the
                // button simply returns to its idle state so the user can try again; no raw
                // backend error is ever surfaced here per the product spec.
            }
        }
    }

    // MARK: - Monthly outlook

    private var monthlyOutlookSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Monthly Outlook")

            MonthlyOutlookCard(
                budgetedMonthlySpend: settings?.monthlyGoal,
                actualMonthlySpend: monthlyPlanSummary.actualSpentThisMonth,
                projectedSavings: monthlyPlanSummary.projectedMonthlySavings,
                status: monthlyPlanSummary.projectedStatus,
                recommendedWeeklyLimit: monthlyPlanSummary.recommendedWeeklySpendingLimit,
                isPrivacyModeEnabled: privacyMode.isEnabled
            )
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Week-by-week

    private var weeklyComparisons: [MonthlyPlanCalculator.WeeklyPlanComparison] {
        monthlyPlanSummary.weeklyComparisons
    }

    /// Defaults to whichever week contains today; falls back to the first week if today somehow
    /// isn't covered (shouldn't happen — `weeksOverlapping` always spans the full month).
    private var currentWeekComparisonIndex: Int {
        weeklyComparisons.firstIndex(where: { $0.weekInterval.contains(.now) }) ?? 0
    }

    private var effectiveWeekIndex: Int {
        guard let selectedWeekIndex, weeklyComparisons.indices.contains(selectedWeekIndex) else {
            return currentWeekComparisonIndex
        }
        return selectedWeekIndex
    }

    private func weekMenuLabel(for index: Int) -> String {
        guard weeklyComparisons.indices.contains(index) else { return "" }
        return "Week \(index + 1): \(DateRangeHelper.weekDisplayText(for: weeklyComparisons[index].weekInterval))"
    }

    private var weekByWeekSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Week-by-Week")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if weeklyComparisons.count > 1 {
                    Menu {
                        ForEach(weeklyComparisons.indices, id: \.self) { index in
                            Button(weekMenuLabel(for: index)) {
                                selectedWeekIndex = index
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Week \(effectiveWeekIndex + 1)")
                                .font(Theme.captionFont)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if weeklyComparisons.indices.contains(effectiveWeekIndex) {
                WeeklyPlanComparisonRow(comparison: weeklyComparisons[effectiveWeekIndex], isPrivacyModeEnabled: privacyMode.isEnabled)
                    .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Recent activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Recent Activity")

            // Only shown once there's more than one source to choose between — a household with
            // no connected accounts yet never sees a single-option "Manual Transactions" tab.
            if activityTabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(activityTabs) { tab in
                            FilterChip(title: tab.label, isSelected: tab == effectiveActivityTab) {
                                selectedActivityTab = tab
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }

            if recentTransactions.isEmpty {
                EmptyStateCard(
                    systemIconName: "list.bullet.rectangle.portrait.fill",
                    message: emptyActivityMessage
                )
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                CardBackground {
                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(Array(recentTransactions.enumerated()), id: \.element.id) { index, transaction in
                            RecentActivityRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled)
                            if index < recentTransactions.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }

            Button {
                isPresentingActivity = true
            } label: {
                HStack(spacing: 4) {
                    Text("More")
                        .font(Theme.captionFont)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var emptyActivityMessage: String {
        if case .manual = effectiveActivityTab { return "No expenses added yet." }
        return "No connected transactions yet."
    }
}

/// One compact line per transaction on the Dashboard: date, name, amount — deliberately lighter
/// than the full `TransactionRow` used in Activity/Weekly, since this is a glance-only summary.
private struct RecentActivityRow: View {
    let transaction: FinanceTransaction
    var isPrivacyModeEnabled: Bool = false

    private var amountColor: Color {
        switch transaction.type {
        case .expense: return Theme.textPrimary
        case .refund, .income: return Theme.statusGood
        case .transfer, .creditCardPayment, .balanceAdjustment: return Theme.textTertiary
        }
    }

    private var signPrefix: String {
        switch transaction.type {
        case .expense: return "-"
        case .refund, .income: return "+"
        case .transfer, .creditCardPayment, .balanceAdjustment: return ""
        }
    }

    /// `displayName` (merchant/note) when there is one; otherwise the category name, then the
    /// transaction type — a compact row should never show a blank name.
    private var displayText: String {
        let name = transaction.displayName
        if !name.isEmpty { return name }
        return transaction.category?.name ?? transaction.type.label
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .leading)

            Text(displayText)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.sm)

            PrivacyAmountView(
                amount: transaction.amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.bodyFont,
                color: amountColor,
                prefix: signPrefix
            )
        }
    }
}

/// One connected Plaid account's cached balance on the Dashboard — reads only what
/// `ConnectedAccountsDashboardPresenter` already computed from persisted `PlaidConnectionManager`
/// state; this view has no networking of its own.
private struct ConnectedAccountBalanceRow: View {
    let display: ConnectedAccountsDashboardPresenter.Display
    var isPrivacyModeEnabled: Bool = false
    /// `nil` only when this account has no `accountId` yet (the no-balance-cached-yet placeholder
    /// row) — there is nothing for a per-account Refresh button to target in that case, so the row
    /// simply omits the button rather than showing one that can't do anything.
    var isRefreshing: Bool = false
    var isRateLimited: Bool = false
    var onRefresh: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.accent.opacity(0.16)))

            VStack(alignment: .leading, spacing: 2) {
                Text(display.institutionName)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitleText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            if let row = display.primaryRow {
                VStack(alignment: .trailing, spacing: 4) {
                    PrivacyAmountView(
                        amount: row.amount,
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: Theme.bodyFont,
                        color: Theme.textPrimary
                    )
                    Text(row.label)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                    if let onRefresh, display.accountId != nil {
                        RefreshPillButton(isRefreshing: isRefreshing, isRateLimited: isRateLimited, action: onRefresh)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitleText: String {
        guard let updatedAt = display.updatedAt else { return "Balance not refreshed yet" }
        return "Last updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Small circular icon button used in the dashboard header (privacy toggle, settings).
private struct HeaderIconButton: View {
    let systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.cardSurface))
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Shown on the dashboard when accounts exist but no weekly spending limit has been set yet.
private struct NoBudgetCard: View {
    var onSetBudget: () -> Void

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This Week")
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text("No weekly budget set")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }

                Text("Set a weekly spending limit to see how much you have left to spend.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)

                PremiumActionButton(title: "Set Weekly Budget", action: onSetBudget)
            }
        }
    }
}

#Preview("Populated") {
    DashboardView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}

#Preview("Privacy Mode") {
    DashboardView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager(isEnabled: true))
        .environment(PlaidConnectionManager())
}

#Preview("Empty") {
    DashboardView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}
