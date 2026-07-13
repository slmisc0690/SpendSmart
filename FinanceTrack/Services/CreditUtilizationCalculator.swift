import Foundation

/// How much of a credit card's limit is currently used. Deliberately separate from
/// `BudgetCalculator`'s weekly-budget `SpendingStatus` — utilization is about a card's balance
/// vs. its limit, not spending vs. the weekly budget, and the two must never share a threshold.
enum CreditUtilizationStatus: Equatable {
    case good
    case caution
    case high

    var label: String {
        switch self {
        case .good: return "Good"
        case .caution: return "Caution"
        case .high: return "High"
        }
    }
}

enum CreditUtilizationCalculator {
    /// 0...1 fraction of `limit` currently used. Returns 0 if there's no positive limit to divide by.
    static func utilization(balance: Decimal, limit: Decimal?) -> Double {
        guard let limit, limit > 0 else { return 0 }
        let ratio = NSDecimalNumber(decimal: balance / limit).doubleValue
        return min(max(ratio, 0), 1)
    }

    /// 0–29% good, 30–79% caution, 80%+ high.
    static func status(balance: Decimal, limit: Decimal?) -> CreditUtilizationStatus {
        let ratio = utilization(balance: balance, limit: limit)
        if ratio >= 0.80 { return .high }
        if ratio >= 0.30 { return .caution }
        return .good
    }

    /// `limit - balance`, floored at 0. Nil when there's no limit set.
    static func availableCredit(balance: Decimal, limit: Decimal?) -> Decimal? {
        guard let limit else { return nil }
        return max(limit - balance, 0)
    }
}
