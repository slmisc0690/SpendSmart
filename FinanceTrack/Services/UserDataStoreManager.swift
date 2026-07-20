import Foundation
import SwiftData
import Observation

/// Coordinates the per-authenticated-user local data lifecycle: which SwiftData store is
/// attached, which namespaced `PlaidConnectionManager` is active, and the one-time legacy-data
/// claim/migration that runs the first time any user resolves on this device.
///
/// One authenticated Supabase UID == one isolated `ModelContainer` (see `storeURL(for:)`). Never
/// exposes a container for a UID other than the one most recently resolved — `RootView` (and
/// everything under it) must only ever be attached to `modelContainer` once `resolvedUserId`
/// matches the currently authenticated user, so a wrong-user `@Query` render is structurally
/// impossible rather than merely avoided by convention.
@MainActor
@Observable
final class UserDataStoreManager {
    private(set) var modelContainer: ModelContainer?
    private(set) var plaidConnectionManager: PlaidConnectionManager?
    private(set) var resolvedUserId: UUID?
    private(set) var isResolving = false
    /// Set only if `resolve(for:)` fails to create/attach the per-user store — surfaced so a
    /// future caller could show an error state; not acted on further in this phase (no new error
    /// UI is in scope here).
    private(set) var lastResolutionError: String?

    private let defaults: UserDefaults
    /// Overrides where per-user store files live; `nil` in production, meaning the real
    /// `Application Support/UserStores` directory. Exists purely so tests can point this at a
    /// throwaway temp directory instead of touching the app's real on-disk storage.
    private let userStoresBaseDirectoryOverride: URL?
    /// Overrides how the "legacy" (pre-Phase-3) source container is built; `nil` in production,
    /// meaning the real default-location container via `makeLegacyContainer()`. Exists purely so
    /// tests can supply an in-memory legacy container instead of touching this device's real
    /// pre-Phase-3 store.
    private let legacyContainerProvider: () throws -> ModelContainer

    /// UserDefaults keys for the single combined "who claimed this device's pre-Phase-3 legacy
    /// local data" marker — covers BOTH the SwiftData copy and the Plaid flat-key copy under one
    /// value, so the two can never desync (one claimed by user A, the other by user B). Not a
    /// secret; not process-memory-only; survives sign-out/sign-in and app relaunch.
    private static let legacyClaimedByUserIDKey = "legacyMigration.claimedByUserID"
    private static let legacyClaimedAtKey = "legacyMigration.claimedAt"

    init(
        defaults: UserDefaults = .standard,
        userStoresBaseDirectoryOverride: URL? = nil,
        legacyContainerProvider: (() throws -> ModelContainer)? = nil
    ) {
        self.defaults = defaults
        self.userStoresBaseDirectoryOverride = userStoresBaseDirectoryOverride
        self.legacyContainerProvider = legacyContainerProvider ?? { try Self.makeLegacyContainer() }
    }

    /// Attaches `userId`'s isolated store (creating it if this is the first time), runs the
    /// one-time legacy-data claim if nobody has claimed it yet, backfills any nil `ownerUserID`
    /// rows, and attaches a namespaced `PlaidConnectionManager`. Safe to call repeatedly for the
    /// same `userId` — a no-op once already resolved to it. Never reuses a previously-resolved
    /// container for a *different* `userId`; callers switching users must rely on this replacing
    /// `modelContainer`/`plaidConnectionManager` wholesale rather than mutating in place.
    func resolve(for userId: UUID) async {
        if resolvedUserId == userId, modelContainer != nil {
            return
        }

        isResolving = true
        lastResolutionError = nil
        defer { isResolving = false }

        do {
            let container = try makeUserContainer(for: userId)
            let context = ModelContext(container)

            try claimLegacyDataIfUnclaimed(userId: userId, destinationContext: context)
            try OwnerUserIDBackfill.run(in: context, ownerUserID: userId)

            let plaid = PlaidConnectionManager(defaults: defaults, userId: userId)

            modelContainer = container
            plaidConnectionManager = plaid
            resolvedUserId = userId
        } catch {
            lastResolutionError = error.localizedDescription
        }
    }

    /// Called on sign-out. Clears in-memory user state only — never deletes the on-disk store or
    /// any UserDefaults data, so signing back in as the same user (or anyone else, later) finds
    /// everything exactly as it was left.
    func detach() {
        modelContainer = nil
        plaidConnectionManager = nil
        resolvedUserId = nil
        lastResolutionError = nil
    }

    // MARK: - Per-user store location

    private func userStoresDirectory() throws -> URL {
        let base = try userStoresBaseDirectoryOverride ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("UserStores", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// The on-disk location of `userId`'s isolated store. The same UID always resolves to the
    /// same URL; different UIDs always resolve to different URLs — this is the whole isolation
    /// guarantee at the filesystem level, independent of any in-memory bookkeeping.
    func storeURL(for userId: UUID) throws -> URL {
        try userStoresDirectory().appendingPathComponent("\(userId.uuidString).store")
    }

    private static var schema: Schema {
        Schema([
            Account.self,
            FinanceTransaction.self,
            BudgetSettings.self,
            Category.self,
            IncomeSource.self,
            RecurringExpense.self,
            MonthlyPlanSettings.self,
        ])
    }

    private func makeUserContainer(for userId: UUID) throws -> ModelContainer {
        let url = try storeURL(for: userId)
        let config = ModelConfiguration(schema: Self.schema, url: url)
        return try ModelContainer(for: Self.schema, configurations: [config])
    }

    /// Builds a container against the exact same configuration the app has always used before
    /// Phase 3 (no explicit `url:`, `isStoredInMemoryOnly: false`) — this deterministically
    /// resolves to the same pre-existing store that already holds any real local data, without
    /// this codebase ever hardcoding/guessing SwiftData's own default path resolution. Read-only
    /// use only: never attached to the UI, never written to by anything in this type. This is the
    /// default `legacyContainerProvider` in production; tests substitute their own provider.
    static func makeLegacyContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Legacy claim

    /// Runs `LegacyDataMigrator` + `PlaidConnectionManager.migrateFlatConnectionsIfNeeded` only if
    /// nobody has claimed the device's legacy state yet, and only writes the claim marker once
    /// both complete successfully — a thrown error here leaves the marker unset, so the same
    /// (idempotent) attempt is retried on next launch rather than silently marking a failed
    /// migration as done. If the marker is already set — by this same user (already migrated,
    /// correctly a no-op) or by a different user (must never touch the legacy data or copy
    /// Plaid state into this user's namespace on their behalf) — this returns immediately.
    private func claimLegacyDataIfUnclaimed(userId: UUID, destinationContext: ModelContext) throws {
        guard defaults.string(forKey: Self.legacyClaimedByUserIDKey) == nil else { return }

        let legacyContainer = try legacyContainerProvider()
        let legacyContext = ModelContext(legacyContainer)

        try LegacyDataMigrator.migrate(from: legacyContext, into: destinationContext, ownerUserID: userId)
        PlaidConnectionManager.migrateFlatConnectionsIfNeeded(defaults: defaults, userId: userId)

        defaults.set(userId.uuidString, forKey: Self.legacyClaimedByUserIDKey)
        defaults.set(Date.now, forKey: Self.legacyClaimedAtKey)
    }
}
