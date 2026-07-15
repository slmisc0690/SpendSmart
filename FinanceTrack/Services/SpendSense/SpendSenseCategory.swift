import Foundation

/// The broad financial topic a `SpendSenseSignal` is about. Deliberately coarse-grained (not, e.g.,
/// `budgetPace` vs. `budgetOverspend`) — the finer distinction between "which specific rule
/// produced this" belongs to whatever engine generated it, not to a case here.
enum SpendSenseCategory: String, Codable, CaseIterable, Sendable {
    case budget
    case spending
    case income
    case cashFlow
    case subscriptions
    case savings
    case creditCards
    case positive
}
