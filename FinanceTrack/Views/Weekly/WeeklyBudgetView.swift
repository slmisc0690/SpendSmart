import SwiftUI
import SwiftData

struct WeeklyBudgetView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]

    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaidConnectionManager.self) private var plaidConnection

    @State private var isPresentingEditLimit = false
    @State private var selectedFilter: WeeklyBreakdownFilter = .manualTransactions
    /// nil means "no explicit choice yet" — falls back to the first available connected account,
    /// same pattern `ExpenseListView`/`DashboardView` use for their own tab selection.
    @State private var selectedConnectedAccountId: String?

    private var settings: BudgetSettings? { settingsList.first }

    private var weekInterval: DateInterval {
        DateRangeHelper.currentWeekRange(weekStartsOnSunday: settings?.weekStartsOnSunday ?? true)
    }

    private var includePending: Bool {
        settings?.includePendingTransactions ?? true
    }

    private var spentThisWeek: Decimal {
        BudgetCalculator.weeklySpent(transactions, in: weekInterval, includePending: includePending)
    }

    private var weeklyLimit: Decimal {
        settings?.weeklySpendingLimit ?? 0
    }

    private var hasWeeklyBudget: Bool { weeklyLimit > 0 }

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
                    pendingToggleSection
                    categoryBreakdownSection
                    dailyBreakdownSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $isPresentingEditLimit) {
                WeeklyLimitEditView(settings: settings)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly Budget")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Sunday through Saturday")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        if hasWeeklyBudget {
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
        } else {
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
                    Text("Set a weekly spending limit to see your progress here.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textSecondary)
                    PremiumActionButton(title: "Set Weekly Budget") {
                        isPresentingEditLimit = true
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
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
