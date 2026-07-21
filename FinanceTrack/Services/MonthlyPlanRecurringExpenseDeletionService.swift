import Foundation
import SwiftData

/// Centralizes deletion of a `RecurringExpense`. Mirrors
/// `MonthlyPlanIncomeSourceDeletionService`'s exact reasoning — no dedicated deletion path exists
/// anywhere in this app today (confirmed by inspection), so this exists to give Phase 6's
/// cloud-sync architecture a real, correct deletion path to hook into. No balance to reverse, no
/// Plaid-import eligibility to check — a `RecurringExpense` is pure forecasting data.
enum MonthlyPlanRecurringExpenseDeletionService {

    /// Deletes `recurringExpense` and records a `PendingCloudDeletion` tombstone — in the SAME
    /// save as the delete itself — when `recurringExpense.ownerUserID` is set. Returns `false`
    /// only if the save itself throws.
    @discardableResult
    static func delete(_ recurringExpense: RecurringExpense, context: ModelContext) -> Bool {
        if let ownerUserID = recurringExpense.ownerUserID {
            context.insert(
                PendingCloudDeletion(entityType: .monthlyPlanRecurringExpense, recordID: recurringExpense.id, ownerUserID: ownerUserID)
            )
        }
        context.delete(recurringExpense)
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
