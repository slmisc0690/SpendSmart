import SwiftUI
import SwiftData

/// Full monthly summary: hero card (with optional goal), category/account breakdowns, each
/// overlapping week's contribution, and a day-grouped transaction list. Opened from the
/// Dashboard's "Monthly Spending" stat tile.
struct MonthlySummaryView: View {
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]

    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMonthAnchor: Date = .now
    @State private var isPresentingEditGoal = false
    @State private var isPresentingAddAccount = false
    @State private var selectedFilter: TransactionListFilter = .allCounted

    private var activeAccounts: [Account] {
        allAccounts.filter { !$0.isArchived }
    }

    private var settings: BudgetSettings? { settingsList.first }
    private var includePending: Bool { settings?.includePendingTransactions ?? true }
    private var weekStartsOnSunday: Bool { settings?.weekStartsOnSunday ?? true }

    private var monthInterval: DateInterval {
        DateRangeHelper.monthRangeContaining(selectedMonthAnchor)
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(selectedMonthAnchor, equalTo: .now, toGranularity: .month)
    }

    private var spentThisMonth: Decimal {
        BudgetCalculator.monthlySpent(transactions, in: monthInterval, includePending: includePending)
    }

    private var monthlyGoal: Decimal? {
        settings?.monthlyGoal
    }

    private var categoryTotals: [BudgetCalculator.CategoryTotal] {
        BudgetCalculator.categoryTotals(transactions, in: monthInterval, includePending: includePending, context: .monthly)
    }

    private var accountTotals: [BudgetCalculator.AccountTotal] {
        BudgetCalculator.accountTotals(transactions, in: monthInterval, includePending: includePending, context: .monthly)
    }

    /// Every transaction dated within the selected month, regardless of type or filter.
    private var transactionsThisMonth: [FinanceTransaction] {
        transactions.filter { monthInterval.contains($0.date) }
    }

    private var filteredTransactions: [FinanceTransaction] {
        switch selectedFilter {
        case .allCounted: return transactionsThisMonth.filter { BudgetCalculator.isCounted($0, includePending: includePending, context: .monthly) }
        case .pending: return transactionsThisMonth.filter { $0.isPending }
        case .excluded: return transactionsThisMonth.filter { $0.isExcludedFromReports }
        }
    }

    /// One entry per day (within the selected month) that has at least one row matching the
    /// current filter. Each day's total always comes from *all* of that day's transactions, so
    /// the figure shown is the true counted total regardless of which filter chip is active.
    private var dailyGroups: [(day: Date, transactions: [FinanceTransaction], total: Decimal)] {
        let calendar = Calendar.current
        let days = Set(filteredTransactions.map { calendar.startOfDay(for: $0.date) }).sorted(by: >)

        return days.map { day in
            let rows = filteredTransactions
                .filter { calendar.isDate($0.date, inSameDayAs: day) }
                .sorted { $0.date > $1.date }

            let allDayTransactions = transactionsThisMonth.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let total = BudgetCalculator.monthlySpent(allDayTransactions, in: DateInterval(start: day, end: dayEnd), includePending: includePending)

            return (day, rows, total)
        }
    }

    /// Every Sunday/Monday-start calendar week that touches the selected month, walked from the
    /// month's first day to its last.
    private var overlappingWeeks: [DateInterval] {
        DateRangeHelper.weeksOverlapping(monthInterval, weekStartsOnSunday: weekStartsOnSunday)
    }

    /// This week's slice of the *selected month's* spend — a week spanning two months only
    /// counts, here, the days that actually fall inside `monthInterval`.
    private func spentInMonth(for weekInterval: DateInterval) -> Decimal {
        guard let clipped = DateRangeHelper.clampedInterval(weekInterval, to: monthInterval) else { return 0 }
        return BudgetCalculator.monthlySpent(transactions, in: clipped, includePending: includePending)
    }

    /// The week's standing against the *weekly* budget, using its full (unclipped) range —
    /// independent of which month is selected. `nil` when no weekly limit is set.
    private func weeklyStatus(for weekInterval: DateInterval) -> SpendingStatus? {
        guard let weeklyLimit = settings?.weeklySpendingLimit, weeklyLimit > 0 else { return nil }
        let spent = BudgetCalculator.weeklySpent(transactions, in: weekInterval, includePending: includePending)
        return BudgetCalculator.status(spent: spent, limit: weeklyLimit, warningThreshold: settings?.warningThreshold ?? 0.70)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header

                    MonthSelectorView(
                        monthInterval: monthInterval,
                        isCurrentMonth: isCurrentMonth,
                        onPrevious: { shiftMonth(by: -1) },
                        onNext: { shiftMonth(by: 1) },
                        onToday: { selectedMonthAnchor = .now }
                    )

                    if activeAccounts.isEmpty {
                        EmptyStateCard(
                            systemIconName: "creditcard.fill",
                            message: "Add a manually tracked account to start tracking your monthly spending. Connected banks and credit cards are managed in Connected Accounts.",
                            actionTitle: "Add Manual Tracked Account"
                        ) {
                            isPresentingAddAccount = true
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    } else {
                        heroSection
                        pendingToggleSection
                        categoryBreakdownSection
                        accountBreakdownSection
                        weeklyTotalsSection
                        dailyBreakdownSection
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $isPresentingEditGoal) {
                MonthlyGoalEditView(settings: settings)
            }
            .sheet(isPresented: $isPresentingAddAccount) {
                AddAccountView()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func shiftMonth(by value: Int) {
        let calendar = Calendar.current
        selectedMonthAnchor = calendar.date(byAdding: .month, value: value, to: selectedMonthAnchor) ?? selectedMonthAnchor
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Monthly Summary")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Where your money went this month")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Hero

    private var heroSection: some View {
        MonthlySummaryHeroCard(
            monthInterval: monthInterval,
            spent: spentThisMonth,
            goal: monthlyGoal,
            isPrivacyModeEnabled: privacyMode.isEnabled,
            warningThreshold: settings?.warningThreshold ?? 0.70
        ) {
            isPresentingEditGoal = true
        }
        .padding(.horizontal, Theme.Spacing.lg)
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
            DashboardSectionHeader(title: "Spending by Category")

            if categoryTotals.isEmpty {
                emptyBreakdownCard(message: "No spending tracked this month yet.", systemIconName: "chart.pie.fill")
            } else {
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(categoryTotals.enumerated()), id: \.element.id) { index, categoryTotal in
                            CategoryBreakdownRow(
                                categoryTotal: categoryTotal,
                                periodTotal: spentThisMonth,
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

    // MARK: - Account breakdown

    private var accountBreakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Spending by Account")

            if accountTotals.isEmpty {
                emptyBreakdownCard(message: "No account spending tracked this month yet.", systemIconName: "creditcard.fill")
            } else {
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(accountTotals.enumerated()), id: \.element.id) { index, accountTotal in
                            AccountBreakdownRow(
                                accountTotal: accountTotal,
                                periodTotal: spentThisMonth,
                                isPrivacyModeEnabled: privacyMode.isEnabled
                            )
                            if index < accountTotals.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    @ViewBuilder
    private func emptyBreakdownCard(message: String, systemIconName: String) -> some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemIconName)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text(message)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Weekly totals within the month

    private var weeklyTotalsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Weekly Totals")

            VStack(spacing: Theme.Spacing.md) {
                ForEach(overlappingWeeks, id: \.start) { week in
                    WeeklyMonthlyTotalCard(
                        weekInterval: week,
                        spentInMonth: spentInMonth(for: week),
                        monthlyTotal: spentThisMonth,
                        weeklyStatus: weeklyStatus(for: week),
                        isPrivacyModeEnabled: privacyMode.isEnabled
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Daily breakdown

    private var dailyBreakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Transactions")

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(TransactionListFilter.allCases) { filter in
                    FilterChip(title: filter.rawValue, isSelected: selectedFilter == filter) {
                        selectedFilter = filter
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if dailyGroups.isEmpty {
                Text("No transactions this month yet")
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
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }
}

#Preview("Populated") {
    MonthlySummaryView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}

#Preview("No Goal") {
    MonthlySummaryView()
        .modelContainer({
            let container = SampleData.emptyPreviewContainer()
            let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 1000)
            container.mainContext.insert(checking)
            let settings = BudgetSettings(weeklySpendingLimit: 300, monthlyGoal: nil)
            container.mainContext.insert(settings)
            return container
        }())
        .environment(PrivacyModeManager())
}

#Preview("No Accounts") {
    MonthlySummaryView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
}
