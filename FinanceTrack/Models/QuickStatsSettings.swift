import Foundation
import SwiftData

/// Singleton-style, per-user record of which Dashboard Quick Stats are hidden — same "one row per
/// user's isolated store" pattern as `FavoritesSettings`/`BudgetSettings`. Per-user isolation comes
/// ENTIRELY from `UserDataStoreManager`'s per-user SwiftData store file (this model carries no
/// `userId`/owner field of its own) — registering this type in that manager's schema is the whole
/// isolation guarantee, not anything this file does.
///
/// Stores HIDDEN ids rather than SELECTED ids, deliberately — so a brand-new record (or a user who
/// never opens the configuration screen) shows every Quick Stat by default, including any new one
/// added in a future update, without needing a migration to backfill a "selected" list.
@Model
final class QuickStatsSettings {
    var id: UUID
    /// `QuickStatID.rawValue` strings currently hidden. May contain a stale/unknown string (a stat
    /// removed in a future app version) — harmless, since `isHidden` only ever checks membership
    /// and an unrecognized string simply never matches a real `QuickStatID`.
    var hiddenRawIDs: [String]
    var updatedAt: Date

    init(id: UUID = UUID(), hiddenRawIDs: [String] = [], updatedAt: Date = .now) {
        self.id = id
        self.hiddenRawIDs = hiddenRawIDs
        self.updatedAt = updatedAt
    }

    func isHidden(_ stat: QuickStatID) -> Bool {
        hiddenRawIDs.contains(stat.rawValue)
    }

    func setHidden(_ stat: QuickStatID, hidden: Bool) {
        let alreadyHidden = isHidden(stat)
        guard hidden != alreadyHidden else { return }
        if hidden {
            hiddenRawIDs.append(stat.rawValue)
        } else {
            hiddenRawIDs.removeAll { $0 == stat.rawValue }
        }
        updatedAt = .now
    }

    /// Same duplicate-row-resolution pattern as `FavoritesSettings.resolveCanonicalRecord` — the
    /// ONE place this model is allowed to create or merge rows, always from an explicit,
    /// user-visible-context call (`QuickStatsConfigurationView`'s own `.onAppear`/mutation call
    /// sites), NEVER from `DashboardView`'s passive read path. Merges every distinct hidden id
    /// across duplicate rows onto the first (deterministically sorted) row, so a duplicate-row race
    /// can never silently un-hide a stat the user had already hidden on a different row.
    @discardableResult
    static func resolveCanonicalRecord(existing: [QuickStatsSettings], in context: ModelContext) -> QuickStatsSettings {
        if existing.count <= 1 {
            if let only = existing.first { return only }
            let created = QuickStatsSettings()
            context.insert(created)
            try? context.save()
            return created
        }

        let survivor = existing[0]
        var mergedHiddenIDs: [String] = []
        for record in existing {
            for rawID in record.hiddenRawIDs where !mergedHiddenIDs.contains(rawID) {
                mergedHiddenIDs.append(rawID)
            }
        }
        if mergedHiddenIDs != survivor.hiddenRawIDs {
            survivor.hiddenRawIDs = mergedHiddenIDs
            survivor.updatedAt = .now
        }
        for duplicate in existing.dropFirst() {
            context.delete(duplicate)
        }
        try? context.save()
        return survivor
    }
}
