import SwiftUI

/// Drives app-wide "privacy mode", which hides balance and amount figures behind `•••••`.
/// Persisted via `BudgetSettings.hideBalancesByDefault`; this class holds the live, observable
/// in-memory toggle that views bind to for instant UI response. Every dollar amount in the app
/// should be shown via `PrivacyAmountView` (or `AmountText` for values that are never sensitive),
/// so this single toggle is all that's needed to mask them everywhere at once.
@Observable
final class PrivacyModeManager {
    var isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func toggle() {
        isEnabled.toggle()
    }
}
