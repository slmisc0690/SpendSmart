import Foundation

/// One connected Plaid account a manually entered transaction can optionally be tagged with — via
/// `FinanceTransaction.plaidAccountId`, never `FinanceTransaction.account` (which is reserved
/// exclusively for locally created Manual Accounts; see `Account`'s own doc comment: "Reserved for
/// future bank sync. Always .manual in version 1."). Selecting one of these never makes the
/// transaction a Plaid transaction — `source` stays `.manual` — and never touches, creates, or
/// modifies any Plaid-imported row.
struct ConnectedAccountOption: Identifiable, Equatable {
    /// Plaid's own `account_id` — the same stable identifier `ActivityTabPresenter` and
    /// `PlaidConnectionManager.cachedBalances` already key by.
    let id: String
    let label: String
    /// Plaid's own `subtype` string for this account (e.g. `"savings"`, `"checking"`), unmodified —
    /// `nil` when Plaid hasn't reported one. Lets `AddExpenseView`'s Transfer To Savings "To" picker
    /// verify a Connected account is actually a savings account before offering it, the same way it
    /// already verifies a Manual Account's `AccountType`.
    let subtype: String?
}

/// Builds the list of connected accounts a manually entered transaction may reference — reads
/// only `PlaidConnectionManager`'s already-persisted `cachedBalances` (never Plaid, never an Edge
/// Function, never a network request). Deliberately independent of `ActivityTabPresenter.tabs`,
/// which only lists accounts a transaction already exists for — this lists every KNOWN connected
/// account so a brand-new manual transaction can reference one before any transaction on it
/// exists.
enum ConnectedAccountOptionPresenter {
    static func options(for connections: [PlaidConnection]) -> [ConnectedAccountOption] {
        var perAccount: [(accountId: String, institutionName: String, mask: String?, subtype: String?)] = []
        for connection in connections {
            guard let cached = connection.cachedBalances else { continue }
            for (accountId, balance) in cached {
                perAccount.append((accountId, connection.institutionName, balance.mask, balance.subtype))
            }
        }
        guard !perAccount.isEmpty else { return [] }

        let institutionNameCounts = Dictionary(grouping: perAccount.map(\.institutionName), by: { $0 }).mapValues(\.count)

        return perAccount
            .sorted { $0.accountId < $1.accountId }
            .map { entry in
                let isAmbiguous = (institutionNameCounts[entry.institutionName] ?? 0) > 1
                let label: String
                if isAmbiguous, let mask = entry.mask, !mask.isEmpty {
                    label = "\(entry.institutionName) \u{00B7}\u{00B7}\u{00B7}\(mask)"
                } else {
                    label = entry.institutionName
                }
                return ConnectedAccountOption(id: entry.accountId, label: label, subtype: entry.subtype)
            }
    }

    /// The same safe display label `options(for:)` would produce for `accountId`, resolved for
    /// a single known id — used to show "Paid With" attribution on a Manual Transaction row.
    /// `nil` for a `nil` id (no attribution) or an id no longer represented in `connections`
    /// (e.g. the connection was removed since the transaction was tagged) — never a fabricated
    /// or stale label.
    static func label(forAccountId accountId: String?, in connections: [PlaidConnection]) -> String? {
        guard let accountId else { return nil }
        return options(for: connections).first { $0.id == accountId }?.label
    }
}
