import Foundation

/// Coordinates every injected `SmartSignalEngine`: evaluates each one against a shared
/// `SmartSignalContext`, combines their output, deduplicates by `SmartSignal.deduplicationID`,
/// ranks what remains, and returns the final stable collection.
///
/// A plain, dependency-injected value type — never a singleton, never a static/global engine
/// list. It does not fetch data, query SwiftData, compute spending totals, own application state,
/// or reference SwiftUI; it only orchestrates the engines and signals it's given.
struct SmartSignalsEngine {
    private let engines: [any SmartSignalEngine]
    private let ranking: SmartSignalRanking

    init(
        engines: [any SmartSignalEngine],
        ranking: SmartSignalRanking = .init()
    ) {
        self.engines = engines
        self.ranking = ranking
    }

    /// Runs every injected engine against `context`, deduplicates, ranks, and returns the result.
    /// The output never depends on the order `engines` were injected in — see `deduplicate` and
    /// `SmartSignalRanking` for why.
    func generateSignals(context: SmartSignalContext) -> [SmartSignal] {
        let allSignals = engines.flatMap { $0.generateSignals(context: context) }
        let deduplicated = deduplicate(allSignals)
        return ranking.rank(deduplicated)
    }

    /// Groups signals by `deduplicationID` and keeps only the highest-ranked signal in each group
    /// (per `SmartSignalRanking.isOrderedBefore`). A dictionary is used to gather candidates per
    /// group, but its iteration order never influences the result: each group's winner is decided
    /// by direct pairwise comparison as candidates are encountered, and the final array this
    /// method returns is unordered/unstable on its own — `generateSignals` always re-ranks it
    /// afterward, so no caller ever observes dictionary order.
    private func deduplicate(_ signals: [SmartSignal]) -> [SmartSignal] {
        var winnerByDeduplicationID: [String: SmartSignal] = [:]
        for signal in signals {
            if let currentWinner = winnerByDeduplicationID[signal.deduplicationID] {
                if ranking.isOrderedBefore(signal, currentWinner) {
                    winnerByDeduplicationID[signal.deduplicationID] = signal
                }
            } else {
                winnerByDeduplicationID[signal.deduplicationID] = signal
            }
        }
        return Array(winnerByDeduplicationID.values)
    }
}
