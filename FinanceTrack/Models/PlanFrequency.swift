import Foundation

/// How often an `IncomeSource` or `RecurringExpense` recurs. Shared between both models since
/// the conversion-to-monthly math (see `MonthlyPlanCalculator`) is identical either way.
enum PlanFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case twiceMonthly
    case monthly
    case quarterly
    case yearly
    case oneTime

    var id: String { rawValue }

    /// SCHEDULE UX PHASE: `.biweekly`'s user-facing label is "Every 2 Weeks," never "Biweekly" —
    /// physical-device testing found users routinely confuse "Biweekly" with "Twice a Month"
    /// (`.twiceMonthly`, a genuinely different schedule — every 14 days vs. two configured days
    /// each calendar month). The enum case itself is unchanged (renaming it would risk breaking
    /// stored `rawValue`s) — only this display string changed.
    var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 Weeks"
        case .twiceMonthly: return "Twice a Month"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        case .oneTime: return "One-Time"
        }
    }
}
