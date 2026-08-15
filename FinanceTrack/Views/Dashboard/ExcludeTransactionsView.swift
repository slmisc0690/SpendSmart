import SwiftUI
import SwiftData

/// EXCLUDE TRANSACTIONS — lets the user pick specific transactions to leave out of Weekly/Monthly
/// budget calculations, WITHOUT touching the transaction itself in any way (no field on
/// `FinanceTransaction` is ever read or written here). Shows every local transaction — Connected
/// Account, Manual Account, and manually-added expenses alike — day-grouped exactly like
/// `ExpenseListView`'s own Activity list (`DailyTransactionTotals.groups(for:)`, the same shared
/// day-bucketing service that screen uses), reusing `ConnectedTransactionRow`/`TransactionRow`
/// unmodified for each row. A checkmark button is added ALONGSIDE each row, never inside it.
///
/// DRAFT-THEN-SAVE: selections are held in local `@State` (`draftExcludedIDs`) until "Save" is
/// tapped, so "Cancel" truly discards every change, matching the required Cancel/Save contract.
/// Persistence itself is a single write to `BudgetSettings.excludedTransactionIDs` — no per-row
/// SwiftData mutation of any kind.
struct ExcludeTransactionsView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(PlaidConnectionManager.self) private var plaidConnection

    @State private var draftExcludedIDs: Set<UUID> = []

    private var settings: BudgetSettings? { settingsList.first }

    private var dayGroups: [DailyTransactionTotals.DayGroup] {
        DailyTransactionTotals.groups(for: transactions)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if dayGroups.isEmpty {
                    Text("No transactions yet.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.Spacing.xl)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        ForEach(dayGroups) { group in
                            daySection(group)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.lg)
                }
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
