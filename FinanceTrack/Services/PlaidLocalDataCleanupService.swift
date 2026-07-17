import Foundation
import SwiftData

/// Local-only cleanup for Plaid-imported data, so it doesn't outlive the connection (or account)
/// it came from — Plaid's data-retention expectations aren't only about what SpendSmart's own
/// backend retains; data already synced onto this device via Plaid shouldn't linger indefinitely
/// after the user disconnects an institution or deletes their account either.
///
/// Deliberately separate from `ManualTransactionDeletionService`: that service exists to protect
/// a SINGLE Plaid-imported transaction from accidental user deletion (see its own
/// `Eligibility.blockedPlaidImport` case) — this service does the opposite, a deliberate BULK
/// removal of Plaid-imported data, scoped to exactly the connection (or account) being removed.
/// The two are not in tension: a user can never delete one imported transaction by hand, but
/// disconnecting the institution it came from — or deleting their account entirely — correctly
/// removes it along with everything else that connection/account brought in.
enum PlaidLocalDataCleanupService {
    /// Deletes every local `FinanceTransaction` with `source == .plaid` whose `plaidAccountId`
    /// is in `accountIds` — i.e. every imported transaction that came from the institution being
    /// disconnected, and only that institution. No balance reversal is performed: Plaid-imported
    /// transactions always default to `isExcludedFromReports = true` /
    /// `countsTowardWeeklyBudget = false` (see `PlaidTransactionImportService
    /// .mapToFinanceTransaction`) and are never linked to a local `Account` (`account` is always
    /// `nil` for them), so none of them can have ever affected any account balance in the first
    /// place — nothing to undo.
    ///
    /// Returns the number of rows deleted. An empty `accountIds` set deletes nothing (not "every
    /// Plaid transaction") — callers must resolve the connection's actual account IDs first;
    /// this function never guesses or falls back to a broader scope on its own.
    @discardableResult
    static func deletePlaidTransactions(matchingAccountIds accountIds: Set<String>, context: ModelContext) -> Int {
        guard !accountIds.isEmpty else { return 0 }

        // Fetch-then-filter in plain Swift, not an enum equality inside #Predicate — matching
        // PlaidTransactionImportService.applySync's own established pattern for the exact same
        // `source == .plaid` check, rather than introducing a new, untested #Predicate shape.
        guard let allTransactions = try? context.fetch(FetchDescriptor<FinanceTransaction>()) else { return 0 }
        let candidates = allTransactions.filter { transaction in
            transaction.source == .plaid && transaction.plaidAccountId.map(accountIds.contains) == true
        }

        for transaction in candidates {
            context.delete(transaction)
        }

        if !candidates.isEmpty {
            try? context.save()
        }
        return candidates.count
    }

    /// Deletes every SwiftData record this app stores, across all seven models — used only for
    /// full account deletion (never for disconnecting a single institution), after the server
    /// side of that deletion has already succeeded. Unlike `SettingsView.resetAllData()` (which
    /// deliberately reseeds default `BudgetSettings`/`Category` rows for a user continuing to use
    /// the app), this never reinserts anything — the account is gone, there is no "continuing to
    /// use the app" state to prepare for.
    static func deleteAllLocalData(context: ModelContext) {
        try? context.delete(model: FinanceTransaction.self)
        try? context.delete(model: Account.self)
        try? context.delete(model: Category.self)
        try? context.delete(model: BudgetSettings.self)
        try? context.delete(model: IncomeSource.self)
        try? context.delete(model: RecurringExpense.self)
        try? context.delete(model: MonthlyPlanSettings.self)
        try? context.save()
    }
}
