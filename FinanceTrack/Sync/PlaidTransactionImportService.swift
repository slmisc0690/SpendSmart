import Foundation
import SwiftData

/// Converts a `PlaidTransactionDTO` into a `FinanceTransaction` with `source == .plaid`, and
/// applies a full `PlaidSyncResult` to SwiftData (insert/update/remove). No networking, no Plaid
/// SDK, no token handling — this only ever touches a `ModelContext` it's given.
enum PlaidTransactionImportService {
    /// Maps one imported transaction to a `FinanceTransaction`, ready to be reviewed.
    ///
    /// Every transaction this produces is excluded from weekly/monthly totals
    /// (`isExcludedFromReports = true`, `countsTowardWeeklyBudget = false`,
    /// `countsTowardMonthlySpending = false`) — imported transactions never count toward
    /// spending until the user explicitly approves them in the review flow (a future "Add to
    /// Budget" action would flip these flags at that point). This function itself never inserts
    /// anything into persistence and never auto-merges with an existing manual entry. `category`
    /// is optional and left to the caller to resolve (e.g. from `categoryGuess`, or left nil for
    /// the user to pick during review).
    static func mapToFinanceTransaction(
        _ dto: PlaidTransactionDTO,
        account: Account?,
        category: Category? = nil
    ) -> FinanceTransaction {
        FinanceTransaction(
            amount: dto.amount,
            date: dto.postedDate ?? dto.authorizedDate ?? .now,
            type: .expense,
            source: .plaid,
            note: "",
            countsTowardWeeklyBudget: false,
            countsTowardMonthlySpending: false,
            isExcludedFromReports: true,
            isPending: dto.isPending,
            externalTransactionId: dto.externalTransactionId,
            pendingTransactionId: dto.pendingTransactionId,
            merchantName: dto.merchantName,
            originalDescription: dto.originalDescription,
            plaidAccountId: dto.plaidAccountId,
            authorizedDate: dto.authorizedDate,
            postedDate: dto.postedDate,
            account: account,
            category: category
        )
    }

    /// The result of applying one `PlaidSyncResult` to SwiftData.
    struct SyncOutcome: Equatable {
        let insertedCount: Int
        let updatedCount: Int
        let duplicateSkippedCount: Int
        let removedCount: Int
        /// Pending-to-posted transitions handled by re-keying the existing pending row (see
        /// `applySync`'s pending-merge branch) rather than inserting a fresh row — these are
        /// counted separately from `insertedCount`/`updatedCount` specifically so a caller/test
        /// can confirm user-entered data survived the transition rather than just observing "some
        /// row got updated," which a plain re-delivery of an already-posted transaction would
        /// also report.
        let mergedFromPendingCount: Int
    }

