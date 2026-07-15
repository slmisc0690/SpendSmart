import Foundation

/// Future responsibility: cash-flow observations — income vs. spending pace this period,
/// available-after-bills trends — sourced from `MonthlyPlanCalculator`, never reimplemented here.
/// Foundation phase only: produces no signals yet.
struct CashFlowSignalEngine: SpendSenseEngine {
    func generateSignals(context: SpendSenseContext) -> [SpendSenseSignal] {
        []
    }
}
