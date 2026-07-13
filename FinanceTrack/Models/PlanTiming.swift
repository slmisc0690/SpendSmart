import Foundation

/// When within its cycle an `IncomeSource` or `RecurringExpense` lands. Purely descriptive for
/// now (shown in the UI) — `MonthlyPlanCalculator` uses `dayOfMonth`/`nextPayDate`/`dueDate` for
/// actual date math, not this enum.
enum PlanTiming: String, Codable, CaseIterable, Identifiable {
    case beginningMonth
    case midMonth
    case endMonth
    case weekly
    case customDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beginningMonth: return "Beginning of Month"
        case .midMonth: return "Mid-Month"
        case .endMonth: return "End of Month"
        case .weekly: return "Weekly"
        case .customDate: return "Custom Date"
        }
    }
}