    /// Applies a full backend sync result to SwiftData: inserts new Plaid transactions, updates
    /// existing ones the backend reports as modified, and removes ones Plaid reports gone — then
    /// saves. Dedup/reconciliation key: `externalTransactionId` (Plaid's own `transaction_id`),
    /// the only identifier Plaid guarantees stays stable for a transaction across repeated syncs.
    ///
    /// Every inserted or updated record keeps the read-only-until-approved defaults
    /// (`countsTowardWeeklyBudget = false`, `isExcludedFromReports = true`) — this function never
    /// flips them on; that stays under the app's own control, never Plaid's.
    ///
    /// Removed transactions are DELETED outright rather than soft-deleted/flagged: `FinanceTransaction`
    /// has no "removed" or "deletedAt" field, and adding one purely for this would be a schema
    /// change for a case Plaid Sandbox essentially never exercises (removed transactions are rare
    /// even in production — they represent Plaid correcting its own data, e.g. a duplicate it
    /// initially reported). Since imported-but-unapproved transactions carry no other app state
    /// (no history depends on them existing), a hard delete is the simplest correct choice here.
    /// Deleting only ever targets a `source == .plaid` row matched by `externalTransactionId` —
    /// manual transactions have no `externalTransactionId`, so they can never match.
    ///
    /// PENDING-TO-POSTED: a pending transaction's `removed` entry is the OTHER HALF of the
    /// pending-to-posted merge handled inside `upsert` below (see that closure's own comment) —
    /// by the time the removal loop runs, the old pending id has already been re-keyed onto the
    /// new posted id and removed from the lookup map, so the removal loop's lookup for that same
    /// id finds nothing and correctly does nothing. This is why the removal loop must run AFTER
    /// the `added`/`modified` loops, not interleaved or before.
    @discardableResult
    static func applySync(
        _ result: PlaidSyncResult,
        context: ModelContext
    ) throws -> SyncOutcome {
        let existingPlaidTransactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
            .filter { $0.source == .plaid }
        var byExternalId: [String: FinanceTransaction] = [:]
        for transaction in existingPlaidTransactions {
            if let externalId = transaction.externalTransactionId {
                byExternalId[externalId] = transaction
            }
        }

        var insertedCount = 0
        var updatedCount = 0
        var duplicateSkippedCount = 0
        var mergedFromPendingCount = 0

        func upsert(_ dto: PlaidTransactionDTO) {
            if let existing = byExternalId[dto.externalTransactionId] {
                if applyUpdates(from: dto, to: existing) {
                    updatedCount += 1
                } else {
                    duplicateSkippedCount += 1
                }
                return
            }

            // PENDING-TO-POSTED MERGE: Plaid reports a posted transaction replacing a pending one
            // as a brand-new `added` entry (this `dto`) whose OWN `pendingTransactionId` points at
            // the OLD pending transaction's `externalTransactionId` — delivered alongside a
            // `removed` entry for that same old id (handled below). Re-keying the EXISTING pending
            // row in place — rather than inserting a fresh row for the posted id and letting the
            // `removed` handling delete the old one, which is what an earlier version of this
            // function did — is what actually preserves every user-entered field on it: category,
            // note, the `countsTowardWeeklyBudget`/`isExcludedFromReports` overrides,
            // `isMatchedToManualExpense`, `matchedTransactionId`, and `account`. None of those are
            // ever touched by `applyUpdates` (see its own doc comment), and none of them could
            // possibly survive a delete-then-insert.
            if let pendingId = dto.pendingTransactionId, let pendingTransaction = byExternalId[pendingId] {
                pendingTransaction.externalTransactionId = dto.externalTransactionId
                _ = applyUpdates(from: dto, to: pendingTransaction)
                // Re-key the lookup map itself so (a) the `removed` pass below, which still
                // contains `pendingId`, finds nothing under that key and correctly does NOT delete
                // this row, and (b) a later DTO in this same batch that references the posted id
                // (e.g. an immediate `modified` re-delivery) finds the right row.
                byExternalId.removeValue(forKey: pendingId)
                byExternalId[dto.externalTransactionId] = pendingTransaction
                mergedFromPendingCount += 1
                return
            }

            let created = mapToFinanceTransaction(dto, account: nil)
            context.insert(created)
            byExternalId[dto.externalTransactionId] = created
            insertedCount += 1
        }

        // `added` is the common case; `modified` falls back to inserting defensively if the app
        // somehow never saw the original `added` delivery for that id (e.g. an app reinstall
        // between syncs) — either way every transaction Plaid reports ends up represented exactly
        // once, keyed by externalTransactionId.
        for dto in result.added { upsert(dto) }
        for dto in result.modified { upsert(dto) }

        var removedCount = 0
        for externalId in result.removedExternalIds {
            if let existing = byExternalId[externalId], existing.source == .plaid {
                context.delete(existing)
                byExternalId.removeValue(forKey: externalId)
                removedCount += 1
            }
        }

        #if DEBUG
        print("[PlaidTransactionImportService] returned transaction count: \(result.added.count + result.modified.count)")
        print("[PlaidTransactionImportService] inserted count: \(insertedCount)")
        print("[PlaidTransactionImportService] updated count: \(updatedCount)")
        print("[PlaidTransactionImportService] duplicate-skipped count: \(duplicateSkippedCount)")
        print("[PlaidTransactionImportService] merged-from-pending count: \(mergedFromPendingCount)")
        print("[PlaidTransactionImportService] removed count: \(removedCount)")
        #endif

        do {
            try context.save()
            #if DEBUG
            print("[PlaidTransactionImportService] modelContext.save succeeded: true")
            #endif
        } catch {
            #if DEBUG
            print("[PlaidTransactionImportService] modelContext.save succeeded: false")
            #endif
            throw error
        }

        return SyncOutcome(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            duplicateSkippedCount: duplicateSkippedCount,
            removedCount: removedCount,
            mergedFromPendingCount: mergedFromPendingCount
        )
    }

    /// Copies mutable, sync-safe fields from `dto` onto `existing` — never `id`, `source`,
    /// `countsTowardWeeklyBudget`, or `isExcludedFromReports`, which stay under the app's own
    /// control. Account/category association aren't touched here either: neither is resolved at
    /// insert time yet (see `mapToFinanceTransaction`'s `category` param), so there's nothing
    /// Plaid-driven to reconcile for them until that resolution exists. Returns whether anything
    /// actually changed, so the caller can tell a genuine update apart from a no-op re-delivery.
    private static func applyUpdates(from dto: PlaidTransactionDTO, to existing: FinanceTransaction) -> Bool {
        var changed = false
        if existing.amount != dto.amount { existing.amount = dto.amount; changed = true }
        let newDate = dto.postedDate ?? dto.authorizedDate ?? existing.date
        if existing.date != newDate { existing.date = newDate; changed = true }
        if existing.isPending != dto.isPending { existing.isPending = dto.isPending; changed = true }
        if existing.merchantName != dto.merchantName { existing.merchantName = dto.merchantName; changed = true }
        if existing.originalDescription != dto.originalDescription { existing.originalDescription = dto.originalDescription; changed = true }
        if existing.authorizedDate != dto.authorizedDate { existing.authorizedDate = dto.authorizedDate; changed = true }
        if existing.postedDate != dto.postedDate { existing.postedDate = dto.postedDate; changed = true }
        if existing.pendingTransactionId != dto.pendingTransactionId { existing.pendingTransactionId = dto.pendingTransactionId; changed = true }
        if changed { existing.updatedAt = .now }
        return changed
    }
}
