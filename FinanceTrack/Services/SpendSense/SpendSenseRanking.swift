import Foundation

/// Deterministic ordering for a collection of `SpendSenseSignal`s. An initialized value type (not a
/// namespace-only static enum) so a future caller could parameterize it if ever needed, though
/// today it takes no configuration.
///
/// Order, most-important first:
/// 1. Higher `priority`
/// 2. Higher `severity` (`important` > `headsUp` > `information` > `positive`)
/// 3. Higher `confidence` (`high` > `medium` > `limitedData`)
/// 4. More recent `relevantDate` (falling back to `evaluatedAt` when `relevantDate` is `nil`)
/// 5. Lexically smaller `id`, as a final, always-deterministic tiebreaker
///
/// Every criterion is compared explicitly in `isOrderedBefore` rather than relied on via `sort`'s
/// stability guarantee alone — this ranking is fully deterministic regardless of input order,
/// `hashValue`, or dictionary iteration order, none of which it ever reads.
struct SpendSenseRanking {
    /// Higher value ranks first. Raw `String` case order is deliberately never used for this.
    private static let severityWeight: [SpendSenseSeverity: Int] = [
        .important: 3,
        .headsUp: 2,
        .information: 1,
        .positive: 0,
    ]

    /// Higher value ranks first. Raw `String` case order is deliberately never used for this.
    private static let confidenceWeight: [SpendSenseConfidence: Int] = [
        .high: 2,
        .medium: 1,
        .limitedData: 0,
    ]

    init() {}

    func rank(_ signals: [SpendSenseSignal]) -> [SpendSenseSignal] {
        signals.sorted(by: isOrderedBefore)
    }

    /// `true` when `lhs` must rank strictly ahead of `rhs`.
    func isOrderedBefore(_ lhs: SpendSenseSignal, _ rhs: SpendSenseSignal) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }

        let lhsSeverity = Self.severityWeight[lhs.severity] ?? 0
        let rhsSeverity = Self.severityWeight[rhs.severity] ?? 0
        if lhsSeverity != rhsSeverity {
            return lhsSeverity > rhsSeverity
        }

        let lhsConfidence = Self.confidenceWeight[lhs.confidence] ?? 0
        let rhsConfidence = Self.confidenceWeight[rhs.confidence] ?? 0
        if lhsConfidence != rhsConfidence {
            return lhsConfidence > rhsConfidence
        }

        let lhsDate = lhs.relevantDate ?? lhs.evaluatedAt
        let rhsDate = rhs.relevantDate ?? rhs.evaluatedAt
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        return lhs.id < rhs.id
    }
}
