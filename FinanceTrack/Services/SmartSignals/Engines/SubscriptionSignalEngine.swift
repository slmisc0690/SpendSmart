import Foundation

/// Future responsibility: recurring-charge observations — likely recurring merchants,
/// subscription-like charges, a recurring bill's amount increasing, duplicate-looking charges, an
/// expected recurring bill not yet seen this period. Foundation phase only: produces no signals
/// yet.
struct SubscriptionSignalEngine: SmartSignalEngine {
    func generateSignals(context: SmartSignalContext) -> [SmartSignal] {
        []
    }
}
