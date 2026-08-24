import Foundation
import SwiftData

/// Singleton-style, per-user record of whether the first-run setup flow (paywall stub → "how do
/// you want to get started?" → path-specific instructions) has been completed — same "one row per
/// user's isolated store" pattern as `BudgetSettings`/`QuickStatsSettings`. Per-user isolation
/// comes ENTIRELY from `UserDataStoreManager`'s per-user SwiftData store file, not anything this
/// file does.
///
/// EXISTING-USER SAFETY — `RootView` only ever creates a row with `hasCompletedOnboarding: false`
/// for a GENUINELY brand-new user (one whose `BudgetSettings` also didn't exist yet). An existing
/// user updating to the app version that introduced this flow gets a row pre-marked
/// `hasCompletedOnboarding: true` the first time it's bootstrapped, so nobody who already has real
/// data is ever retroactively dropped into a "first run" flow.
@Model
final class OnboardingSettings {
    var id: UUID
    var hasCompletedOnboarding: Bool
    /// The path the user picked on the selection screen — `nil` if they haven't reached it yet, or
    /// chose "None". Stored purely for reference; nothing in the app currently branches on it after
    /// onboarding completes.
    var selectedPathRawValue: String?
    var updatedAt: Date

    init(id: UUID = UUID(), hasCompletedOnboarding: Bool = false, selectedPathRawValue: String? = nil, updatedAt: Date = .now) {
        self.id = id
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.selectedPathRawValue = selectedPathRawValue
        self.updatedAt = updatedAt
    }
}
