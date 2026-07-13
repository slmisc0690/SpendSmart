import Foundation

/// How this app buckets Plaid's own `type` string for display purposes — kept as a plain enum
/// with an explicit `.other` case, never a `switch` over the raw string directly anywhere in the
/// UI, so a Plaid account type this app has never seen (a new product line, an obscure
/// institution-specific type) degrades to neutral wording instead of crashing or mislabeling.
enum PlaidAccountKind: Equatable {
    case depository
    case credit
    case loan
    case investment
    case other

    static func classify(type: String?) -> PlaidAccountKind {
        switch type?.lowercased() {
        case "depository": return .depository
        case "credit": return .credit
        case "loan": return .loan
        case "investment": return .investment
        default: return .other
        }
    }
}

/// Turns one `PlaidAccountBalance` into the exact set of labeled amounts this app is willing to
/// show for it — the single place account-type-aware balance semantics live, so the UI layer
/// never has to reason about "is this credit card debt or cash" itself. Pure and stateless:
/// same input always produces the same output, which is what makes this independently testable
/// without any networking/SwiftUI involved.
enum PlaidBalanceFormatter {
    struct DisplayRow: Equatable {
        let label: String
        let amount: Decimal
    }

    /// - Depository (checking/savings): "Current Balance" + "Available Balance" — both represent
    ///   funds the account holder has, so the plain, familiar labels are accurate.
    /// - Credit (a card like American Express): "Balance Owed" (never "Current Balance" — the
    ///   whole point of this formatter existing is that showing a credit card's `current` under
    ///   checking-account wording is materially misleading) + "Available Credit" (Plaid's own
    ///   `available`, or `derivedAvailableCredit` as a fallback) + "Credit Limit".
    /// - Loan/investment/anything unrecognized: neutral "Balance" (never "available cash" framing
    ///   for a loan's principal), plus "Available" ONLY if Plaid actually supplied a value — never
    ///   fabricated for these types.
    ///
    /// Every row is omitted entirely when its underlying value is `nil` — this never invents a
    /// $0.00 to fill a gap.
    static func rows(for balance: PlaidAccountBalance) -> [DisplayRow] {
        switch PlaidAccountKind.classify(type: balance.type) {
        case .depository:
            return [
                balance.currentBalance.map { DisplayRow(label: "Current Balance", amount: $0) },
                balance.availableBalance.map { DisplayRow(label: "Available Balance", amount: $0) },
            ].compactMap { $0 }

        case .credit:
            var rows: [DisplayRow] = []
            if let current = balance.currentBalance {
                rows.append(DisplayRow(label: "Balance Owed", amount: current))
            }
            if let available = balance.availableBalance ?? derivedAvailableCredit(balance: balance) {
                rows.append(DisplayRow(label: "Available Credit", amount: available))
            }
            if let limit = balance.creditLimit {
                rows.append(DisplayRow(label: "Credit Limit", amount: limit))
            }
            return rows

        case .loan, .investment, .other:
            return [
                balance.currentBalance.map { DisplayRow(label: "Balance", amount: $0) },
                balance.availableBalance.map { DisplayRow(label: "Available", amount: $0) },
            ].compactMap { $0 }
        }
    }

    /// Derives available credit as `limit − current` ONLY when Plaid didn't already supply
    /// `available` AND both `current`/`limit` are present — never applied blindly. This exact
    /// formula, and the sign convention it depends on (a credit account's `current` is POSITIVE
    /// when money is owed), are both Plaid's own documented behavior for credit accounts:
    /// "a positive balance indicates the amount owed" (current) and "[available] typically equals
    /// the limit less the current balance" (https://plaid.com/docs/api/accounts/) — confirmed
    /// against Plaid's docs before implementing this, not assumed.
    static func derivedAvailableCredit(balance: PlaidAccountBalance) -> Decimal? {
        guard balance.availableBalance == nil,
              let limit = balance.creditLimit,
              let current = balance.currentBalance
        else { return nil }
        return limit - current
    }
}
