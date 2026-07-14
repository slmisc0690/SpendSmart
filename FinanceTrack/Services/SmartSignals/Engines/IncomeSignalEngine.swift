import Foundation

/// Future responsibility: income-trend observations — income up/down vs. prior periods, an
/// expected income source not yet received — sourced from `context.incomeSources`, never
/// reimplemented from raw transactions. Foundation phase only: produces no signals yet.
struct IncomeSignalEngine: SmartSignalEngine {
    func generateSignals(context: SmartSignalContext) -> [SmartSignal] {
        []
    }
}
