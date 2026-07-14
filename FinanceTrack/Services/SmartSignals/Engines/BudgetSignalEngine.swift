import Foundation

/// Future responsibility: weekly/monthly budget-pace observations — e.g. spending faster or
/// slower than a typical pace for this point in the period, projected month-end spend vs. the
/// weekly/monthly limit — sourced from `BudgetCalculator`/`MonthlyPlanCalculator`, never
/// reimplemented here. Foundation phase only: produces no signals yet.
struct BudgetSignalEngine: SmartSignalEngine {
    func generateSignals(context: SmartSignalContext) -> [SmartSignal] {
        []
    }
}
