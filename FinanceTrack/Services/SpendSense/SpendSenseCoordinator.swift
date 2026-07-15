import Foundation

/// Coordinates every injected `SpendSenseEngine`: evaluates each one against a shared
/// `SpendSenseContext`, combines their output, deduplicates by `SpendSenseSignal.deduplicationID`,
/// ranks what remains, and returns the final stable collection.
///
/// A plain, dependency-injected value type — never a singleton, never a static/global engine
/// list. It does not fetch data, query SwiftData, compute spending totals, own application state,
/// or reference SwiftUI; it only orchestrates the engines and signals it's given.
struct SpendSenseCoordinator {
    private let engines: [any SpendSenseEngine]
    private let ranking: SpendSenseRanking

    init(
        engines: [any SpendSenseEngine],
        ranking: SpendSenseRanking = .init()
    ) {
        self.engines = engines
        self.ranking = ranking
    }

    /// Runs every injected engine against `context`, deduplicates, ranks, and returns the result.
    /// The output never depends on the order `engines` were injected in — see `deduplicate` and
    /// `SpendSenseRanking` for why.
    func generateSignals(context: SpendSenseContext) -> [SpendSenseSignal] {
        let allSignals = engines.flatMap { $0.generateSignals(context: context) }
        let deduplicated = deduplicate(allSignals)
        return ranking.rank(deduplicated)
    }

    /// Groups signals by `deduplicationID` and keeps only the highest-ranked signal in each group
    /// (per `SpendSenseRanking.isOrderedBefore`). A dictionary is used to gather candidates per
    /// group, but its iteration order never influences the result: each group's winner is decided
    /// by direct pairwise comparison as candidates are encountered, and the final array this
    /// method returns is unordered/unstable on its own — `generateSignals` always re-ranks it
    /// afterward, so no caller ever observes dictionary order.
    private func deduplicate(_ signals: [SpendSenseSignal]) -> [SpendSenseSignal] {
        var winnerByDeduplicationID: [String: SpendSenseSignal] = [:]
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
