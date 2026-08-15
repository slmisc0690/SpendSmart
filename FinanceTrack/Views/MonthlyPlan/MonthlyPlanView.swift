import SwiftUI
import SwiftData

/// The actual normal-navigation boundary for Monthly Plan (presented from Settings ▸ Monthly
/// Plan — see `SettingsView`'s own sheet). Decides ONCE, before presenting anything, whether this
/// signed-in user should see their own owned `MonthlyPlanView` or — for an active Secondary whose
/// household Primary currently has Monthly Plan shared — the Primary's real plan directly via the
/// existing read-only `SharedMonthlyPlanView`. No extra "Shared" card, no second tap, no nested
/// sheet: whichever one applies IS what "Monthly Plan" shows.
///
/// LOADING, NOT FLICKER: `AccountRelatedOptionsViewModel.state` starts `.idle`/`.loading` until
/// its one launch-time `refresh()` (see `RootView.task`) resolves. Rather than defaulting to
/// User B's own (possibly empty) owned plan and silently swapping to the Primary's plan a moment
/// later — which would both flicker AND transiently render Primary data through the wrong branch
/// — this shows a plain loading state until role/sharing is actually known, exactly once per
/// resolution. In practice `refresh()` has already completed by the time a user has navigated
/// Settings ▸ Planning ▸ Monthly Plan, so this is not a perceptible change for a Primary or a
/// no-household user; it only matters for the narrow window it exists to close.
///
/// FUTURE "ALLOW EDITS" COMPATIBILITY: this is deliberately the ONLY place that chooses between
/// the two screens. A future edit-permission phase adds controls to `SharedMonthlyPlanView`
/// itself (gated on `monthly_plan_allow_edits`) — it does not need a third screen or a different
/// decision point here.
struct MonthlyPlanEntryView: View {
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch accountRelatedOptionsViewModel.state {
        case .idle, .loading:
            loadingView
        case .loaded(let response):
            if response.role == .secondary, response.primaryMonthlyPlanShared, let primaryUserId = response.primaryUserId {
                // Never fabricated — the exact server-discovered id, exactly like the prior
                // Settings-only "Shared with You" entry point used. PHASE B — also threads
                // through the exact same server-authorized shared account lists this response
                // already carries, so SharedMonthlyPlanView's Option A outlook never has to
                // discover/evaluate sharing itself.
                SharedMonthlyPlanView(
                    primaryUserId: primaryUserId,
                    connectedAccounts: response.primarySharedConnectedAccounts,
                    manualAccounts: response.primarySharedManualAccounts
                )
            } else {
                // Primary, a no-household user, or a Secondary whose Primary hasn't (or no
                // longer) shares Monthly Plan — all fall through to the normal owned screen.
                // Never shows the Primary's plan unless BOTH conditions above are true.
                MonthlyPlanView()
            }
        case .failed:
            // Safe default: never blocks a Primary/no-household user from their own plan just
            // because the sharing-discovery call failed, and never risks showing (or attempting
            // to show) Primary data off a failed/unknown discovery result either.
            MonthlyPlanView()
        }
    }

    private var loadingView: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundGradient.ignoresSafeArea()
                ProgressView()
                    .tint(Theme.accent)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Full Monthly Plan screen: hero summary, income, fixed bills, savings goal, recommended
