import Foundation
import SwiftUI

/// The stable, canonical set of Dashboard Quick Stats a user can show or hide. The raw value is
/// the ONLY thing ever persisted (`QuickStatsSettings.hiddenRawIDs`) — never a display label or SF
/// Symbol name — so renaming `displayName`/`systemImageName` below can never silently break an
/// already-saved preference. Adding a new case is safe and additive; removing a case simply makes
/// it a "stale" id for any user whose stored preference still names it (harmlessly ignored — see
/// `QuickStatsSettings.isHidden`).
enum QuickStatID: String, CaseIterable, Codable, Identifiable, Equatable, Sendable {
    case plannedWeeklySpending
    case spentThisWeek
    case plannedMonthlySpending
    case projectedAvailableAfterSpend
    case savedThisMonth
    /// SAVED-TRACKING — the monthly total of `.transferToSavings` Manual Account entries (see
    /// `SavedViaTransferCalculator`). Distinct from `.savedThisMonth`, which totals manually-logged
    /// `SavingsEntry` rows instead — two independent ways of tracking savings, shown as two
    /// separate stats rather than combined into one figure.
    case savedViaTransfer

    var id: String { rawValue }

    /// Shown in the Quick Stats configuration screen's checklist.
    var displayName: String {
        switch self {
        case .plannedWeeklySpending: return "Planned Weekly Spending"
        case .spentThisWeek: return "Spent This Week"
        case .plannedMonthlySpending: return "Planned Monthly Spending"
        case .projectedAvailableAfterSpend: return "Projected Available After Spend"
        case .savedThisMonth: return "Saved This Month"
        case .savedViaTransfer: return "Saved"
        }
    }

    var systemImageName: String {
        switch self {
        case .plannedWeeklySpending: return "calendar"
        case .spentThisWeek: return "creditcard"
        case .plannedMonthlySpending: return "calendar.badge.clock"
        case .projectedAvailableAfterSpend: return "chart.line.uptrend.xyaxis"
        case .savedThisMonth: return "banknote"
        case .savedViaTransfer: return "arrow.turn.down.right"
        }
    }
}
