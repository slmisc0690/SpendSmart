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

/// Transaction history: everything manually entered, grouped by day, filterable to a date range.
/// This is a history screen, not where accounts or categories are managed.
struct ExpenseListView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(\.modelContext) private var modelContext

    @State private var isPresentingAdd = false
    @State private var selectedDateFilter: ActivityDateFilter = .thisMonth
    @State private var customRangeStart: Date = .now
    @State private var customRangeEnd: Date = .now
    @State private var transactionPendingDeletion: FinanceTransaction?
    @State private var isPresentingDeletionError = false

    private var settings: BudgetSettings? { settingsList.first }

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

    private var filteredTransactions: [FinanceTransaction] {
        transactions.filter { selectedInterval.contains($0.date) }
    }

    /// One entry per day with at least one transaction in range, newest first. Each day's total
    /// is net spending for that day (via `BudgetCalculator`, never reimplemented here) — the same
    /// technique the Weekly screen's daily breakdown uses.
    private var dailyGroups: [(day: Date, transactions: [FinanceTransaction], total: Decimal)] {
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
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
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
                        HStack(spacing: 0) {
                            TransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled, showsTypeBadge: true)
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
                        if index < group.transactions.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
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
}

#Preview("Empty") {
    ExpenseListView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
}
