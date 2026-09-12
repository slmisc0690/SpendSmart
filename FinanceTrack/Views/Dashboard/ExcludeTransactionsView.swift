import SwiftUI
import SwiftData

/// EXCLUDE TRANSACTIONS — lets the user pick specific transactions to leave out of Weekly/Monthly
/// budget calculations, WITHOUT touching the transaction itself in any way (no field on
/// `FinanceTransaction` is ever read or written here). Shows CURRENT-MONTH local transactions only —
/// Connected Account, Manual Account, and manually-added expenses alike — day-grouped exactly like
/// `ExpenseListView`'s own Activity list (`DailyTransactionTotals.groups(for:)`, the same shared
/// day-bucketing service that screen uses), reusing `ConnectedTransactionRow`/`TransactionRow`
/// unmodified for each row. A checkmark button is added ALONGSIDE each row, never inside it.
///
/// MONTH SCOPE (Scott's explicit request): this screen used to show every transaction ever, all
/// months mixed together. It now scopes the browsable/toggleable list to
/// `DateRangeHelper.currentMonthRange()` — the SAME helper `DashboardView.monthInterval` already
/// uses — so October only ever shows October's own activity, etc. This is a DISPLAY scope change
/// ONLY: `BudgetSettings.excludedTransactionIDs` is loaded in full at `.task` time and `save()`
/// still persists the complete `draftExcludedIDs` set, so a transaction excluded in August stays
/// excluded in August's own historical totals forever — nothing about how exclusions are STORED or
/// APPLIED changes, only what is shown/toggleable in this one screen.
///
/// EARLIER-MONTH EXCLUSIONS STAY REACHABLE (required addition, not optional): scoping the main list
/// to the current month would otherwise create hidden, un-reachable state — a past exclusion the
/// user can never see or undo again. `earlierExclusions` surfaces exactly those (and only those —
/// not every past transaction, just the ones actually checked) in a collapsed-by-default
/// `SettingsCollapsibleSection` ABOVE the current month's list, so it's immediately visible on
/// opening the screen, never something to discover by scrolling.
struct ExcludeTransactionsView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(PlaidConnectionManager.self) private var plaidConnection

    @State private var draftExcludedIDs: Set<UUID> = []
    @State private var isEarlierExclusionsExpanded = false

    private var settings: BudgetSettings? { settingsList.first }

    private var currentMonthRange: DateInterval {
        DateRangeHelper.currentMonthRange()
    }

    private var currentMonthTransactions: [FinanceTransaction] {
        transactions.filter { currentMonthRange.contains($0.date) }
    }

    private var dayGroups: [DailyTransactionTotals.DayGroup] {
        DailyTransactionTotals.groups(for: currentMonthTransactions)
    }

    /// Transactions currently checked as excluded (via the live, editable `draftExcludedIDs` —
    /// same state the current month's own checkmarks read, so un-checking one here updates
    /// immediately exactly like the current-month rows do) whose date falls OUTSIDE the current
    /// month. Deliberately only these specific rows, never every past transaction — the point is
    /// to surface exactly what's hidden, not to reintroduce the full all-time list this change
    /// removes.
    private var earlierExclusions: [FinanceTransaction] {
        transactions.filter { draftExcludedIDs.contains($0.id) && !currentMonthRange.contains($0.date) }
    }

    private var earlierExclusionsDayGroups: [DailyTransactionTotals.DayGroup] {
        DailyTransactionTotals.groups(for: earlierExclusions)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // EARLIER-MONTH EXCLUSIONS — always checked and shown first (never gated behind
                    // `dayGroups.isEmpty`, since past exclusions can exist even with zero current-
                    // month transactions), collapsed by default, so it's visible immediately on
                    // opening the screen rather than requiring scroll discovery.
                    if !earlierExclusions.isEmpty {
                        SettingsCollapsibleSection(
                            title: "Excluded in Earlier Months (\(earlierExclusions.count))",
                            isExpanded: $isEarlierExclusionsExpanded
                        ) {
                            // `SettingsCollapsibleSection` already applies its own horizontal
                            // padding around `content()`, and `daySection` applies the SAME
                            // padding internally too — negated here so nested rows line up with
                            // the current-month list below, one layer of inset, not two.
                            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                                ForEach(earlierExclusionsDayGroups) { group in
                                    daySection(group)
                                }
                            }
                            .padding(.horizontal, -Theme.Spacing.lg)
                            .padding(.top, Theme.Spacing.sm)
                        }
                    }

                    if dayGroups.isEmpty {
                        Text("No transactions this month.")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, Theme.Spacing.xl)
                            .frame(maxWidth: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            ForEach(dayGroups) { group in
                                daySection(group)
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Exclude Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
                // Bottom toolbar (matching Photos/Mail's "Deselect All"-style placement) rather
                // than crowding the leading/trailing nav-bar slots Cancel/Save already occupy —
                // only ever touches `draftExcludedIDs`, never `BudgetSettings`, so Cancel still
                // discards it and Save still persists whatever the draft holds at that moment.
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear") { draftExcludedIDs.removeAll() }
                        .disabled(draftExcludedIDs.isEmpty)
                }
            }
            .task {
                draftExcludedIDs = Set(settings?.excludedTransactionIDs ?? [])
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func daySection(_ group: DailyTransactionTotals.DayGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Spacing.lg)

            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(group.transactions.enumerated()), id: \.element.id) { index, transaction in
                        selectableRow(for: transaction)
                        if index < group.transactions.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// The exact existing row UI (`ConnectedTransactionRow`/`TransactionRow`, matching
    /// `ExpenseListView.transactionRow(for:)`'s own source-based choice), with a checkmark button
    /// added beside it — the row content itself is never modified.
    @ViewBuilder
    private func selectableRow(for transaction: FinanceTransaction) -> some View {
        Button {
            toggleExclusion(for: transaction)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: draftExcludedIDs.contains(transaction.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(draftExcludedIDs.contains(transaction.id) ? Theme.accent : Theme.textTertiary)

                if transaction.source == .plaid {
                    ConnectedTransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled)
                } else {
                    TransactionRow(
                        transaction: transaction,
                        isPrivacyModeEnabled: privacyMode.isEnabled,
                        showsTypeBadge: true,
                        connectedAccountLabel: ConnectedAccountOptionPresenter.label(forAccountId: transaction.plaidAccountId, in: plaidConnection.connections)
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleExclusion(for transaction: FinanceTransaction) {
        if draftExcludedIDs.contains(transaction.id) {
            draftExcludedIDs.remove(transaction.id)
        } else {
            draftExcludedIDs.insert(transaction.id)
        }
    }

    private func save() {
        let updatedArray = Array(draftExcludedIDs)
        if let settings {
            settings.excludedTransactionIDs = updatedArray
            settings.updatedAt = .now
        } else {
            let created = BudgetSettings(excludedTransactionIDs: updatedArray)
            modelContext.insert(created)
        }
        dismiss()
    }
}

#Preview {
    ExcludeTransactionsView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
}
