import SwiftUI
import SwiftData

struct WeeklyBudgetView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]

    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(\.modelContext) private var modelContext

    @State private var isPresentingEditLimit = false
    @State private var selectedFilter: TransactionListFilter = .allCounted

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

    /// This week's transactions matching the selected display filter — rows only, never used
    /// to compute totals.
    private var filteredTransactions: [FinanceTransaction] {
        switch selectedFilter {
        case .allCounted: return transactionsThisWeek.filter { BudgetCalculator.isCounted($0, includePending: includePending, context: .weekly) }
        case .pending: return transactionsThisWeek.filter { $0.isPending }
        case .excluded: return transactionsThisWeek.filter { $0.isExcludedFromReports }
        }
    }

    /// One entry per day that has at least one row matching the current filter. Each day's total
    /// is always computed from *all* of that day's transactions (via `BudgetCalculator`), never
    /// just the filtered rows, so the figure shown is always the true counted total regardless
    /// of which filter chip is active.
    private var dailyGroups: [(day: Date, transactions: [FinanceTransaction], total: Decimal)] {
        let calendar = Calendar.current
        let days = Set(filteredTransactions.map { calendar.startOfDay(for: $0.date) }).sorted(by: >)

        return days.map { day in
            let rows = filteredTransactions
                .filter { calendar.isDate($0.date, inSameDayAs: day) }
                .sorted { $0.date > $1.date }

            let allDayTransactions = transactionsThisWeek.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let total = BudgetCalculator.weeklySpent(allDayTransactions, in: DateInterval(start: day, end: dayEnd), includePending: includePending)

            return (day, rows, total)
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
                ForEach(TransactionListFilter.allCases) { filter in
                    FilterChip(title: filter.rawValue, isSelected: selectedFilter == filter) {
                        selectedFilter = filter
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if dailyGroups.isEmpty {
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
    WeeklyBudgetView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
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
}

#Preview("No Accounts") {
    WeeklyBudgetView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
}
