import SwiftUI
import SwiftData

/// Shows transactions persisted to SwiftData by `PlaidTransactionImportService.applySync` (called
/// from Connected Accounts' Manual Refresh / initial sync-after-connect) — a simple, read-only
/// reference list for comparing against manually entered transactions, using the same minimal
/// `ConnectedTransactionRow` presentation (description, date, amount) shown on the Dashboard and
/// Activity screen's connected tabs. This view does NOT call `syncTransactions()` itself: Plaid's
/// `/transactions/sync` is a stateful, cursor-advancing endpoint, and having two independent call
/// sites (this view and Manual Refresh) both hit it was exactly the bug that lost transactions —
/// Manual Refresh would consume and discard the diff, and this view's own subsequent call would
/// then correctly get nothing back. Reading from the `@Query` below instead means this view has
/// nothing to fetch — it just reflects whatever's already been persisted, and updates
/// automatically (SwiftData's `@Query` re-runs whenever the model context saves).
struct ImportedTransactionsReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var allTransactions: [FinanceTransaction]

    /// PERFORMANCE FIX (2026-09-16) — this used to be a plain computed property, so SwiftUI ran
    /// its full O(imported × manual) matching pass — referenced from TWO places in this view's
    /// body (`content` and `possibleMatchesSection`) — on EVERY render, not just when the
    /// underlying transactions actually changed. With a few hundred imported transactions across
    /// several Connected accounts, that's tens of thousands of match-score calls per render, all
    /// synchronous on the main thread — the multi-second freeze reported on-device opening this
    /// screen. Computed ONCE here via `.task(id:)`, only when the transaction set actually
    /// changes, and yielded periodically (`Task.yield()`) so the main thread stays responsive to
    /// touch/animation input throughout instead of one long unbroken blocking stretch. Stays
    /// `@MainActor`-only (never `Task.detached`) — SwiftData's `FinanceTransaction` model objects
    /// are not safe to read from a background actor.
    @State private var possibleMatches: [(imported: FinanceTransaction, best: TransactionMatcher.MatchCandidate)] = []

    // Deliberately NOT filtered by `isExcludedFromReports` — every Plaid-sourced transaction has
    // that flag set true by design (see PlaidTransactionImportService), so filtering on it would
    // hide everything this screen exists to show.
    private var importedTransactions: [FinanceTransaction] {
        allTransactions.filter { $0.source == .plaid }
    }

    private var manualTransactions: [FinanceTransaction] {
        allTransactions.filter { $0.source == .manual }
    }

    /// See `possibleMatches`' own header — the actual matching work, run once per transaction-set
    /// change rather than on every render.
    private func recomputePossibleMatches() async {
        let imported = importedTransactions
        let manual = manualTransactions
        var matches: [(imported: FinanceTransaction, best: TransactionMatcher.MatchCandidate)] = []
        for (index, transaction) in imported.enumerated() {
            guard let best = TransactionMatcher.findPossibleMatches(for: transaction, in: manual).first else { continue }
            matches.append((transaction, best))
            if index % 25 == 0 { await Task.yield() }
        }
        possibleMatches = matches
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
            .task(id: allTransactions.count) { await recomputePossibleMatches() }
        }
        .preferredColorScheme(.dark)
    }

    private func logPersistedCount() {
        #if DEBUG
        print("[ImportedTransactionsReviewView] persisted count: \(importedTransactions.count)")
        #endif
    }

    private var header: some View {
        Text("Imported transactions are read-only and never counted in your weekly or monthly totals — this is a simple reference list for comparing against what you've manually entered.")
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
                        ConnectedTransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled)
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
}

#Preview("Empty") {
    ImportedTransactionsReviewView()
        .environment(PrivacyModeManager())
        .modelContainer(SampleData.previewContainer)
}
