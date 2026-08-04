import Foundation
import SwiftUI

/// The stable, canonical set of screens a user can pin to the Dashboard Favorites Bar. The raw
/// value is the ONLY thing ever persisted (`FavoritesSettings.orderedDestinationIDs`) — never a
/// display label or SF Symbol name — so renaming `displayName`/`systemImageName` below can never
/// silently break (or rename) an already-saved favorite. Adding a new case is safe and additive;
/// removing a case makes it a "stale" id for any user who already had it selected (see
/// `FavoritesSettings.validDestinationIDs`, which drops anything that no longer parses).
///
/// "Budget Settings" was deliberately NOT added here — investigation found no standalone canonical
/// destination for it: the Budget Settings UI is an inline, permanently-read-only card inside
/// `SettingsView` itself (`WeeklyLimitEditView`/`MonthlyGoalEditView` are both locked, non-editable
/// display screens, never a configuration entry point a Favorite could meaningfully open).
enum FavoriteDestinationID: String, CaseIterable, Codable, Identifiable, Equatable, Sendable {
    case monthlyPlan
    case addToSavings
    case connectedAccounts
    case accountSharing
    case backup
    case insights

    var id: String { rawValue }

    /// Shown in the Favorites configuration screen (Profile ▸ Favorites) — the full, unambiguous
    /// name. Also used as the Dashboard pill's `accessibilityLabel` (VoiceOver always hears the
    /// full name, even where `dashboardLabel` below shows an abbreviated on-screen version).
    var displayName: String {
        switch self {
        case .monthlyPlan: return "Monthly Plan"
        case .addToSavings: return "Add to Savings"
        case .connectedAccounts: return "Connected Accounts"
        case .accountSharing: return "Account Sharing"
        case .backup: return "Backup"
        case .insights: return "Insights"
        }
    }

    /// Shown ONLY under the icon in the Dashboard Favorites Bar — deliberately shorter than
    /// `displayName` so six of these can sit side by side without wrapping/scrolling on the
    /// smallest supported device. Never persisted, never used for identity — purely a Dashboard
    /// presentation label; the Favorites configuration screen keeps showing `displayName` in full.
    var dashboardLabel: String {
        switch self {
        case .monthlyPlan: return "Monthly Plan"
        case .addToSavings: return "+ Savings"
        case .connectedAccounts: return "Accounts"
        case .accountSharing: return "Sharing"
        case .backup: return "Backup"
        case .insights: return "Insights"
        }
    }

    var systemImageName: String {
        switch self {
        case .monthlyPlan: return "calendar.badge.clock"
        case .addToSavings: return "banknote.fill"
        case .connectedAccounts: return "building.columns.fill"
        case .accountSharing: return "person.2.circle.fill"
        case .backup: return "icloud.and.arrow.up.fill"
        case .insights: return "chart.line.uptrend.xyaxis"
        }
    }

    var accessibilityHint: String {
        "Opens \(displayName)"
    }

    /// The ONE canonical color identity per destination — shared by `FavoritesConfigurationView`'s
    /// list rows and `FavoritesBarView`'s Dashboard pill via `FavoriteDestinationIconBadge` below,
    /// so the two screens can never define their own separate color switch and drift apart. Stable
    /// and deterministic (a plain `switch`, no randomness, no dependency on selection order or
    /// count). Reuses an existing `Theme` token wherever one is already a good semantic/visual
    /// match (`Theme.accent` for blue, `Theme.accentSecondary` for purple, `Theme.statusGood` for
    /// green, `Theme.statusWarning` for orange) rather than inventing a parallel color system;
    /// Connected Accounts (teal) and Insights (pink) have no existing token to reuse, so they're
    /// defined here using the same RGB-literal style every other color in `Theme.swift` already
    /// uses.
    var accentColor: Color {
        switch self {
        case .monthlyPlan: return Theme.accent
        case .addToSavings: return Theme.statusGood
        case .connectedAccounts: return Color(red: 0.243, green: 0.706, blue: 0.729)
        case .accountSharing: return Theme.accentSecondary
        case .backup: return Theme.statusWarning
        case .insights: return Color(red: 0.925, green: 0.365, blue: 0.647)
        }
    }

    /// Whether this destination is currently eligible for the SIGNED-IN user — checked both when
    /// populating the Favorites configuration list (an ineligible destination is never offered) and
    /// when deciding what to render on the Dashboard bar (a previously-selected favorite that has
    /// since become ineligible is safely omitted, never shown/opened). Every other destination view
    /// already self-adapts to Primary/Secondary role internally (see each one's own header comment
    /// — `MonthlyPlanEntryView` routes to the Primary's shared plan or the owned one,
    /// `AccountRelatedOptionsView` renders different content per role) and therefore has no
    /// eligibility restriction of its own — `.accountSharing` is the one exception: its row on
    /// `SettingsView` is itself hidden while `AccountRelatedOptionsViewModel`'s role hasn't resolved
    /// yet (`.hidden`), so Favorites must honor the exact same gate rather than exposing (or trying
    /// to open) that destination before role resolution completes.
    static func isEligible(
        _ id: FavoriteDestinationID,
        accountRelatedOptionsVisibility: AccountRelatedOptionsViewModel.Visibility
    ) -> Bool {
        switch id {
        case .accountSharing: return accountRelatedOptionsVisibility != .hidden
        case .monthlyPlan, .addToSavings, .connectedAccounts, .backup, .insights: return true
        }
    }
}
