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
    /// SETTINGS ORGANIZATION PHASE — the three new top-level Settings destinations (Profile,
    /// Account, Tools). `dashboardLabel` for each measures at the existing 44pt minimum-tap-target
    /// floor (`FavoritesBarLayout.buttonWidth(forLabel:)`), so adding them introduces zero regression
    /// to `testAllSixDashboardLabelsFitWithinAvailableWidthAtSmallestSupportedDevice`'s width budget
    /// — the worst-case 6-of-9 selection is still exactly the original 6 destinations (only
    /// "Monthly Plan" exceeds the floor either way).
    case profile
    case account
    case tools
    /// TWO-LINE FAVORITES PHASE — opens Scott's own configured Manual Account register directly
    /// (`ManualAccountDetailView`, the exact same canonical destination `AccountListView` itself
    /// opens — never a duplicate register screen). Unlike every other case here, this destination
    /// has no self-contained parameterless view of its own: which `Account` it opens is picked by
    /// the user (via `CheckingRegisterAccountPickerView`) and persisted as a stable `Account.id`
    /// UUID on `FavoritesSettings.checkingRegisterAccountID` — never an account NAME, so a rename
    /// can never break it. See `DashboardView.handleFavoriteSelection(_:)` for the routing that
    /// resolves this to a real `Account` (or re-prompts if the configured one was deleted).
    case checkingRegister

    var id: String { rawValue }

    /// Shown in the Favorites configuration screen (Profile ▸ Favorites) — the full, unambiguous
    /// name. Also used as the Dashboard pill's `accessibilityLabel` (VoiceOver always hears the
    /// full name, even where `dashboardLabel` below shows an abbreviated on-screen version).
    ///
    /// USER-FACING BRANDING CORRECTION — `.insights` now displays as "SpendAI" (the active
    /// user-facing assistant brand, replacing "Ask SpendSmart"). The Swift case identifier and its
    /// `rawValue` ("insights") are deliberately left unchanged — that raw string is the ONLY thing
    /// ever persisted (`FavoritesSettings.orderedDestinationIDs`), so renaming the case itself
    /// would strand any already-saved favorite (see this enum's own header). Only the display text
    /// and its routed destination view change.
    var displayName: String {
        switch self {
        case .monthlyPlan: return "Monthly Plan"
        case .addToSavings: return "Add to Savings"
        case .connectedAccounts: return "Connected Accounts"
        case .accountSharing: return "Account Sharing"
        case .backup: return "Backup"
        case .insights: return "SpendAI"
        case .profile: return "Profile"
        // ACCOUNT OPTIONS RENAME — this is the generic Account/Account Settings destination, never
        // Connected Accounts or Manual Accounts (see `imageAssetName`'s own header). "Account" alone
        // read as confusing/ambiguous next to those two — "Account Options" is unambiguous and is
        // also the full VoiceOver-facing name (`dashboardLabel` below just splits it visually across
        // two lines). The Swift case identifier and its `rawValue` ("account") are deliberately left
        // unchanged — only the display text and artwork change (see this enum's own header).
        case .account: return "Account Options"
        case .tools: return "Tools"
        case .checkingRegister: return "Checking Register"
        }
    }

    /// Shown ONLY under the icon in the Dashboard Favorites Bar — the ONE centralized place a
    /// destination opts into a two-line title (an embedded "\n") rather than a single line, so
    /// `FavoritesBarView`/`FavoritesBarLayout` never hard-code which destinations wrap — they just
    /// measure/render whatever this returns, one line at a time. Never persisted, never used for
    /// identity — purely a Dashboard presentation label; the Favorites configuration screen keeps
    /// showing `displayName` in full (see `FavoritesConfigurationView`'s own explicit test).
    ///
    /// TWO-LINE FAVORITES PHASE — `.monthlyPlan`/`.connectedAccounts`/`.account`/`.checkingRegister`
    /// now show their real full names across two centered lines (Scott's explicit "Connected
    /// Accounts"/"Monthly Plan"/"Account Options"/"Checking Register" full-name request) now that
    /// the pill has the modest extra height (`FavoritesBarLayout.minimumButtonHeight`) to support it
    /// — every other destination stays a single line, unchanged from before.
    /// `FavoritesBarLayout.buttonWidth(forLabel:)` measures the WIDEST individual line, never the
    /// full joined string, so a two-line label is never wider than it needs to be — see that
    /// function's own header.
    var dashboardLabel: String {
        switch self {
        case .monthlyPlan: return "Monthly\nPlan"
        case .addToSavings: return "+ Savings"
        case .connectedAccounts: return "Connected\nAccounts"
        case .accountSharing: return "Sharing"
        case .backup: return "Backup"
        case .insights: return "SpendAI"
        case .profile: return "Profile"
        case .account: return "Account\nOptions"
        case .tools: return "Tools"
        case .checkingRegister: return "Checking\nRegister"
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
        case .profile: return "person.crop.circle.fill"
        case .account: return "briefcase.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .checkingRegister: return "list.bullet.clipboard.fill"
        }
    }

    var accessibilityHint: String {
        "Opens \(displayName)"
    }

    /// PHASE 2B VISUAL ASSETS — the canonical full-color artwork asset (from Scott's supplied
    /// `FavoritesBar/*.png` files) rendered by `FavoriteDestinationIconBadge`, replacing the old
    /// `systemImageName`/`accentColor`-driven SF-Symbol-in-a-tinted-circle treatment above (both
    /// left intact, unused in production UI, rather than deleted — this phase is visual-asset
    /// integration only, never a behavior/API-surface change). `.monthlyPlan` and `.addToSavings`
    /// deliberately share ONE asset (`MonthlyPlanSavingsArtwork`, from the single supplied
    /// `MonthlySavingsPlan.png`) — there is no separate "Savings" artwork file, and Scott's own
    /// mapping groups "Monthly Plan / Savings" as one visual. `.insights` uses `AskSpendSmartIcon`
    /// (from the authoritative `SpendAI.png`, confirmed byte-identical), never the
    /// supplied-but-unused `Insights.png`.
    ///
    /// TWO-LINE FAVORITES PHASE — three distinct, never-shared assets for three distinct concepts
    /// that must never be visually confused:
    /// - `.checkingRegister` uses `CheckbookArtwork` (Scott's supplied `checkbook.png`, imported
    ///   byte-for-byte, checksum-verified).
    /// - `.account` (the generic Account/Account Settings Favorite — "Account Options") now uses
    ///   its OWN dedicated `AccountOptionsArtwork` (Scott's supplied `AccountOptions.png`, also
    ///   imported byte-for-byte, checksum-verified) — it PREVIOUSLY shared `AccountsArtwork` with
    ///   the Manual Accounts tab, which read as confusing (same icon, two different destinations);
    ///   that sharing is now retired for THIS Favorite only.
    /// - `AccountsArtwork` itself is UNCHANGED and still exclusively backs the Manual Accounts tab
    ///   bar icon (`FinanceTrackApp.swift`'s own hardcoded `assetName: "AccountsArtwork"` — entirely
    ///   independent of this enum, see that call site) — nothing here touches it.
    /// - `.connectedAccounts` keeps its own separate `ConnectedAccountsArtwork`, as before.
    var imageAssetName: String {
        switch self {
        case .monthlyPlan: return "MonthlyPlanSavingsArtwork"
        case .addToSavings: return "MonthlyPlanSavingsArtwork"
        case .connectedAccounts: return "ConnectedAccountsArtwork"
        case .accountSharing: return "SharingArtwork"
        case .backup: return "BackupArtwork"
        case .insights: return "AskSpendSmartIcon"
        case .profile: return "ProfileArtwork"
        case .account: return "AccountOptionsArtwork"
        case .tools: return "ToolsArtwork"
        case .checkingRegister: return "CheckbookArtwork"
        }
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
        case .profile: return Color(red: 0.945, green: 0.769, blue: 0.298)
        case .account: return Color(red: 0.478, green: 0.545, blue: 0.639)
        case .tools: return Color(red: 0.780, green: 0.518, blue: 0.318)
        case .checkingRegister: return Color(red: 0.400, green: 0.400, blue: 0.760)
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
        // PHASE 2B VISUAL FIX — `.addToSavings` is no longer separately offered as a Favorite
        // (Scott wants exactly one "Monthly Plan" favorite, never a second "+ Savings" one). It is
        // never eligible for NEW selection; any ALREADY-persisted `addToSavings` favorite is still
        // safely handled — see `canonicalDisplayDestination` and
        // `FavoritesSettings.migrateAddToSavingsToMonthlyPlanIfNeeded()` — never silently dropped.
        case .addToSavings: return false
        case .monthlyPlan, .connectedAccounts, .backup, .insights,
             .profile, .account, .tools, .checkingRegister:
            return true
        }
    }

    /// PHASE 2B VISUAL FIX — the destination to actually DISPLAY/ROUTE for a persisted raw value,
    /// collapsing the retired `.addToSavings` favorite into `.monthlyPlan` (its replacement — see
    /// `isEligible` above). Applied by `FavoritesSettings.validDestinationIDs`, the ONE canonical
    /// read path every screen already uses, so a legacy `addToSavings` entry displays as "Monthly
    /// Plan" and routes to the same canonical Monthly Plan destination everywhere, automatically,
    /// with no per-call-site special-casing needed.
    var canonicalDisplayDestination: FavoriteDestinationID {
        self == .addToSavings ? .monthlyPlan : self
    }
}
