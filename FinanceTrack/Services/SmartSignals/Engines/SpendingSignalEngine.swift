import Foundation

/// Future responsibility: spending-trend observations — category or overall spend up/down vs.
/// prior periods, merchant concentration, weekday spending patterns, the largest qualifying
/// expense — sourced from `BudgetCalculator`'s existing totals/breakdowns, never reimplemented
/// here. Foundation phase only: produces no signals yet.
struct SpendingSignalEngine: SmartSignalEngine {
    func generateSignals(context: SmartSignalContext) -> [SmartSignal] {
        []
    }
}
