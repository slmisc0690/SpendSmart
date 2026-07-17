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

/// Transaction history — manual transactions and, separately, each connected Plaid account's
/// activity, selected via a source tab (see `ActivityTabPresenter`). Grouped by day within
/// whichever tab is selected, filterable to a date range. This is a history screen, not where
/// accounts or categories are managed.
struct ExpenseListView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(PlaidConnectionManager.self) private var plaidConnection
    @Environment(\.modelContext) private var modelContext

    @State private var isPresentingAdd = false
    @State private var selectedDateFilter: ActivityDateFilter = .thisMonth
    @State private var customRangeStart: Date = .now
    @State private var customRangeEnd: Date = .now
    @State private var transactionPendingDeletion: FinanceTransaction?
    @State private var isPresentingDeletionError = false
    /// nil means "no explicit in-screen choice yet" — `effectiveTab` falls back to whatever was
    /// passed in via `init(initialTab:)`, then to `ActivityTabPresenter.defaultTab`.
    @State private var selectedTab: ActivityTab?
    private let initialTab: ActivityTab?

    /// `initialTab` lets a caller (the Dashboard's "More" action) open this screen with a
    /// specific source already selected — never required, so every other existing call site
    /// (the app's own Activity tab) keeps working unchanged with the deterministic default.
    init(initialTab: ActivityTab? = nil) {
        self.initialTab = initialTab
    }

    private var settings: BudgetSettings? { settingsList.first }

    private var tabs: [ActivityTab] {
        ActivityTabPresenter.tabs(transactions: transactions, connections: plaidConnection.connections)
    }

    private var effectiveTab: ActivityTab {
        if let selectedTab, tabs.contains(selectedTab) { return selectedTab }
        if let initialTab, tabs.contains(initialTab) { return initialTab }
        return ActivityTabPresenter.defaultTab(tabs: tabs)
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

    /// Scoped to the selected tab FIRST (never mixing connected and manual activity in the same
    /// list), then to the existing date-range filter — both preserved together, neither replacing
    /// the other.
    private var filteredTransactions: [FinanceTransaction] {
        ActivityTabPresenter.transactions(for: effectiveTab, in: transactions)
            .filter { selectedInterval.contains($0.date) }
    }

    /// One entry per day with at least one transaction in range, newest first.
    ///
    /// For the Manual Transactions tab, each day's total is net *monthly-eligible* spending
    /// (via `BudgetCalculator`, unchanged from before) — a Manual Transaction's total has always
    /// meant "what counts," not merely "what's shown."
    ///
    /// For a connected-account tab, `BudgetCalculator` would always report $0.00 here: every
    /// imported row has `countsTowardMonthlySpending == false` by design (see
    /// `PlaidTransactionImportService`), so a budget-eligibility total can never reflect visible
    /// imported activity. `DailyTransactionTotals` sums exactly the displayed rows instead, so
    /// the heading always agrees with what's listed underneath it.
    private var dailyGroups: [(day: Date, transactions: [FinanceTransaction], total: Decimal)] {
        switch effectiveTab {
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

    /// The safe "Paid With" label for a general Manual Transaction's optional connected-account
    /// attribution — `nil` for a Plaid-imported row, a Manual Account transaction, or a legacy
    /// Manual Transaction with no attribution.
    private func connectedAccountLabel(for transaction: FinanceTransaction) -> String? {
        ConnectedAccountOptionPresenter.label(forAccountId: transaction.plaidAccountId, in: plaidConnection.connections)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if tabs.count > 1 {
                        sourceTabSection
                    }
                    filterSection

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
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Activity")
            .toolbar {
                // Only Manual Transactions can be added from here — a connected-account tab is a
                // read-only reference list (see `ConnectedTransactionRow`'s own doc comment), so
                // adding a new entry from it would have nowhere correct to go.
                if effectiveTab == .manual {
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
    }

    // MARK: - Source tabs (Manual Transactions vs. each connected account)

    private var sourceTabSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(tabs) { tab in
                    FilterChip(title: tab.label, isSelected: tab == effectiveTab) {
                        selectedTab = tab
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

    // MARK: - Day section

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

#Preview {
    ExpenseListView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}

#Preview("Empty") {
    ExpenseListView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}
