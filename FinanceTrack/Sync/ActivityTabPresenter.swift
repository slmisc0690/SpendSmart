import Foundation

/// One selectable activity source on the Dashboard and Activity screen — either the single
/// "Manual Transactions" bucket, or one specific connected Plaid account. Never represents an
/// institution-level grouping directly: a connection with two accounts produces two separate
/// `.connectedAccount` tabs, since transactions are reliably associated with a specific Plaid
/// `account_id` (`FinanceTransaction.plaidAccountId`), never merely an institution.
enum ActivityTab: Identifiable, Equatable, Hashable {
    case manual
    /// `id` is Plaid's own `account_id` — stable across app launches and syncs.
    case connectedAccount(id: String, label: String)

    var id: String {
        switch self {
        case .manual: return "manual"
        case .connectedAccount(let id, _): return id
        }
    }

    var label: String {
        switch self {
        case .manual: return "Manual Transactions"
        case .connectedAccount(_, let label): return label
        }
    }

    /// Equality/hashing deliberately ignore `label` — the same account must remain "the same tab"
    /// even if its cached display name changes between loads (e.g. Plaid renames an account).
    static func == (lhs: ActivityTab, rhs: ActivityTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Pure logic for building the Dashboard/Activity tab list and filtering transactions by tab —
/// kept out of any SwiftUI view so it's unit-testable without an environment. Reads only what's
/// already persisted locally (`FinanceTransaction.plaidAccountId`,
/// `PlaidConnectionManager.connections[].cachedBalances`); never fetches anything, never calls
/// Plaid or an Edge Function.
enum ActivityTabPresenter {
    /// Builds one `.connectedAccount` tab per DISTINCT Plaid `account_id` actually referenced by
    /// `transactions` — never a tab for an account no transaction actually belongs to, and never
    /// a tab for a connection with zero imported transactions. Always includes exactly one
    /// `.manual` tab, regardless of whether any manual transactions exist, so switching to it is
    /// always possible. Connected tabs are sorted by `account_id` for a stable, deterministic
    /// order across launches.
    static func tabs(transactions: [FinanceTransaction], connections: [PlaidConnection]) -> [ActivityTab] {
        let accountIds = Set(transactions.compactMap { $0.source == .plaid ? $0.plaidAccountId : nil })
        guard !accountIds.isEmpty else { return [.manual] }

        // Every known (institutionName, mask) pair for a given account_id, gathered from every
        // connection's locally cached balances — the only place this device has ever recorded an
        // account's own display name. An account_id a transaction references but that was never
        // (yet) balance-synced simply has no entry here, and falls back to neutral wording below
        // rather than a fabricated name.
        var accountInfo: [String: (institutionName: String, mask: String?)] = [:]
        for connection in connections {
            guard let cached = connection.cachedBalances else { continue }
            for (accountId, balance) in cached {
                accountInfo[accountId] = (connection.institutionName, balance.mask)
            }
        }

        let institutionNameCounts = Dictionary(
            grouping: accountIds.map { accountInfo[$0]?.institutionName ?? "Connected Account" },
            by: { $0 }
        ).mapValues(\.count)

        let connectedTabs = accountIds.sorted().map { accountId -> ActivityTab in
            let info = accountInfo[accountId]
            let institutionName = info?.institutionName ?? "Connected Account"
            // Only disambiguate when two or more VISIBLE tabs would otherwise share this exact
            // label — never appends a mask just because one happens to be available.
            let isAmbiguous = (institutionNameCounts[institutionName] ?? 0) > 1
            let label: String
            if isAmbiguous, let mask = info?.mask, !mask.isEmpty {
                label = "\(institutionName) \u{00B7}\u{00B7}\u{00B7}\(mask)"
            } else {
                label = institutionName
            }
            return .connectedAccount(id: accountId, label: label)
        }

        return connectedTabs + [.manual]
    }

    /// Every transaction belonging to `tab`.
    ///
    /// `.manual` means Dashboard-entered general spending — `source != .plaid` AND
    /// `account == nil`. The `account == nil` half is required, not optional: a transaction
    /// entered from within a Manual Account's own screen always has `account` set to that
    /// account (see `ManualAccountDetailView`/`CreditCardDetailView`, which both find "their"
    /// transactions via `$0.account?.id == account.id || $0.transferDestinationAccount?.id ==
    /// account.id`), and `transferDestinationAccount` is never set without `account` also being
    /// set (see `CreditCardPaymentView`, the only place that sets both) — so `account == nil`
    /// alone is sufficient to exclude every Manual Account transaction, transfer, and credit card
    /// payment. Without this check, a Manual Account's own transactions would leak into "Manual
    /// Transactions" — exactly the bug this filter exists to prevent. Manual Account transactions
    /// remain fully visible, just only via their own account's screen, never here.
    ///
    /// `.connectedAccount` matches only Plaid transactions whose `plaidAccountId` equals this
    /// tab's `id`. Never mixes the two.
    static func transactions(for tab: ActivityTab, in transactions: [FinanceTransaction]) -> [FinanceTransaction] {
        switch tab {
        case .manual:
            return transactions.filter { $0.source != .plaid && $0.account == nil }
        case .connectedAccount(let accountId, _):
            return transactions.filter { $0.source == .plaid && $0.plaidAccountId == accountId }
        }
    }

    /// The deterministic default selection: the first connected account if any connected activity
    /// exists (matching `tabs(transactions:connections:)`'s stable sort), otherwise Manual
    /// Transactions. Never `nil` — `tabs` always returns at least `[.manual]`.
    static func defaultTab(tabs: [ActivityTab]) -> ActivityTab {
        for tab in tabs {
            if case .connectedAccount = tab { return tab }
        }
        return .manual
    }
}
