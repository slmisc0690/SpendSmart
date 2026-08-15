import Foundation

/// SAVED VIA TRANSFER SHARING — the client-side push half of Saved-via-Transfer sharing
/// (migration 0023). No raw `FinanceTransaction` row is ever uploaded — this uploads exactly the
/// one aggregate total `SavedViaTransferCalculator` already computes from the owner's own local
/// `.transferToSavings` entries, via the verified `upsert-saved-via-transfer-summary` Edge Function
/// (`HouseholdSharingService.upsertSavedViaTransferSummary`).
///
/// LOCAL-AUTHORITATIVE / FAIL-SAFE: this is a best-effort background push. A failed upload never
/// touches `transactions`, never mutates SwiftData, and never surfaces a blocking error — the next
/// successful trigger simply re-sends the CURRENT correct local total, which is a complete, safe
/// reconciliation with no separate retry queue needed. No polling, no timer, no `asyncAfter` — every
/// call site is an existing user action or app-lifecycle event, mirroring
/// `SavingsSummarySyncService`'s own established call-site pattern.
enum SavedViaTransferSummarySyncService {
    static func sync(
        transactions: [FinanceTransaction],
        backend: HouseholdSharingService = SupabaseHouseholdSharingService()
    ) async {
        let month = DateRangeHelper.currentMonthRange()
        let savedViaTransferThisMonth = SavedViaTransferCalculator.savedThisMonth(transactions, in: month)
        _ = try? await backend.upsertSavedViaTransferSummary(
            UpsertSavedViaTransferSummaryRequest(savedViaTransferThisMonth: savedViaTransferThisMonth)
        )
    }
}
