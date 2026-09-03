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

    /// TWO-LINE FAVORITES PHASE — which `Account` the `.checkingRegister` Favorite opens, by its
    /// stable `Account.id` UUID — never a name/index, so a rename or reorder can never break it.
    /// `nil` until Scott configures one (`CheckingRegisterAccountPickerView`), and safely `nil`
    /// again if the configured account is ever deleted (`DashboardView.handleFavoriteSelection(_:)`
    /// only ever resolves against currently-existing, non-archived accounts — a stale id here is
    /// simply treated as "not yet configured," re-prompting rather than crashing or guessing).
    /// Optional so every pre-existing `FavoritesSettings` row (from before this phase) decodes with
    /// no migration needed, matching this model's own lightweight-migration-friendly convention.
    var checkingRegisterAccountID: UUID?

    init(id: UUID = UUID(), orderedDestinationIDs: [String] = [], updatedAt: Date = .now, checkingRegisterAccountID: UUID? = nil) {
        self.id = id
        self.orderedDestinationIDs = orderedDestinationIDs
        self.updatedAt = updatedAt
        self.checkingRegisterAccountID = checkingRegisterAccountID
    }

    /// The recognized subset of `orderedDestinationIDs`, in the same order — the ONLY safe way to
    /// read this model's favorites. Never throws, never crashes on an unrecognized id.
    ///
    /// PHASE 2B VISUAL FIX — every raw id is mapped through `canonicalDisplayDestination` (which
    /// collapses the retired `addToSavings` into `monthlyPlan`) and de-duplicated, so a legacy
    /// `addToSavings` entry ALWAYS displays/routes correctly as "Monthly Plan" even before
    /// `migrateAddToSavingsToMonthlyPlanIfNeeded()` below has ever run persistently, and a user who
    /// somehow has both `monthlyPlan` and `addToSavings` stored never sees two "Monthly Plan"
    /// pills. Read-only — never mutates `orderedDestinationIDs` itself.
    var validDestinationIDs: [FavoriteDestinationID] {
        var seen = Set<FavoriteDestinationID>()
        var result: [FavoriteDestinationID] = []
        for raw in orderedDestinationIDs {
            guard let parsed = FavoriteDestinationID(rawValue: raw) else { continue }
            let canonical = parsed.canonicalDisplayDestination
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            result.append(canonical)
        }
        return result
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

    /// TWO-LINE FAVORITES PHASE — the one place `checkingRegisterAccountID` is ever written, called
    /// only from an explicit, user-visible-context selection (`CheckingRegisterAccountPickerView`'s
    /// own confirm action) — never a passive side effect of rendering the Dashboard, matching this
    /// model's own established "no passive read/write during render" rule.
    func setCheckingRegisterAccount(_ accountID: UUID?) {
        guard checkingRegisterAccountID != accountID else { return }
        checkingRegisterAccountID = accountID
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

    /// PHASE 2B VISUAL FIX — persistently rewrites any raw `"addToSavings"` entries to
    /// `"monthlyPlan"` (never silently dropped), collapsing a duplicate if `"monthlyPlan"` is
    /// ALSO already present rather than ever producing two Monthly Plan entries. Called explicitly
    /// from `FavoritesConfigurationView.onAppear` — same "deliberate, user-visible-context
    /// mutation, never a passive render side effect" pattern as `reconcileEligibility` — and MUST
    /// run BEFORE it: `reconcileEligibility`'s own eligibility filter would otherwise strip a raw
    /// `"addToSavings"` entry outright (now permanently ineligible for new selection — see
    /// `FavoriteDestinationID.isEligible`) before it ever got the chance to migrate. Idempotent —
    /// a no-op once no `addToSavings` entry remains.
    func migrateAddToSavingsToMonthlyPlanIfNeeded() {
        guard orderedDestinationIDs.contains(FavoriteDestinationID.addToSavings.rawValue) else { return }
        var migrated: [String] = []
        var hasMonthlyPlan = false
        for raw in orderedDestinationIDs {
            if raw == FavoriteDestinationID.monthlyPlan.rawValue {
                guard !hasMonthlyPlan else { continue }
                hasMonthlyPlan = true
                migrated.append(raw)
            } else if raw == FavoriteDestinationID.addToSavings.rawValue {
                guard !hasMonthlyPlan else { continue }
                hasMonthlyPlan = true
                migrated.append(FavoriteDestinationID.monthlyPlan.rawValue)
            } else {
                migrated.append(raw)
            }
        }
        guard migrated != orderedDestinationIDs else { return }
        orderedDestinationIDs = migrated
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
