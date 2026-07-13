import SwiftUI
import SwiftData

/// Full Monthly Plan screen: hero summary, income, fixed bills, savings goal, recommended
/// weekly spending, and a week-by-week comparison against actual spending. Opened from the
/// Dashboard's Monthly Plan card.
struct MonthlyPlanView: View {
    @Query(sort: \IncomeSource.createdAt) private var allIncomeSources: [IncomeSource]
    @Query(sort: \RecurringExpense.createdAt) private var allRecurringExpenses: [RecurringExpense]
    @Query private var planSettingsList: [MonthlyPlanSettings]
    @Query private var budgetSettingsList: [BudgetSettings]
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]

    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode

    @State private var isPresentingAddIncome = false
    @State private var incomeSourcePendingEdit: IncomeSource?
    @State private var incomeSourcePendingArchive: IncomeSource?
    @State private var isPresentingAddExpense = false
    @State private var expensePendingEdit: RecurringExpense?
    @State private var expensePendingArchive: RecurringExpense?
    @State private var isPresentingSavingsGoalEdit = false

    private var activeIncomeSources: [IncomeSource] {
        allIncomeSources.filter { $0.isActive }
    }

    private var activeRecurringExpenses: [RecurringExpense] {
        allRecurringExpenses.filter { $0.isActive }
    }

    private var planSettings: MonthlyPlanSettings? { planSettingsList.first }
    private var budgetSettings: BudgetSettings? { budgetSettingsList.first }

    private var monthInterval: DateInterval { DateRangeHelper.currentMonthRange() }
    private var weekStartsOnSunday: Bool { budgetSettings?.weekStartsOnSunday ?? true }
    private var weekInterval: DateInterval { DateRangeHelper.currentWeekRange(weekStartsOnSunday: weekStartsOnSunday) }
    private var includePending: Bool { budgetSettings?.includePendingTransactions ?? true }
    private var warningThreshold: Double { budgetSettings?.warningThreshold ?? 0.70 }

    private var summary: MonthlyPlanCalculator.Summary {
        MonthlyPlanCalculator.summary(
            month: monthInterval,
            incomeSources: allIncomeSources,
            recurringExpenses: allRecurringExpenses,
            planSettings: planSettings,
            weeklyBudgetLimit: budgetSettings?.weeklySpendingLimit ?? 0,
            transactions: transactions,
            weekInterval: weekInterval,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold
        )
    }

    private var recommendedVsCurrentDifference: Decimal {
        summary.recommendedWeeklySpendingLimit - summary.currentManualWeeklyBudget
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header

                    MonthlyPlanHeroCard(summary: summary, isPrivacyModeEnabled: privacyMode.isEnabled)
                        .padding(.horizontal, Theme.Spacing.lg)

                    incomeSection
                    fixedBillsSection
                    savingsGoalSection
                    recommendedWeeklySection
                    weeklyComparisonSection
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
            .sheet(isPresented: $isPresentingAddIncome) {
                AddEditIncomeSourceView()
            }
            .sheet(item: $incomeSourcePendingEdit) { source in
                AddEditIncomeSourceView(incomeSource: source)
            }
            .sheet(isPresented: $isPresentingAddExpense) {
                AddEditRecurringExpenseView()
            }
            .sheet(item: $expensePendingEdit) { expense in
                AddEditRecurringExpenseView(recurringExpense: expense)
            }
            .sheet(isPresented: $isPresentingSavingsGoalEdit) {
                MonthlyPlanSettingsEditView(settings: planSettings)
            }
            .confirmationDialog(
                "Archive \(incomeSourcePendingArchive?.name ?? "Income Source")?",
                isPresented: Binding(
                    get: { incomeSourcePendingArchive != nil },
                    set: { isPresented in if !isPresented { incomeSourcePendingArchive = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Archive", role: .destructive) {
                    incomeSourcePendingArchive?.isActive = false
                    incomeSourcePendingArchive?.updatedAt = .now
                    incomeSourcePendingArchive = nil
                }
                Button("Cancel", role: .cancel) { incomeSourcePendingArchive = nil }
            } message: {
                Text("This income source will no longer count toward your Monthly Plan.")
            }
            .confirmationDialog(
                "Archive \(expensePendingArchive?.name ?? "Bill")?",
                isPresented: Binding(
                    get: { expensePendingArchive != nil },
                    set: { isPresented in if !isPresented { expensePendingArchive = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Archive", role: .destructive) {
                    expensePendingArchive?.isActive = false
                    expensePendingArchive?.updatedAt = .now
                    expensePendingArchive = nil
                }
                Button("Cancel", role: .cancel) { expensePendingArchive = nil }
            } message: {
                Text("This bill will no longer count toward your Monthly Plan.")
            }
            .task {
                applyAutoUpdateIfNeeded()
            }
            .onChange(of: summary.recommendedWeeklySpendingLimit) { _, _ in
                applyAutoUpdateIfNeeded()
            }
            .onChange(of: isPresentingSavingsGoalEdit) { wasPresented, isPresented in
                if wasPresented, !isPresented {
                    applyAutoUpdateIfNeeded()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Monthly Plan")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Income, bills, and savings \u{2014} planned out")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Income

    private var incomeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Income", actionTitle: "Add") {
                isPresentingAddIncome = true
            }

            if activeIncomeSources.isEmpty {
                EmptyStateCard(
                    systemIconName: "dollarsign.circle.fill",
                    message: "Add your income sources so SpendSmart can plan your month.",
                    actionTitle: "Add Income"
                ) {
                    isPresentingAddIncome = true
                }
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(activeIncomeSources.enumerated()), id: \.element.id) { index, source in
                            IncomeSourceRow(
                                source: source,
                                isPrivacyModeEnabled: privacyMode.isEnabled,
                                onEdit: { incomeSourcePendingEdit = source },
                                onArchive: { incomeSourcePendingArchive = source }
                            )
                            if index < activeIncomeSources.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Fixed bills

    private var fixedBillsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Fixed Bills", actionTitle: "Add") {
                isPresentingAddExpense = true
            }

            if activeRecurringExpenses.isEmpty {
                EmptyStateCard(
                    systemIconName: "doc.text.fill",
                    message: "Add your recurring bills to see what's left after they're paid.",
                    actionTitle: "Add Bill"
                ) {
                    isPresentingAddExpense = true
                }
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(activeRecurringExpenses.enumerated()), id: \.element.id) { index, expense in
                            RecurringExpenseRow(
                                expense: expense,
                                isPrivacyModeEnabled: privacyMode.isEnabled,
                                onEdit: { expensePendingEdit = expense },
                                onArchive: { expensePendingArchive = expense }
                            )
                            if index < activeRecurringExpenses.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Savings goal

    private var savingsGoalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Savings Goal")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack {
                        labeledAmount(title: "Monthly Goal", amount: summary.monthlySavingsGoal)
                        Spacer()
                        if summary.bufferAmount > 0 {
                            labeledAmount(title: "Buffer", amount: summary.bufferAmount)
                        }
                    }

                    PremiumActionButton(
                        title: planSettings == nil ? "Set Savings Goal" : "Edit Savings Goal",
                        systemIconName: "pencil"
                    ) {
                        isPresentingSavingsGoalEdit = true
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Recommended weekly spending

    private var recommendedWeeklySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Recommended Weekly Spending")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack {
                        labeledAmount(title: "Recommended", amount: summary.recommendedWeeklySpendingLimit)
                        Spacer()
                        labeledAmount(title: "Current Budget", amount: summary.currentManualWeeklyBudget)
                        Spacer()
                        labeledAmount(
                            title: recommendedVsCurrentDifference >= 0 ? "More Available" : "Over Current",
                            amount: abs(recommendedVsCurrentDifference),
                            color: recommendedVsCurrentDifference >= 0 ? Theme.statusGood : Theme.statusOver
                        )
                    }

                    if planSettings?.autoUpdateWeeklyBudgetFromPlan == true {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Auto-updating your weekly budget from this plan")
                                .font(Theme.captionFont)
                        }
                        .foregroundStyle(Theme.statusGood)
                    } else {
                        PremiumActionButton(title: "Use Recommended Weekly Limit", systemIconName: "arrow.triangle.2.circlepath") {
                            applyRecommendedWeeklyLimit()
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Week-by-week comparison

    private var weeklyComparisonSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Week-by-Week")

            VStack(spacing: Theme.Spacing.md) {
                ForEach(summary.weeklyComparisons) { comparison in
                    WeeklyPlanComparisonRow(comparison: comparison, isPrivacyModeEnabled: privacyMode.isEnabled)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func labeledAmount(title: String, amount: Decimal, color: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            PrivacyAmountView(amount: amount, isPrivacyModeEnabled: privacyMode.isEnabled, font: Theme.bodyFont, color: color)
        }
    }

    // MARK: - Actions

    private func applyRecommendedWeeklyLimit() {
        guard let budgetSettings else { return }
        MonthlyPlanCalculator.applyRecommendedWeeklyLimit(summary.recommendedWeeklySpendingLimit, to: budgetSettings)
    }

    private func applyAutoUpdateIfNeeded() {
        guard let planSettings, planSettings.autoUpdateWeeklyBudgetFromPlan, let budgetSettings else { return }
        guard budgetSettings.weeklySpendingLimit != summary.recommendedWeeklySpendingLimit else { return }
        MonthlyPlanCalculator.applyRecommendedWeeklyLimit(summary.recommendedWeeklySpendingLimit, to: budgetSettings)
    }
}

// MARK: - Rows

private struct IncomeSourceRow: View {
    let source: IncomeSource
    var isPrivacyModeEnabled: Bool = false
    var onEdit: () -> Void
    var onArchive: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.statusGood)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.statusGood.opacity(0.16)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(source.frequency.label) \u{00B7} \(source.timing.label)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                PrivacyAmountView(amount: source.amount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.bodyFont, color: Theme.textPrimary)

                Menu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Button("Archive", systemImage: "archivebox", role: .destructive, action: onArchive)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RecurringExpenseRow: View {
    let expense: RecurringExpense
    var isPrivacyModeEnabled: Bool = false
    var onEdit: () -> Void
    var onArchive: () -> Void

    private var tint: Color {
        expense.category.map { Theme.categoryColor(named: $0.colorName) } ?? Theme.statusOver
    }

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: expense.category?.iconName ?? "doc.text.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.opacity(0.16)))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(expense.name)
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                        if expense.isEssential {
                            Text("Essential")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.textTertiary.opacity(0.15)))
                        }
                    }
                    Text("\(expense.frequency.label) \u{00B7} \(expense.timing.label)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                PrivacyAmountView(amount: expense.amount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.bodyFont, color: Theme.textPrimary)

                Menu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Button("Archive", systemImage: "archivebox", role: .destructive, action: onArchive)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview("Populated") {
    MonthlyPlanView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}

#Preview("Empty") {
    MonthlyPlanView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
}
