import Foundation

/// The Scenario Builder's top-level entry choice — one "What if..." card per thing the user can
/// modify. Deliberately a SEPARATE type from `ScenarioCategory`: `ScenarioCategory` still
/// classifies individual `ScenarioLineItem`s (and still powers "Extra Spending After Mid-Month/
/// End-of-Month Bills" — see `ScenarioSummaryBuilder`), while `ScenarioGoal` is purely the UI's own
/// entry-flow selector and carries no line-item semantics of its own.
enum ScenarioGoal: String, CaseIterable, Identifiable, Equatable, Sendable {
    case income
    case fixedBills
    case monthlySavingsGoal
    case plannedWeeklySpending
    case customDateRange

    var id: String { rawValue }

    /// Card title (PHASE 7 — Part 2).
    var title: String {
        switch self {
        case .income: return "Income"
        case .fixedBills: return "Fixed Bills"
        case .monthlySavingsGoal: return "Savings Goal"
        case .plannedWeeklySpending: return "Planned Weekly Spending"
        case .customDateRange: return "Custom Date Range"
        }
    }

    /// Card subtitle (PHASE 7 — Part 2) — short and action-oriented rather than a question, since
    /// the card itself is now the action (tap to build that kind of change), not a question to
    /// answer.
    var cardSubtitle: String {
        switch self {
        case .income: return "Add • Remove • Change"
        case .fixedBills: return "Add • Remove • Change"
        case .monthlySavingsGoal: return "Adjust Monthly Goal"
        case .plannedWeeklySpending: return "Adjust Weekly Amount"
        case .customDateRange: return "Analyze Any Time Period"
        }
    }

    /// Card icon (PHASE 7 — Part 2: emoji, Apple Settings-style, not an SF Symbol).
    var emoji: String {
        switch self {
        case .income: return "💰"
        case .fixedBills: return "🧾"
        case .monthlySavingsGoal: return "🎯"
        case .plannedWeeklySpending: return "🗓️"
        case .customDateRange: return "📅"
        }
    }
}
