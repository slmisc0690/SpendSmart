import Foundation
import SwiftData

/// Centralizes deletion of an `IncomeSource`. No dedicated deletion path exists anywhere in this
/// app today (confirmed by inspection before authoring this file — no view calls
/// `context.delete(_ incomeSource:)` directly) — Monthly Plan v1 only exposes create/edit through
/// its UI. This service exists so the cloud-sync architecture (Phase 6) has a real, correct
/// deletion path to hook into, matching the exact centralized-service pattern already established
/// for Manual Accounts/Transactions (`ManualAccountDeletionService`/
/// `ManualTransactionDeletionService`, Phase 5), ready for a future edit-screen delete action to
/// call — this phase does not add that UI itself (out of scope).
///
/// Unlike the Manual Account/Transaction deletion services, there is no balance to reverse and no
/// Plaid-import eligibility to check — an `IncomeSource` is pure forecasting data with no side
/// effect on any account balance.
enum MonthlyPlanIncomeSourceDeletionService {

    /// Deletes `incomeSource` and records a `PendingCloudDeletion` tombstone — in the SAME save as
    /// the delete itself — when `incomeSource.ownerUserID` is set (matches
    /// `ManualAccountDeletionService.delete`'s identical reasoning: a still-nil `ownerUserID`
    /// means nothing was ever synced to the cloud for this row). Returns `false` only if the save
    /// itself throws — deletion has no other eligibility precondition.
    @discardableResult
    static func delete(_ incomeSource: IncomeSource, context: ModelContext) -> Bool {
        if let ownerUserID = incomeSource.ownerUserID {
            context.insert(
                PendingCloudDeletion(entityType: .monthlyPlanIncomeSource, recordID: incomeSource.id, ownerUserID: ownerUserID)
            )
        }
        context.delete(incomeSource)
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
