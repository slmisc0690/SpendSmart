import Foundation

/// One rule-based, single-topic evaluator that inspects a `SmartSignalContext` and returns zero
/// or more `SmartSignal`s. An engine must be:
/// - deterministic — the same context always produces the same output
/// - side-effect-free — never mutates `context`, never writes to SwiftData, never touches
///   `UserDefaults`/the filesystem/global state
/// - synchronous and local — no networking, no SwiftUI/state access
///
/// An engine calls the app's existing calculation services (`BudgetCalculator`,
/// `MonthlyPlanCalculator`, `CreditUtilizationCalculator`, `DateRangeHelper`,
/// `AccountBalanceManager`) for any spending total, eligibility check, or projection — it never
/// reimplements that math against `context.transactions` directly.
protocol SmartSignalEngine {
    func generateSignals(context: SmartSignalContext) -> [SmartSignal]
}
