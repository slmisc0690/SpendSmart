import Foundation

/// CLIENT UI PHASE — the client-side push half of Monthly Savings sharing (migration 0018 /
/// Phase A-B). `SavingsEntry` itself remains entirely local-only SwiftData — this NEVER uploads an
/// entry, its id, its date, or the Savings Goal; it uploads exactly the two aggregate totals
/// `SavingsCalculator` already computes from the owner's own local entries, via the verified
/// `upsert-savings-summary` Edge Function (`HouseholdSharingService.upsertSavingsSummary`).
///
/// LOCAL-AUTHORITATIVE / FAIL-SAFE: this is a best-effort background push. A failed upload never
/// touches `entries`, never mutates SwiftData, and never surfaces a blocking error — the next
/// successful trigger (add, delete, or an existing app-lifecycle reconciliation point) simply
/// re-sends the CURRENT correct local totals, which is a complete, safe reconciliation with no
/// separate retry queue needed. No polling, no timer, no `asyncAfter` — every call site is an
/// existing user action or app-lifecycle event (see `MonthlyPlanView`/`DashboardView`/
/// `AddSavingsEntryView`'s own call sites).
enum SavingsSummarySyncService {
    static func sync(
        entries: [SavingsEntry],
        backend: HouseholdSharingService = SupabaseHouseholdSharingService()
    ) async {
        let month = DateRangeHelper.currentMonthRange()
        let savedThisMonth = SavingsCalculator.savedThisMonth(entries, in: month)
        let totalSavingsToDate = SavingsCalculator.totalSavingsToDate(entries)
        _ = try? await backend.upsertSavingsSummary(
            UpsertSavingsSummaryRequest(savedThisMonth: savedThisMonth, totalSavingsToDate: totalSavingsToDate)
        )
    }
}
