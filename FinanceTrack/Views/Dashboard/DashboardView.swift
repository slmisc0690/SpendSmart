import SwiftUI
import SwiftData

struct DashboardView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]

    @Environment(PrivacyModeManager.self) private var privacyMode

    @State private var isPresentingSetBudget = false
    @State private var isPresentingAddExpense = false
    @State private var isPresentingSettings = false
    @State private var isPresentingMonthlySummary = false
    @State private var selectedWeekIndex: Int?

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

    private var recentTransactions: [FinanceTransaction] {
        Array(transactions.prefix(5))
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

            if recentTransactions.isEmpty {
                EmptyStateCard(
                    systemIconName: "list.bullet.rectangle.portrait.fill",
                    message: "No expenses added yet."
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
        }
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
}

#Preview("Privacy Mode") {
    DashboardView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager(isEnabled: true))
}

#Preview("Empty") {
    DashboardView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
}
