import Foundation

/// Future responsibility: savings-progress observations — progress toward the monthly savings
/// goal, projected month-end savings — sourced from `MonthlyPlanCalculator`, never reimplemented
/// here. Foundation phase only: produces no signals yet.
struct SavingsSignalEngine: SpendSenseEngine {
    func generateSignals(context: SpendSenseContext) -> [SpendSenseSignal] {
        []
    }
}
