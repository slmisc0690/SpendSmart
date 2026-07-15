import Foundation

/// Future responsibility: credit-card observations — utilization level, an unusually large
/// balance change, a payment amount compared with the current balance — sourced from
/// `CreditUtilizationCalculator`/`context.accounts`, never reimplemented here. Foundation phase
/// only: produces no signals yet.
struct CreditCardSignalEngine: SpendSenseEngine {
    func generateSignals(context: SpendSenseContext) -> [SpendSenseSignal] {
        []
    }
}
