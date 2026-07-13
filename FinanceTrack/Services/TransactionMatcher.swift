import Foundation

/// Scores how likely two transactions are the same real-world purchase — e.g. a manually entered
/// expense and a later Amex/Plaid-synced transaction for that same purchase. This exists purely as
/// matching *logic* to prepare for future bank sync: it performs no networking, calls no external
/// service, and never merges or deletes anything on its own. Callers decide what to do with the
/// candidates it returns (e.g. present them to the user for confirmation).
enum TransactionMatcher {

    struct MatchCandidate {
        let transaction: FinanceTransaction
        /// 0...1, higher means more likely to be the same transaction.
        let score: Double
    }

    /// Amounts more than this far apart are never considered a match.
    static let amountTolerance: Decimal = 0.50
    /// Dates more than this many days apart are never considered a match.
    static let maxDateDistanceDays = 3

    /// Returns `candidates` that could plausibly be the same transaction as `target`, best match
    /// first. An empty result means nothing cleared the amount/date cutoff — not necessarily that
    /// no similar transaction exists.
    static func findPossibleMatches(
        for target: FinanceTransaction,
        in candidates: [FinanceTransaction],
        calendar: Calendar = .current
    ) -> [MatchCandidate] {
        candidates
            .filter { $0.id != target.id }
            .compactMap { candidate in
                guard let score = matchScore(target, candidate, calendar: calendar) else { return nil }
                return MatchCandidate(transaction: candidate, score: score)
            }
            .sorted { $0.score > $1.score }
    }

    /// Blends amount closeness, date closeness, merchant/description similarity, category match,
    /// and account match into a single 0...1 score. Returns `nil` if the amount or date are too
    /// far apart to be worth scoring at all.
    static func matchScore(_ a: FinanceTransaction, _ b: FinanceTransaction, calendar: Calendar = .current) -> Double? {
        let amountDelta = abs(a.amount - b.amount)
        guard amountDelta <= amountTolerance else { return nil }

        let dayDistance = abs(calendar.dateComponents([.day], from: a.date, to: b.date).day ?? Int.max)
        guard dayDistance <= maxDateDistanceDays else { return nil }

        let amountScore = 1 - NSDecimalNumber(decimal: amountDelta / max(amountTolerance, 0.01)).doubleValue
        let dateScore = 1 - (Double(dayDistance) / Double(maxDateDistanceDays))
        let descriptionScore = textSimilarity(a.displayName, b.displayName)
        let categoryScore: Double = (a.category != nil && a.category?.id == b.category?.id) ? 1 : 0
        let accountScore: Double = (a.account != nil && a.account?.id == b.account?.id) ? 1 : 0

        // Amount and date carry the most weight — they're the strongest signal that two records
        // describe the same real-world charge.
        let score = (amountScore * 0.4) + (dateScore * 0.25) + (descriptionScore * 0.2) + (categoryScore * 0.1) + (accountScore * 0.05)
        return min(max(score, 0), 1)
    }

    /// Case-insensitive word-overlap similarity. Deliberately simple — good enough to bias
    /// matching toward same-merchant transactions without a text-matching dependency.
    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsWords = Set(lhs.lowercased().split(separator: " "))
        let rhsWords = Set(rhs.lowercased().split(separator: " "))
        guard !lhsWords.isEmpty, !rhsWords.isEmpty else { return 0 }
        let union = lhsWords.union(rhsWords).count
        guard union > 0 else { return 0 }
        return Double(lhsWords.intersection(rhsWords).count) / Double(union)
    }
}
