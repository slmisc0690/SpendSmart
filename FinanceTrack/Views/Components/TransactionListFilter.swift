import Foundation

/// Display-only filter for a period's transaction rows (used by the Weekly and Monthly
/// screens). Never affects what `BudgetCalculator` counts — it only changes which rows are
/// shown underneath each day.
enum TransactionListFilter: String, CaseIterable, Identifiable {
    case allCounted = "All Counted"
    case pending = "Pending"
    case excluded = "Excluded"
    var id: String { rawValue }
}
