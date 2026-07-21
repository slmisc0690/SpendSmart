import Foundation
import SwiftData

/// What kind of local row a `PendingCloudDeletion` tombstone refers to.
enum PendingCloudDeletionEntityType: String, Codable {
    case manualAccount
    case manualTransaction
    /// Phase 6 — see `MonthlyPlanIncomeSourceDeletionService`.
    case monthlyPlanIncomeSource
    /// Phase 6 — see `MonthlyPlanRecurringExpenseDeletionService`.
    case monthlyPlanRecurringExpense
}

/// A durable, local tombstone recorded in the SAME save transaction as deleting a Manual `Account`
/// or `FinanceTransaction` (see `ManualAccountDeletionService`/`ManualTransactionDeletionService`).
/// Exists because once a SwiftData row is actually deleted, there is nothing left to enumerate to
/// know what to tell the server to remove — this is the minimal state needed to make that deletion
/// durably syncable without any full offline conflict-resolution engine (Phase 5's own instruction
/// not to introduce one unless required).
///
/// Removed by `ManualDataCloudSyncManager` only AFTER the server confirms the corresponding cloud
/// row (if any — the row may never have been synced yet, e.g. created and deleted before the first
/// sync ran) has been deleted — never removed speculatively before that confirmation, so a
/// transient network failure can never silently leave a ghost row in the cloud.
@Model
final class PendingCloudDeletion {
    var id: UUID
    var entityType: String
    /// The `id` of the now-deleted `Account`/`FinanceTransaction` — never resolvable back to the
    /// row itself once this tombstone exists, which is exactly why this field must be captured
    /// BEFORE the delete, not derived from it afterward.
    var recordID: UUID
    var ownerUserID: UUID
    var createdAt: Date

    init(
        id: UUID = UUID(),
        entityType: PendingCloudDeletionEntityType,
        recordID: UUID,
        ownerUserID: UUID,
        createdAt: Date = .now
    ) {
        self.id = id
        self.entityType = entityType.rawValue
        self.recordID = recordID
        self.ownerUserID = ownerUserID
        self.createdAt = createdAt
    }
}
