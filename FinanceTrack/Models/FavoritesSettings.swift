import Foundation
import SwiftData

/// Singleton-style, per-user record of which Dashboard Favorites are selected, and in what order —
/// same "one row per user's isolated store" pattern as `BudgetSettings`/`MonthlyPlanSettings`. Per-
/// user isolation comes ENTIRELY from `UserDataStoreManager`'s per-user SwiftData store file (this
/// model carries no `userId`/owner field of its own, exactly like every other locally-owned model
/// in this schema) — registering this type in that manager's schema is the whole isolation
/// guarantee, not anything this file does.
@Model
final class FavoritesSettings {
    var id: UUID
    /// `FavoriteDestinationID.rawValue` strings, in Dashboard display order. May contain a stale/
    /// unknown string (a destination removed in a future app version, or corrupted data) — always
    /// read through `validDestinationIDs` below, never this raw array directly, so an unrecognized
    /// entry is silently dropped rather than crashing or rendering a broken favorite.
    var orderedDestinationIDs: [String]
    var updatedAt: Date

    init(id: UUID = UUID(), orderedDestinationIDs: [String] = [], updatedAt: Date = .now) {
        self.id = id
        self.orderedDestinationIDs = orderedDestinationIDs
        self.updatedAt = updatedAt
    }

    /// The recognized subset of `orderedDestinationIDs`, in the same order — the ONLY safe way to
    /// read this model's favorites. Never throws, never crashes on an unrecognized id.
    var validDestinationIDs: [FavoriteDestinationID] {
        orderedDestinationIDs.compactMap(FavoriteDestinationID.init(rawValue:))
    }

    /// Adds `id` at the end of the selected order. Returns `false` (a no-op) without mutating
    /// anything if `id` is already selected (no duplicates) or `maximumCount` has already been
    /// reached (existing favorites are left completely unchanged — never a silent replacement of
    /// the oldest one). `maximumCount` defaults to the real derived layout maximum
    /// (`FavoritesBarLayout.maximumFavoritesCount`); tests pass their own value to exercise the
    /// capacity boundary without depending on real device-width geometry.
    @discardableResult
    func addFavorite(_ id: FavoriteDestinationID, maximumCount: Int = FavoritesBarLayout.maximumFavoritesCount) -> Bool {
        guard !orderedDestinationIDs.contains(id.rawValue) else { return false }
        guard orderedDestinationIDs.count < maximumCount else { return false }
        orderedDestinationIDs.append(id.rawValue)
        updatedAt = .now
        return true
    }

    /// Removing an id that isn't currently selected is a harmless no-op (matches every other
    /// idempotent removal in this codebase's own conventions).
    func removeFavorite(_ id: FavoriteDestinationID) {
        guard orderedDestinationIDs.contains(id.rawValue) else { return }
        orderedDestinationIDs.removeAll { $0 == id.rawValue }
        updatedAt = .now
    }

    /// Reorders the SELECTED favorites only — the same native `Array.move(fromOffsets:toOffset:)`
    /// semantics `FavoritesConfigurationView`'s own `.onMove` hands this straight through, operating
    /// on `orderedDestinationIDs` directly since its element order IS the Dashboard display order.
    func moveFavorites(fromOffsets: IndexSet, toOffset: Int) {
        orderedDestinationIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        updatedAt = .now
    }

    /// Drops any stored id that is either unrecognized (stale) or no longer eligible for the
    /// current user (see `FavoriteDestinationID.isEligible`) — called explicitly from
    /// `FavoritesConfigurationView.onAppear`, a deliberate, user-visible-context cleanup action,
    /// never a passive side effect of merely rendering the Dashboard (which instead uses a
    /// non-mutating filtered projection — see `DashboardView.favoriteDestinations` — so simply
    /// showing the Dashboard can never itself mutate persisted data, matching this project's
    /// established "no passive live read/write during render" safety rule).
    func reconcileEligibility(accountRelatedOptionsVisibility: AccountRelatedOptionsViewModel.Visibility) {
        let reconciled = orderedDestinationIDs.filter { raw in
            guard let destination = FavoriteDestinationID(rawValue: raw) else { return false }
            return FavoriteDestinationID.isEligible(destination, accountRelatedOptionsVisibility: accountRelatedOptionsVisibility)
        }
        guard reconciled != orderedDestinationIDs else { return }
        orderedDestinationIDs = reconciled
        updatedAt = .now
    }

    /// PROVEN REAL-DEVICE BUG FIX — `FavoritesConfigurationView` used to resolve "the" canonical
    /// record via a plain computed property that called `modelContext.insert(FavoritesSettings())`
    /// on every access when `favoritesSettingsList.first` was still nil — and that property was
    /// referenced from several distinct call sites (`selectedDestinations`, `availableDestinations`,
    /// `.onAppear`, `toggle()`) within the same render. Since a `@Query` snapshot doesn't reflect an
    /// insert made mid-render, each of those accesses could independently create ANOTHER new row
    /// before the first one was ever read back — producing multiple rows on a real device. With no
    /// explicit `sort:` on either screen's `@Query`, `DashboardView` and `FavoritesConfigurationView`
    /// could then each resolve `.first` to a DIFFERENT one of those rows: a favorite added in
    /// Settings landed on one row while the Dashboard kept reading an empty one, so the bar never
    /// appeared. This is the ONE place either screen is allowed to create or merge rows — always as
    /// an explicit, user-visible-context call (`FavoritesConfigurationView`'s own `.onAppear`/mutation
    /// call sites), NEVER from `DashboardView`'s passive read path.
    ///
    /// Idempotent and cheap in the already-correct (`existing.count <= 1`) case — no save, no
    /// allocation beyond finding/creating the one record. Only writes when actually creating a
    /// fresh record or merging duplicates. `existing` MUST already be sorted the same deterministic
    /// way both screens' `@Query`s are sorted (`\.id`), so the survivor is chosen consistently.
    @discardableResult
    static func resolveCanonicalRecord(existing: [FavoritesSettings], in context: ModelContext) -> FavoritesSettings {
        if existing.count <= 1 {
            if let only = existing.first { return only }
            let created = FavoritesSettings()
            context.insert(created)
            try? context.save()
            return created
        }

        // Merge every distinct destination id across all duplicate rows, first-seen order, onto
        // the first (deterministically sorted) row — never silently discarding a valid favorite
        // just because it happened to land on a different duplicate.
        let survivor = existing[0]
        var mergedIDs: [String] = []
        for record in existing {
            for rawID in record.orderedDestinationIDs where !mergedIDs.contains(rawID) {
                mergedIDs.append(rawID)
            }
        }
        if mergedIDs != survivor.orderedDestinationIDs {
            survivor.orderedDestinationIDs = mergedIDs
            survivor.updatedAt = .now
        }
        for duplicate in existing.dropFirst() {
            context.delete(duplicate)
        }
        try? context.save()
        return survivor
    }
}
