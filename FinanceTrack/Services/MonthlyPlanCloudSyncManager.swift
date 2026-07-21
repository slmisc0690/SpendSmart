import Foundation
import SwiftData
import Observation

/// Watches for SwiftData saves and, debounced, pushes the current authenticated user's own
/// Monthly Plan settings/income sources/recurring expenses to Supabase
/// (`sync-monthly-plan-data`) — the owner half of Phase 6's Monthly Plan cloud sync foundation.
///
/// A SEPARATE type from `ManualDataCloudSyncManager`, not a reuse/extension of it — deliberate
/// choice (per this phase's own instruction to explain it): Monthly Plan data is a genuinely
/// distinct domain (different tables, different payload shapes, a different backend endpoint, and
/// — critically — a singleton settings row with no equivalent in the Manual Account/Transaction
/// world) from Manual Accounts/Transactions. Folding both into one manager merely to reduce file
/// count would mix unrelated sync responsibilities in a single type's `performSync`, making it
/// harder to reason about failure isolation for either domain independently — exactly what this
/// phase's own instruction warns against. The two managers DO share the exact same shape
/// (observe `ModelContext.didSave`, debounce, immediate reconciliation on `startObserving`, full
/// reconciliation per pass, tombstone-based deletes) because that shape is already proven correct
/// by `AutoBackupManager` (Phase 3) and `ManualDataCloudSyncManager` (Phase 5) — reusing a PATTERN
/// is not the same as reusing a TYPE, and the pattern itself is what's actually being reused here.
///
/// FULL RECONCILIATION, NOT A DELTA SYNC, and NO ONE-TIME BACKFILL MARKER — identical reasoning to
/// `ManualDataCloudSyncManager`'s own doc comment: every sync pass re-uploads the user's ENTIRE
/// current Monthly Plan state (settings + every income source + every recurring expense), safe
/// because the server's own upsert is idempotent; `startObserving` triggers one immediate pass,
/// which serves as the initial backfill of any pre-existing local data with no separate marker
/// needed (a marker gated on "attempted" rather than "verifiably complete" would be actively
/// unsafe for a network-dependent operation — see `ManualDataCloudSyncManager`'s fuller argument).
///
/// DELETIONS are handled via `PendingCloudDeletion` tombstones — recorded by
/// `MonthlyPlanIncomeSourceDeletionService`/`MonthlyPlanRecurringExpenseDeletionService` in the
/// same save transaction as the delete itself, then processed and cleared here only once the
/// server confirms the corresponding cloud row is gone. `MonthlyPlanSettings` has no delete path
/// at all (a singleton is only ever upserted, matching the local model's own design) — nothing to
/// tombstone for it.
///
/// FAILURE ISOLATION: every failure path here only ever sets `lastSyncError` — never deletes,
/// modifies, or blocks access to any local data.
@Observable
final class MonthlyPlanCloudSyncManager {
    private(set) var lastSyncError: String?

    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private let debounceDelay: Duration
    private let backend: MonthlyPlanSyncService

    init(debounceDelay: Duration = .seconds(3), backend: MonthlyPlanSyncService = SupabaseMonthlyPlanSyncService()) {
        self.debounceDelay = debounceDelay
        self.backend = backend
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Starts observing `context`'s saves for `userId` and immediately triggers one reconciliation
    /// pass. Safe to call more than once — later calls replace the previous observation rather
    /// than stacking, matching `AutoBackupManager`/`ManualDataCloudSyncManager`.
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

    /// Stops observing entirely and cancels any pending debounced sync — called on sign-out,
    /// before the outgoing user's `ModelContext`/container is released, same pairing as
    /// `AutoBackupManager`/`ManualDataCloudSyncManager`.
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
            // #Predicate — matching PlaidLocalDataCleanupService's/ManualDataCloudSyncManager's own
            // established pattern for this exact class of check.
            let allPendingDeletions = try context.fetch(FetchDescriptor<PendingCloudDeletion>())
            let pendingDeletions = allPendingDeletions.filter { $0.ownerUserID == userId }
            let deletedIncomeSourceIds = pendingDeletions
                .filter { $0.entityType == PendingCloudDeletionEntityType.monthlyPlanIncomeSource.rawValue }
                .map { $0.recordID.uuidString }
            let deletedRecurringExpenseIds = pendingDeletions
                .filter { $0.entityType == PendingCloudDeletionEntityType.monthlyPlanRecurringExpense.rawValue }
                .map { $0.recordID.uuidString }

            let allSettings = try context.fetch(FetchDescriptor<MonthlyPlanSettings>())
            let ownedSettings = allSettings.first { $0.ownerUserID == userId }
            let settingsPayload = ownedSettings.map(MonthlyPlanSyncPayloadBuilder.settingsPayload(for:))

            let allIncomeSources = try context.fetch(FetchDescriptor<IncomeSource>())
            let ownedIncomeSources = allIncomeSources.filter { $0.ownerUserID == userId }
            let incomeSourcePayloads = ownedIncomeSources.map(MonthlyPlanSyncPayloadBuilder.incomeSourcePayload(for:))

            let allRecurringExpenses = try context.fetch(FetchDescriptor<RecurringExpense>())
            let ownedRecurringExpenses = allRecurringExpenses.filter { $0.ownerUserID == userId }
            let recurringExpensePayloads = ownedRecurringExpenses.map(MonthlyPlanSyncPayloadBuilder.recurringExpensePayload(for:))

            guard settingsPayload != nil || !incomeSourcePayloads.isEmpty || !recurringExpensePayloads.isEmpty
                || !deletedIncomeSourceIds.isEmpty || !deletedRecurringExpenseIds.isEmpty
            else {
                lastSyncError = nil
                return
            }

            let request = MonthlyPlanSyncRequest(
                settings: settingsPayload,
                income_sources: incomeSourcePayloads,
                recurring_expenses: recurringExpensePayloads,
                deleted_income_source_ids: deletedIncomeSourceIds,
                deleted_recurring_expense_ids: deletedRecurringExpenseIds
            )
            let result = try await backend.syncMonthlyPlanData(request)

            // Clear ONLY the tombstones the server explicitly confirmed deleted — never
            // speculatively, matching ManualDataCloudSyncManager's exact reasoning.
            let confirmedDeletedIds = Set(result.deletedIncomeSourceIds + result.deletedRecurringExpenseIds)
            var didClearTombstone = false
            for tombstone in pendingDeletions where confirmedDeletedIds.contains(tombstone.recordID.uuidString) {
                context.delete(tombstone)
                didClearTombstone = true
            }
            if didClearTombstone {
                try context.save()
            }

            lastSyncError = nil
        } catch {
            // Never touches local data on failure — the next save (or the next app launch's own
            // immediate reconciliation pass) retries from scratch.
            lastSyncError = error.localizedDescription
        }
    }
}
