import SwiftUI
import SwiftData

/// Shows transactions persisted to SwiftData by `PlaidTransactionImportService.applySync` (called
/// from Connected Accounts' Manual Refresh / initial sync-after-connect) — read-only, clearly
/// marked as not counted toward any total yet. This view does NOT call `syncTransactions()`
/// itself: Plaid's `/transactions/sync` is a stateful, cursor-advancing endpoint, and having two
/// independent call sites (this view and Manual Refresh) both hit it was exactly the bug that lost
/// transactions — Manual Refresh would consume and discard the diff, and this view's own
/// subsequent call would then correctly get nothing back. Reading from the `@Query` below instead
/// means this view has nothing to fetch — it just reflects whatever's already been persisted, and
/// updates automatically (SwiftData's `@Query` re-runs whenever the model context saves).
/// "Add to Budget", "Match", "Ignore", and "Exclude" remain disabled placeholders until that
/// approval flow is built.
struct ImportedTransactionsReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var allTransactions: [FinanceTransaction]

    // Deliberately NOT filtered by `isExcludedFromReports` — every Plaid-sourced transaction has
    // that flag set true by design (see PlaidTransactionImportService), so filtering on it would
    // hide everything this screen exists to show.
    private var importedTransactions: [FinanceTransaction] {
        allTransactions.filter { $0.source == .plaid }
    }

    private var manualTransactions: [FinanceTransaction] {
        allTransactions.filter { $0.source == .manual }
    }

    private var possibleMatches: [(imported: FinanceTransaction, best: TransactionMatcher.MatchCandidate)] {
        importedTransactions.compactMap { imported in
            guard let best = TransactionMatcher.findPossibleMatches(for: imported, in: manualTransactions).first else { return nil }
            return (imported, best)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header
                    content
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Review Imports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .task { logPersistedCount() }
            .onChange(of: importedTransactions.count) { _, _ in logPersistedCount() }
        }
        .preferredColorScheme(.dark)
    }

    private func logPersistedCount() {
        #if DEBUG
        print("[ImportedTransactionsReviewView] persisted count: \(importedTransactions.count)")
        #endif
    }

    private var header: some View {
        Text("Imported transactions are read-only and not counted in your weekly or monthly totals until you review and approve them here.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        // Empty state fires purely off persisted SwiftData count — no "not connected"/"loading"/
        // "error" branches, since this view no longer makes a network call of its own.
        if importedTransactions.isEmpty {
            statusCard(icon: "tray", message: "No imported transactions yet. Use Manual Refresh on Connected Accounts to sync.")
        } else {
            importedSection
            if !possibleMatches.isEmpty {
                possibleMatchesSection
            }
        }
    }

    @ViewBuilder
    private func statusCard(icon: String, message: String, color: Color = Theme.textSecondary) -> some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(color)
                Text(message)
                    .font(Theme.bodyFont)
                    .foregroundStyle(color)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var importedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Imported Transactions")
            VStack(spacing: Theme.Spacing.md) {
                ForEach(importedTransactions, id: \.id) { transaction in
                    CardBackground {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            HStack(spacing: 6) {
                                TransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled)
                            }
                            notCountedBadge
                            Divider().overlay(Theme.cardStroke)
                            ImportedTransactionActionsRow()
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var possibleMatchesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Possible Matches")
            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Array(possibleMatches.enumerated()), id: \.element.imported.id) { index, match in
                        VStack(alignment: .leading, spacing: 6) {
                            TransactionRow(transaction: match.imported, isPrivacyModeEnabled: privacyMode.isEnabled)
                            Text("\(Int(match.best.score * 100))% match to \u{201C}\(match.best.transaction.displayName)\u{201D}")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if index < possibleMatches.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var notCountedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("Not counted yet")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Theme.statusWarning)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.statusWarning.opacity(0.15)))
    }
}

/// Disabled placeholder row for the four actions a future approval flow will support. Every
/// button here is inert — tapping does nothing — until that flow is built.
private struct ImportedTransactionActionsRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            actionButton(icon: "plus.circle", title: "Add")
            actionButton(icon: "link", title: "Match")
            actionButton(icon: "minus.circle", title: "Ignore")
            actionButton(icon: "eye.slash", title: "Exclude")
        }
    }

    @ViewBuilder
    private func actionButton(icon: String, title: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
        .opacity(0.6)
    }
}

#Preview("Empty") {
    ImportedTransactionsReviewView()
        .environment(PrivacyModeManager())
        .modelContainer(SampleData.previewContainer)
}