/// weekly spending, and a week-by-week comparison against actual spending. Always User B's own
/// owned, SwiftData-backed plan — an active Secondary with a currently-shared Primary plan never
/// reaches this type at all; see `MonthlyPlanEntryView` below, the actual normal-navigation
/// boundary (Settings ▸ Monthly Plan), which decides between this view and `SharedMonthlyPlanView`
/// before either one is presented.
struct MonthlyPlanView: View {
    @Query(sort: \IncomeSource.createdAt) private var allIncomeSources: [IncomeSource]
    @Query(sort: \RecurringExpense.createdAt) private var allRecurringExpenses: [RecurringExpense]
    @Query private var planSettingsList: [MonthlyPlanSettings]
    @Query private var budgetSettingsList: [BudgetSettings]
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query(sort: \SavingsEntry.date, order: .reverse) private var allSavingsEntries: [SavingsEntry]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PrivacyModeManager.self) private var privacyMode
    /// CLIENT UI PHASE — read-only here, purely to gate the Savings Goal / Saved This Month
    /// sections away from a Secondary who has fallen through to their own owned `MonthlyPlanView`
    /// (see this view's own `isSecondary`). Never mutated from this view.
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel
    /// CLIENT UI PHASE — existing app-lifecycle mechanism (matches `FinanceTrackApp`'s own
    /// `scenePhase`-driven foreground-return reconciliation) used to keep the server's Monthly
    /// Savings aggregate current across a calendar-month rollover without any polling/timer. See
    /// `syncSavingsSummaryIfNeeded()`.
    @Environment(\.scenePhase) private var scenePhase

    @State private var isPresentingAddIncome = false
    @State private var incomeSourcePendingEdit: IncomeSource?
    @State private var incomeSourcePendingArchive: IncomeSource?
    @State private var isPresentingAddExpense = false
    @State private var expensePendingEdit: RecurringExpense?
    @State private var expensePendingArchive: RecurringExpense?
    @State private var isPresentingSavingsGoalEdit = false
    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 5/8/10) — presentation-only trigger for the
    /// Planned Weekly Spending edit sheet.
    @State private var isPresentingPlannedWeeklySpendingEdit = false
    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 10) — which planning row's info explanation
    /// is currently showing, if any.
    @State private var planningInfoTopic: PlanningInfoTopic?
    /// FIXED BILLS TIMING FILTER — presentation-only, view-local state (per this feature's own
    /// spec: no cloud sync, no SwiftData field, defaults back to "All" whenever this view is
    /// recreated). `nil` means "All"; a non-nil value narrows `fixedBillsSection`'s list to bills
    /// whose existing, unrenamed `PlanTiming` matches. Never read by `summary`/
    /// `MonthlyPlanCalculator` — those always use `allRecurringExpenses`, unfiltered.
    @State private var fixedBillsTimingFilter: PlanTiming?
    /// MONTHLY PLAN SCENARIO MODE — presentation-only trigger for the Scenario sheet. The sheet
    /// itself owns all scenario state (`MonthlyPlanScenarioViewModel`, recreated fresh each time
    /// it's presented); this view holds nothing scenario-related beyond whether the sheet is up.
    @State private var isPresentingScenario = false
    /// SAVED THIS MONTH — presentation-only trigger for the Add Savings sheet.
    @State private var isPresentingAddSavings = false

    private var activeIncomeSources: [IncomeSource] {
        allIncomeSources.filter { $0.isActive }
    }

    private var activeRecurringExpenses: [RecurringExpense] {
        allRecurringExpenses.filter { $0.isActive }
    }

    /// Presentation filtering ONLY — narrows what `fixedBillsSection` renders, never what
    /// `summary`/`MonthlyPlanCalculator` computes (those always read `allRecurringExpenses`
    /// directly, above). `filter` preserves `activeRecurringExpenses`' existing order (itself
    /// sorted by `\RecurringExpense.createdAt` via the `@Query` above), so filtering never
    /// reorders bills within the result.
    private var filteredRecurringExpenses: [RecurringExpense] {
        FixedBillsTimingFilter.apply(activeRecurringExpenses, timing: fixedBillsTimingFilter)
    }

    /// FIXED-BILLS TOTAL CORRECTION PHASE — the total for the CURRENTLY selected Fixed Bills
    /// filter, computed from `filteredRecurringExpenses` — the exact same collection rendered as
    /// rows below — via `FixedBillsTimingFilter.displayedTotal(for:)`, the single shared row/total
    /// helper (see that function's own header for why it deliberately sums the raw displayed
    /// amount rather than a frequency-converted/date-filtered one). The displayed total and the
    /// displayed list can now never disagree, and it updates immediately whenever the filter, or
    /// the underlying `@Query`-driven bill list, changes.
    private var filteredRecurringExpensesTotal: Decimal {
        FixedBillsTimingFilter.displayedTotal(for: filteredRecurringExpenses)
    }

    /// "All Fixed Bills" / "Mid-Month Fixed Bills" / etc. — Part 1's required clear label.
    private var filteredRecurringExpensesTotalLabel: String {
        "\(fixedBillsTimingFilter?.label ?? "All") Fixed Bills"
    }

    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE — Part 2: the `PlanTiming` filter chips that
    /// actually have at least one active real Fixed Bill right now, in `PlanTiming.allCases`
    /// order — "All" is handled separately (always shown) by `fixedBillsTimingFilterRow` itself.
    /// Mirrors `MonthlyPlanScenarioViewModel.availableFixedBillTimingFilters` exactly, including
    /// always including `.customDate` (the entry point for adding a first dated bill, so hiding it
    /// whenever empty would make it unreachable).
    private var availableFixedBillsTimingFilters: [PlanTiming] {
        let presentTimings = Set(activeRecurringExpenses.map(\.timing))
        return PlanTiming.allCases.filter { $0 == .customDate || presentTimings.contains($0) }
    }

    private var planSettings: MonthlyPlanSettings? { planSettingsList.first }
    private var budgetSettings: BudgetSettings? { budgetSettingsList.first }

    /// LOCKED PRODUCT RULE — a Secondary must never see savings-planning/savings-entry controls,
    /// unconditionally (not only when this Primary's plan happens to be reached via the
    /// Secondary's own no-shared-plan fallback branch in `MonthlyPlanEntryView` — see that type's
    /// own header). Derived exclusively from the server response, matching every other role check
    /// in this codebase.
    private var isSecondary: Bool {
        accountRelatedOptionsViewModel.response?.role == .secondary
    }

    private var monthInterval: DateInterval { DateRangeHelper.currentMonthRange() }

    /// This month's savings entries only, newest first (the `@Query` above is already sorted by
    /// date descending) — the list `savedThisMonthSection` displays.
    private var currentMonthSavingsEntries: [SavingsEntry] {
        allSavingsEntries.filter { monthInterval.contains($0.date) }
    }

    private var savedThisMonth: Decimal {
        SavingsCalculator.savedThisMonth(allSavingsEntries, in: monthInterval)
    }
    private var weekStartsOnSunday: Bool { budgetSettings?.weekStartsOnSunday ?? true }
    // MONTH-ALIGNED FOUR-WEEK CORRECTION — matches `DashboardView`/`WeeklyBudgetView`'s own
    // identically-corrected `weekInterval` exactly. See `DateRangeHelper.fourWeekBlocks(in:)`.
    private var weekInterval: DateInterval { DateRangeHelper.currentFourWeekBlock() }
    private var includePending: Bool { budgetSettings?.includePendingTransactions ?? true }
    private var warningThreshold: Double { budgetSettings?.warningThreshold ?? 0.70 }
    /// AUTO-TRACKED CONNECTED-ACCOUNT BUDGETING — see `DashboardView.autoTrackedAccountIds`'s own
    /// header for why this is a plain read-only computed property, not a `@State` snapshot.
    private var autoTrackedAccountIds: Set<String> { Set(budgetSettings?.autoCalculateConnectedAccountIds ?? []) }
    /// EXCLUDE TRANSACTIONS — see `DashboardView.excludedTransactionIDs`'s own header for the
    /// master-toggle gating this respects.
    private var excludedTransactionIDs: Set<UUID> {
        guard budgetSettings?.excludeTransactionsEnabled ?? false else { return [] }
        return Set(budgetSettings?.excludedTransactionIDs ?? [])
    }

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
            warningThreshold: warningThreshold,
            autoTrackedAccountIds: autoTrackedAccountIds,
            excludedTransactionIDs: excludedTransactionIDs
        )
    }

    // MARK: - FIXED BILLS $40 DISCREPANCY FIX — corrected Fixed Bills / Flexible Spending figures
    //
    // The single remaining consumer of `MonthlyPlanCalculator.estimatedMonthlyFixedExpenses`'s
    // frequency-converting formula for on-screen Monthly Plan display purposes was the Hero Card
    // (and everything downstream of `summary.flexibleSpendingAvailable`, which is itself derived
    // from that same figure). `FixedBillsTimingFilter.displayedTotal(for:)` — the raw-sum authority
    // already used by the Fixed Bills list screen and the Scenario Bill Groups — is the single
    // source of truth every Fixed Bills total in this view must now route through, so the Hero
    // Card's "Fixed Bills" row always agrees with the Fixed Bills list's own "All Fixed Bills"
    // total. Deliberately built from `activeRecurringExpenses` (unfiltered by the presentation-only
    // Fixed Bills Timing Filter), matching `summary`'s own scope.
    private var correctedFixedBillsTotal: Decimal {
        FixedBillsTimingFilter.displayedTotal(for: activeRecurringExpenses)
    }

    /// Same shape as `MonthlyPlanCalculator.Summary.flexibleSpendingAvailable`
    /// (income − fixed bills − savings goal − buffer), but built from `correctedFixedBillsTotal`
    /// instead of the legacy frequency-converted figure.
    private var correctedFlexibleSpendingAvailable: Decimal {
        summary.estimatedMonthlyIncome - correctedFixedBillsTotal - summary.monthlySavingsGoal - summary.bufferAmount
    }

    // MARK: - MONTHLY PLAN + SCENARIO CORRECTIONS PHASE — Planned Weekly Spending planning path
    //
    // ONE AUTHORITATIVE FORMULA PATH (Part 13): every value below routes through
    // `MonthlyPlanCalculator`'s planning functions applied to `summary` (itself unchanged) — never
    // a second, competing calculation. `summary.projectedMonthlySavings` (the existing
    // actual-spending-based formula) is untouched and still drives `MonthlyPlanHeroCard`/Dashboard/
    // sync — this planning section shows a DIFFERENT, forward-looking metric.

    private var plannedWeeklySpendingOverride: Decimal? { planSettings?.plannedWeeklySpendingOverride }

    /// PLANNED WEEKLY AUTOMATIC/ZERO CORRECTION — whether a REAL Custom override is currently in
    /// effect, matching `MonthlyPlanCalculator.effectivePlannedWeeklySpending`'s own `override > 0`
    /// condition exactly (never a bare `!= nil` check, which would treat a stale non-positive
    /// override as Custom).
    private var isPlannedWeeklySpendingCustom: Bool {
        (plannedWeeklySpendingOverride ?? 0) > 0
    }

    private var plannedWeeklySpending: Decimal {
        MonthlyPlanCalculator.effectivePlannedWeeklySpending(override: plannedWeeklySpendingOverride, flexibleSpendingAvailable: correctedFlexibleSpendingAvailable)
    }

    private var plannedMonthlySpending: Decimal {
        MonthlyPlanCalculator.plannedMonthlySpending(plannedWeeklySpending: plannedWeeklySpending)
    }

    private var additionalPlannedSavings: Decimal {
        MonthlyPlanCalculator.additionalPlannedSavings(flexibleSpendingAvailable: correctedFlexibleSpendingAvailable, plannedMonthlySpending: plannedMonthlySpending)
    }

    private var projectedMonthlySavingsFromPlan: Decimal {
        MonthlyPlanCalculator.projectedMonthlySavingsFromPlan(monthlySavingsGoal: summary.monthlySavingsGoal, additionalPlannedSavings: additionalPlannedSavings)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header

                    MonthlyPlanHeroCard(
                        summary: summary,
                        correctedFixedBillsTotal: correctedFixedBillsTotal,
                        correctedFlexibleSpendingAvailable: correctedFlexibleSpendingAvailable,
                        plannedWeeklySpending: plannedWeeklySpending,
                        isPlannedWeeklySpendingCustom: isPlannedWeeklySpendingCustom,
                        projectedAvailableAfterSpend: additionalPlannedSavings,
                        projectedMonthlySavingsFromPlan: projectedMonthlySavingsFromPlan,
                        isPrivacyModeEnabled: privacyMode.isEnabled
                    )
                        .padding(.horizontal, Theme.Spacing.lg)

                    incomeSection
                    fixedBillsSection
                    billPaymentVarianceSection
                    if !isSecondary {
                        savingsGoalSection
                        planningSection
                        savedThisMonthSection
                    }
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
                ToolbarItem(placement: .primaryAction) {
                    Button("Scenario") { isPresentingScenario = true }
                        .foregroundStyle(Theme.accent)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $isPresentingScenario) {
                // MONTHLY PLAN SCENARIO MODE — deliberately passes allIncomeSources/
                // allRecurringExpenses (the complete, unfiltered @Query results), never
                // activeIncomeSources/filteredRecurringExpenses — Scenario must start from every
                // active item regardless of the Fixed Bills Timing Filter's current selection
                // (that filter is presentation-only and lives entirely in this view).
                MonthlyPlanScenarioView(
                    incomeSources: allIncomeSources,
                    recurringExpenses: allRecurringExpenses,
                    planSettings: planSettings,
                    weeklyBudgetLimit: budgetSettings?.weeklySpendingLimit ?? 0,
                    transactions: transactions,
                    month: monthInterval,
                    weekInterval: weekInterval,
                    weekStartsOnSunday: weekStartsOnSunday,
                    includePending: includePending,
                    warningThreshold: warningThreshold
                )
            }
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
            .sheet(isPresented: $isPresentingPlannedWeeklySpendingEdit) {
                PlannedWeeklySpendingEditView(
                    settings: planSettings,
                    automaticAmount: MonthlyPlanCalculator.automaticPlannedWeeklySpending(flexibleSpendingAvailable: correctedFlexibleSpendingAvailable)
                )
            }
            .sheet(item: $planningInfoTopic) { topic in
                PlanningInfoSheet(topic: topic)
            }
            .sheet(isPresented: $isPresentingAddSavings) {
                AddSavingsEntryView()
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
                applyBudgetAutoCalculateIfNeeded()
                await syncSavingsSummaryIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Covers the "calendar month changed while the app was backgrounded" case (Saved
                // This Month must reset to reflect the new month, Total Savings to Date does not)
                // — reuses the existing scenePhase mechanism, no timer/polling introduced.
                if newPhase == .active {
                    Task { await syncSavingsSummaryIfNeeded() }
                }
            }
            .onChange(of: plannedWeeklySpending) { _, _ in
                applyBudgetAutoCalculateIfNeeded()
            }
            .onChange(of: isPresentingSavingsGoalEdit) { wasPresented, isPresented in
                if wasPresented, !isPresented {
                    applyBudgetAutoCalculateIfNeeded()
                }
            }
            .onChange(of: planSettings?.monthlySavingsGoal) { _, _ in
                applyBudgetAutoCalculateIfNeeded()
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

            if !activeRecurringExpenses.isEmpty {
                fixedBillsTimingFilterRow
                fixedBillsTotalRow
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
            } else if filteredRecurringExpenses.isEmpty {
                // A filter is selected and no active bill matches it — distinct from the
                // true-empty state above: this never offers "Add Bill" (there ARE bills, the
                // filter is just narrower than any of them) and never implies the plan itself has
                // no Fixed Bills.
                EmptyStateCard(
                    systemIconName: "line.3.horizontal.decrease.circle",
                    message: "No \(fixedBillsTimingFilter?.label ?? "") bills."
                )
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(filteredRecurringExpenses.enumerated()), id: \.element.id) { index, expense in
                            RecurringExpenseRow(
                                expense: expense,
                                displayAmount: FixedBillsTimingFilter.displayAmount(for: expense),
                                isPrivacyModeEnabled: privacyMode.isEnabled,
                                onEdit: { expensePendingEdit = expense },
                                onArchive: { expensePendingArchive = expense }
                            )
                            if index < filteredRecurringExpenses.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Bill Payment Variance breakdown

    /// One row per bill actually paid this month (planned vs. actual) — see
    /// `MonthlyPlanCalculator.billPaymentVarianceBreakdown`'s own header. Lets you see directly,
    /// per bill, exactly which payment(s) are moving Flexible Spending Available away from its
    /// $0-variance baseline, instead of only the single combined number.
    private var billPaymentVarianceEntries: [MonthlyPlanCalculator.BillPaymentVarianceEntry] {
        MonthlyPlanCalculator.billPaymentVarianceBreakdown(
            recurringExpenses: activeRecurringExpenses,
            transactions: transactions,
            in: monthInterval
        )
    }

    @ViewBuilder
    private var billPaymentVarianceSection: some View {
        if !billPaymentVarianceEntries.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                DashboardSectionHeader(title: "Bill Payment Variance")

                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(billPaymentVarianceEntries.enumerated()), id: \.element.id) { index, entry in
                            billPaymentVarianceRow(entry)
                            if index < billPaymentVarianceEntries.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    private func billPaymentVarianceRow(_ entry: MonthlyPlanCalculator.BillPaymentVarianceEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.bill.name)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Text("Planned \(entry.planned, format: .currency(code: "USD")) · Paid \(entry.actual, format: .currency(code: "USD"))")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Text(varianceLabel(for: entry.variance))
                .font(Theme.bodyFont.weight(.semibold))
                .foregroundStyle(entry.variance == 0 ? Theme.textTertiary : (entry.variance > 0 ? Theme.statusGood : Theme.statusOver))
        }
    }

    /// `variance > 0` means you paid LESS than planned (adds back to Flexible Spending — shown
    /// with a "+"); `variance < 0` means you paid MORE (comes off it — shown with a "-"). Matches
    /// `MonthlyPlanCalculator.BillPaymentVarianceEntry.variance`'s own documented sign convention.
    private func varianceLabel(for variance: Decimal) -> String {
        guard variance != 0 else { return "Matches Plan" }
        let magnitude = abs(variance).formatted(.currency(code: "USD"))
        return variance > 0 ? "+\(magnitude)" : "-\(magnitude)"
    }

    /// "All" plus one `FilterChip` per existing `PlanTiming` case — same established
    /// display-only-filter pattern `WeeklyBudgetView`'s Daily Breakdown filters use. Only shown
    /// when there is at least one active bill to filter; the true-empty state above already
    /// covers the zero-bills case without this row.
    private var fixedBillsTimingFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                FilterChip(title: "All", isSelected: fixedBillsTimingFilter == nil) {
                    fixedBillsTimingFilter = nil
                }
                ForEach(availableFixedBillsTimingFilters) { timing in
                    FilterChip(title: timing.label, isSelected: fixedBillsTimingFilter == timing) {
                        fixedBillsTimingFilter = timing
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE — Part 1: the filter total, clearly labeled,
    /// directly above the filtered bill list.
    private var fixedBillsTotalRow: some View {
        HStack {
            Text(filteredRecurringExpensesTotalLabel)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            PrivacyAmountView(amount: filteredRecurringExpensesTotal, isPrivacyModeEnabled: privacyMode.isEnabled, font: Theme.bodyFont.weight(.semibold), color: Theme.textPrimary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
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

    // MARK: - Planning (Part 10)

    private var planningSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Planning")

            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    planningRow(title: "Average Monthly Flexible Spending", amount: correctedFlexibleSpendingAvailable) {
                        planningInfoTopic = .averageMonthlyFlexibleSpending
                    }
                    Divider().overlay(Theme.cardStroke)
                    planningRow(title: "Planned Weekly Spending", amount: plannedWeeklySpending) {
                        planningInfoTopic = .plannedWeeklySpending
                    }
                    Divider().overlay(Theme.cardStroke)
                    planningRow(title: "Planned Monthly Spending", amount: plannedMonthlySpending) {
                        planningInfoTopic = .plannedMonthlySpending
                    }
                    Divider().overlay(Theme.cardStroke)
                    planningRow(title: "Projected Available After Spend", amount: additionalPlannedSavings) {
                        planningInfoTopic = .projectedAvailableAfterSpend
                    }
                    Divider().overlay(Theme.cardStroke)
                    planningRow(title: "Monthly Savings Goal", amount: summary.monthlySavingsGoal) {
                        planningInfoTopic = .monthlySavingsGoal
                    }
                    Divider().overlay(Theme.cardStroke)
                    planningRow(title: "Projected Monthly Savings", amount: projectedMonthlySavingsFromPlan) {
                        planningInfoTopic = .projectedMonthlySavings
                    }

                    PremiumActionButton(
                        title: isPlannedWeeklySpendingCustom ? "Edit Planned Weekly Spending" : "Set Custom Weekly Amount",
                        systemIconName: "pencil"
                    ) {
                        isPresentingPlannedWeeklySpendingEdit = true
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private func planningRow(title: String, amount: Decimal, onInfo: @escaping () -> Void) -> some View {
        HStack {
            HStack(spacing: 4) {
                Text(title)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What does \(title) mean?")
            }
            Spacer()
            PrivacyAmountView(amount: amount, isPrivacyModeEnabled: privacyMode.isEnabled, font: Theme.bodyFont.weight(.semibold), color: Theme.textPrimary)
        }
    }

    // MARK: - Saved This Month

    /// WEEKLY SPENDING UNIFICATION (Part 12) — "Savings Added Manually" (renamed from "Saved This
    /// Month") represents ONLY records created through Add Savings — `savedThisMonth`/
    /// `currentMonthSavingsEntries` are both already scoped exclusively to `SavingsEntry` rows
    /// (see `SavingsCalculator.savedThisMonth`), never Monthly Savings Goal or any projected
    /// figure. The Total card (and its entry list) now only renders when at least one manual entry
    /// exists this month — previously a `Total $0.00` card always rendered, misleadingly implying
    /// the user had savings activity when they had none. The heading and Add Savings action always
    /// stay visible either way.
    private var savedThisMonthSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Savings Added Manually", actionTitle: "Add Savings") {
                isPresentingAddSavings = true
            }

            if !currentMonthSavingsEntries.isEmpty {
                CardBackground {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        labeledAmount(title: "Total", amount: savedThisMonth)

                        Divider().overlay(Theme.cardStroke)

                        VStack(spacing: Theme.Spacing.sm) {
                            ForEach(currentMonthSavingsEntries, id: \.id) { entry in
                                SavingsEntryRow(
                                    entry: entry,
                                    isPrivacyModeEnabled: privacyMode.isEnabled,
                                    onDelete: { deleteSavingsEntry(entry) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    private func deleteSavingsEntry(_ entry: SavingsEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
        let remainingEntries = (try? modelContext.fetch(FetchDescriptor<SavingsEntry>())) ?? []
        Task { await SavingsSummarySyncService.sync(entries: remainingEntries) }
    }

    /// CLIENT UI PHASE — reconciles the server's Monthly Savings aggregate whenever this Primary's
    /// own Monthly Plan data loads/returns to the foreground (see the `.task`/`scenePhase` call
    /// sites above). A no-op, best-effort background push — see `SavingsSummarySyncService`'s own
    /// header for the fail-safe/no-retry-daemon contract. Never runs for a Secondary (who has no
    /// savings summary of their own to push, and whose Savings sections are hidden above).
    private func syncSavingsSummaryIfNeeded() async {
        guard !isSecondary else { return }
        await SavingsSummarySyncService.sync(entries: allSavingsEntries)
    }

    // MARK: - Week-by-week comparison

    private var weeklyComparisonSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Week-by-Week")

            VStack(spacing: Theme.Spacing.md) {
                ForEach(Array(summary.weeklyComparisons.enumerated()), id: \.element.id) { index, comparison in
                    WeeklyPlanComparisonRow(comparison: comparison, weekNumber: index + 1, isPrivacyModeEnabled: privacyMode.isEnabled)
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

    /// REVISED PRODUCT DIRECTION — Budget Settings' `weeklySpendingLimit`/`monthlyGoal` are now
    /// ALWAYS derived from the Monthly Plan; there is no toggle, no manual override, and no other
    /// legitimate writer. The prior calculator-driven `autoUpdateWeeklyBudgetFromPlan`/
    /// "Use Recommended Weekly Limit" write path (which wrote `summary.recommendedWeeklySpendingLimit`
    /// directly into `weeklySpendingLimit`) has been removed entirely — it would otherwise conflict
    /// with this single authoritative formula. `MonthlyPlanSettings.autoUpdateWeeklyBudgetFromPlan`
    /// itself (the model field) and its toggle in `MonthlyPlanSettingsEditView` are left untouched
    /// per this task's own "report clearly" allowance — that toggle no longer has any functional
    /// effect (nothing reads it for this purpose anymore), but removing it was judged unnecessary
    /// UI churn beyond what correcting the writer conflict requires. `MonthlyPlanCalculator.
    /// applyRecommendedWeeklyLimit` itself remains defined (per "do not redesign MonthlyPlanCalculator")
    /// but is no longer called anywhere in this view.
    ///
    /// WEEKLY SPENDING UNIFICATION — `BudgetSettings.weeklySpendingLimit` must equal Effective
    /// Planned Weekly Spending (`plannedWeeklySpending`, the same override-aware value the Hero
    /// Card/Planning section/Week-by-Week all already use), never the prior actual-spending-
    /// adjusted `monthlySpendRemaining ÷ 4` — that legacy formula both ignored a custom override
    /// entirely and silently shrank the "limit" as spending came in during the month, which is why
    /// Weekly Budget could show $1,042.25 while the real Planned Weekly Spending was $650.
    /// `BudgetSettings.applyMonthlyPlanAutoCalculate(monthlyPlanSavingsGoal:monthlySpendRemaining:)`
    /// itself is left completely UNCHANGED (its locked `weeklySpendingLimit = monthlySpendRemaining
    /// / 4` formula is still exercised directly by its own tests) — passing `plannedMonthlySpending`
    /// (Effective Planned Weekly × 4) as that argument makes the existing `/ 4` recover the
    /// override-aware weekly value exactly, with no signature change and no new writer.
    /// Propagates immediately (no polling) so Dashboard/other direct `BudgetSettings` readers see
    /// the derived values right away, not only the next time Settings happens to reopen.
    private func applyBudgetAutoCalculateIfNeeded() {
        guard let budgetSettings else { return }
        let goal = summary.monthlySavingsGoal
        let expectedWeeklyLimit = plannedWeeklySpending
        guard budgetSettings.monthlyGoal != goal || budgetSettings.weeklySpendingLimit != expectedWeeklyLimit else { return }
        budgetSettings.applyMonthlyPlanAutoCalculate(monthlyPlanSavingsGoal: goal, monthlySpendRemaining: plannedMonthlySpending)
    }
}

// MARK: - Rows

/// One row in the Saved This Month list — date + amount, with a trailing Menu delete action.
/// Deliberately not tappable/editable: correcting a mistake is delete + re-add, never in-place
/// edit (see `SavingsEntry`'s own doc comment).
private struct SavingsEntryRow: View {
    let entry: SavingsEntry
    var isPrivacyModeEnabled: Bool = false
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(entry.date, format: .dateTime.month(.defaultDigits).day().year(.twoDigits))
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            PrivacyAmountView(amount: entry.amount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.bodyFont, color: Theme.textPrimary)

            Menu {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
        }
    }
}

private struct IncomeSourceRow: View {
    let source: IncomeSource
    var isPrivacyModeEnabled: Bool = false
    var onEdit: () -> Void
    var onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                        // INCOME SCHEDULING PHASE: the actual deposit schedule, never the old
                        // Mid-Month/End-of-Month PlanTiming label (see IncomeScheduleText's own
                        // header for why).
                        Text(IncomeScheduleText.scheduleSummary(for: source))
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

            // SCHEDULE UX PHASE — Part 7: an incomplete schedule (e.g. a Twice-a-Month income
            // whose second deposit day was never configured) is never silently excluded with no
            // way forward — a direct, visible action opens Add/Edit Income right where it can be
            // fixed. Excluded from timing-based cash flow until completed; never invents a date.
            if !source.hasCompleteDepositSchedule {
                Button(action: onEdit) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Complete Deposit Schedule")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Theme.statusWarning)
                }
                .buttonStyle(.plain)
                .padding(.leading, 42)
                .accessibilityLabel("Complete Deposit Schedule for \(source.name)")
            }
        }
    }
}

private struct RecurringExpenseRow: View {
    let expense: RecurringExpense
    /// FIXED-BILLS TOTAL CORRECTION PHASE — the exact same value `MonthlyPlanView.
    /// filteredRecurringExpensesTotal` sums for this row (`displayAmount(for:)`), passed in
    /// explicitly rather than re-read from `expense.amount` here, so the row and the total are
    /// structurally guaranteed to agree — not merely coincidentally equal today.
    let displayAmount: Decimal
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

                PrivacyAmountView(amount: displayAmount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.bodyFont, color: Theme.textPrimary)

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

/// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 10) — which Planning row an info sheet is
/// currently explaining.
enum PlanningInfoTopic: String, Identifiable {
    case averageMonthlyFlexibleSpending
    case plannedWeeklySpending
    case plannedMonthlySpending
    case projectedAvailableAfterSpend
    case monthlySavingsGoal
    case projectedMonthlySavings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .averageMonthlyFlexibleSpending: return "Average Monthly Flexible Spending"
        case .plannedWeeklySpending: return "Planned Weekly Spending"
        case .plannedMonthlySpending: return "Planned Monthly Spending"
        case .projectedAvailableAfterSpend: return "Projected Available After Spend"
        case .monthlySavingsGoal: return "Monthly Savings Goal"
        case .projectedMonthlySavings: return "Projected Monthly Savings"
        }
    }

    var explanation: String {
        switch self {
        case .averageMonthlyFlexibleSpending: return ScenarioSummaryText.averageMonthlyFlexibleSpendingExplanation()
        case .plannedWeeklySpending: return ScenarioSummaryText.plannedWeeklySpendingExplanation()
        case .plannedMonthlySpending: return ScenarioSummaryText.plannedMonthlySpendingExplanation()
        case .projectedAvailableAfterSpend: return ScenarioSummaryText.additionalPlannedSavingsExplanation()
        case .monthlySavingsGoal: return "The amount you're aiming to set aside this month. You can set this to $0.00 if you don't want a savings target right now."
        case .projectedMonthlySavings: return ScenarioSummaryText.projectedMonthlySavingsExplanation()
        }
    }
}

/// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 10) — a minimal, dismissable explanation
/// sheet for one Planning row, matching this app's established "plain-language info sheet"
/// pattern (see `MonthlyPlanScenarioView`'s own results info sheets).
struct PlanningInfoSheet: View {
    let topic: PlanningInfoTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(topic.explanation)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(topic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
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

#Preview("Entry — Primary") {
    MonthlyPlanEntryView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(AccountRelatedOptionsViewModel())
}
