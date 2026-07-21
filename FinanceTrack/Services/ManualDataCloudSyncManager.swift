import Foundation
import SwiftData
import Observation

/// Watches for SwiftData saves and, debounced, pushes the current authenticated user's own Manual
/// Accounts/Transactions to Supabase (`sync-manual-data`) — the owner half of Phase 5's Manual
/// Account cloud sync foundation. Mirrors `AutoBackupManager`'s own established shape exactly:
/// observes `ModelContext.didSave` (SwiftData's own global save notification) rather than
/// instrumenting every add/edit/delete call site across the UI — the same "narrowest reliable
/// path" this phase's own instruction asks for.
///
/// FULL RECONCILIATION, NOT A DELTA SYNC: every sync pass re-uploads EVERY currently-existing
/// Manual Account/Transaction this user owns (never just "what changed since last time") — the
/// server's own upsert-by-id is idempotent, so this is safe to repeat on every save, exactly
/// mirroring `AutoBackupManager.performBackup`'s own identical full-re-serialize-every-time
/// approach (see that type's doc comment). This is also what makes the INITIAL BACKFILL of
/// pre-existing local data work with NO separate one-time-per-user marker: `startObserving` itself
/// triggers one immediate reconciliation pass, which naturally uploads everything that already
/// existed before Phase 5 shipped, and — because there is no "done forever" marker — automatically
/// retries on every subsequent launch too, so a backfill that partially failed (e.g. offline at
/// that first launch) is never permanently treated as complete. A one-time marker was
/// deliberately NOT used (unlike `UserDataStoreManager`'s legacy-claim/Plaid-date-repair markers)
/// specifically because THIS operation depends on network reachability, and a marker gated on
/// "attempted" rather than "verifiably complete" would be actively unsafe here.
///
/// DELETIONS are handled separately via `PendingCloudDeletion` tombstones (see that model's own
/// doc comment) — recorded by `ManualAccountDeletionService`/`ManualTransactionDeletionService` in
/// the same save transaction as the delete itself, then processed and cleared here only once the
/// server confirms the corresponding cloud row is gone.
///
/// FAILURE ISOLATION: every failure path here only ever sets `lastSyncError` — never deletes,
/// modifies, or blocks access to any local data. The existing local SwiftData store remains fully
/// authoritative for this owner's own UI regardless of cloud sync health (Phase 5's own explicit
/// requirement).
@Observable
final class ManualDataCloudSyncManager {
    /// Set after each attempted sync so a future settings screen could show sync health, without
    /// throwing anywhere the user can't see it — same posture as `AutoBackupManager.lastBackupError`.
    private(set) var lastSyncError: String?

    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private let debounceDelay: Duration
    private let backend: ManualDataSyncService

    init(debounceDelay: Duration = .seconds(3), backend: ManualDataSyncService = SupabaseManualDataSyncService()) {
        self.debounceDelay = debounceDelay
        self.backend = backend
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Starts observing `context`'s saves for `userId` and immediately triggers one reconciliation
    /// pass (see this type's own doc comment for why that substitutes for a one-time backfill
    /// marker). Safe to call more than once — later calls replace the previous observation rather
    /// than stacking, matching `AutoBackupManager.startObserving`.
    func startObserving(context: ModelContext, userId: UUID) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: context,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleSync(context: context, userId: userId, immediate: false)
        }
        scheduleSync(context: context, userId: userId, immediate: true)
    }

    /// Stops observing entirely and cancels any pending debounced sync — called on sign-out, same
    /// reasoning and same call-site pairing as `AutoBackupManager.stopObserving`: must run before
    /// the outgoing user's `ModelContext`/container is released, so no debounced sync can fire
    /// against a context whose owning container is going away.
    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleSync(context: ModelContext, userId: UUID, immediate: Bool) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceDelay] in
            if !immediate {
                try? await Task.sleep(for: debounceDelay)
                guard !Task.isCancelled else { return }
            }
            await self?.performSync(context: context, userId: userId)
        }
    }

    @MainActor
    private func performSync(context: ModelContext, userId: UUID) async {
        do {
            // Fetch-then-filter in plain Swift, not an enum/UUID-equality-on-optional inside
            // #Predicate — matching PlaidLocalDataCleanupService's own established pattern for the
            // identical class of `source == .plaid`-style check, rather than introducing a new,
            // untested #Predicate shape.
            let allPendingDeletions = try context.fetch(FetchDescriptor<PendingCloudDeletion>())
            let pendingDeletions = allPendingDeletions.filter { $0.ownerUserID == userId }
            let deletedAccountIds = pendingDeletions
                .filter { $0.entityType == PendingCloudDeletionEntityType.manualAccount.rawValue }
                .map { $0.recordID.uuidString }
            let deletedTransactionIds = pendingDeletions
                .filter { $0.entityType == PendingCloudDeletionEntityType.manualTransaction.rawValue }
                .map { $0.recordID.uuidString }

            let allAccounts = try context.fetch(FetchDescriptor<Account>())
            let ownedManualAccounts = allAccounts.filter { $0.ownerUserID == userId && $0.connectionType == .manual }
            let accountPayloads = ownedManualAccounts.map(ManualDataSyncPayloadBuilder.accountPayload(for:))

            let allTransactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
            let ownedManualTransactions = allTransactions.filter { $0.ownerUserID == userId && $0.source == .manual }
            let transactionPayloads = ownedManualTransactions.compactMap(ManualDataSyncPayloadBuilder.transactionPayload(for:))

            guard !accountPayloads.isEmpty || !transactionPayloads.isEmpty
                || !deletedAccountIds.isEmpty || !deletedTransactionIds.isEmpty
            else {
                lastSyncError = nil
                return
            }

            let request = ManualDataSyncRequest(
                accounts: accountPayloads,
                transactions: transactionPayloads,
                deleted_account_ids: deletedAccountIds,
                deleted_transaction_ids: deletedTransactionIds
            )
            let result = try await backend.syncManualData(request)

            // Clear ONLY the tombstones the server explicitly confirmed deleted — never
            // speculatively, so a partial-failure response (some ids rejected/not reached) leaves
            // the remaining tombstones in place for the next sync pass to retry.
            let confirmedDeletedIds = Set(result.deletedAccountIds + result.deletedTransactionIds)
            var didClearTombstone = false
            for tombstone in pendingDeletions where confirmedDeletedIds.contains(tombstone.recordID.uuidString) {
                context.delete(tombstone)
                didClearTombstone = true
            }
            if didClearTombstone {
                // This save itself re-fires ModelContext.didSave, scheduling one more (bounded,
                // harmless) debounced reconciliation pass — every payload it would upload is
                // already idempotent, so this converges immediately rather than looping.
                try context.save()
            }

            lastSyncError = nil
        } catch {
            // See this type's own doc comment — never touches local data on failure. The next
            // save (or the next app launch's own immediate reconciliation pass) retries from
            // scratch; nothing here is lost or partially applied locally.
            lastSyncError = error.localizedDescription
        }
    }
}
