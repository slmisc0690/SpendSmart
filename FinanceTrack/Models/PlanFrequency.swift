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

    var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Biweekly"
        case .twiceMonthly: return "Twice a Month"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        case .oneTime: return "One-Time"
        }
    }
}
