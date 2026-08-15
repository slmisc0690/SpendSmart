import Foundation

/// Pure mapping from `PlaidConnectionManager`'s persisted, locally cached balances to what the
/// Dashboard shows — extracted out of `DashboardView` so this logic (in particular, that it
/// reuses `PlaidBalanceFormatter`'s existing credit-card semantics and never fabricates a balance
/// for an account nothing has been cached for yet) is unit-testable without any SwiftUI or
/// environment involvement. Reads only what's already persisted; never calls Plaid, `sync-balances`,
/// `refresh-plaid-accounts`, or any Edge Function itself.
enum ConnectedAccountsDashboardPresenter {
    struct Display: Identifiable, Equatable {
        let id: String
        /// This project's own `plaid_items.id` — the connection this account belongs to. Always
        /// present, needed (alongside `accountId`) to target the Dashboard's per-account Refresh
        /// button at exactly one account via `refresh-connected-account`.
        let connectionId: String
        /// Plaid's own `account_id` for this specific account — `nil` only for the placeholder
        /// row shown when a connection has no cached balance for any account yet (nothing to
        /// refresh a *specific* account for until at least one sync has happened). Never this
        /// project's internal `plaid_accounts.id` (a server-only identifier the client has no
        /// need to know).
        let accountId: String?
        let institutionName: String
        /// Every labeled amount `PlaidBalanceFormatter` produces for this account (e.g. "Balance
        /// Owed" + "Available Credit" + "Credit Limit" for a credit card, "Available Balance" +
        /// "Current Balance" for checking) — empty when this connection has no cached balance yet
        /// for any account. Values are always the raw cached `CachedPlaidAccountBalance` fields,
        /// unmodified — Plaid's own `current`/`available` for an account are already what the
        /// institution itself displays; no pending or posted transaction arithmetic is ever
        /// applied here (a prior attempt to derive a "posted-only" balance by subtracting pending
        /// charges was confirmed by live device data to double-count already-included pending
        /// authorizations and was removed). Full parity with what Settings ▸ Connected Accounts
        /// already shows, per Scott's explicit request that the Dashboard match it.
        let rows: [PlaidBalanceFormatter.DisplayRow]
        let updatedAt: Date?

        /// Convenience for call sites that only ever cared about the single most relevant row
        /// (kept so existing "is there a balance at all" checks don't need `rows.first` everywhere).
        var primaryRow: PlaidBalanceFormatter.DisplayRow? { rows.first }

        init(
            id: String,
            connectionId: String,
            accountId: String?,
            institutionName: String,
            rows: [PlaidBalanceFormatter.DisplayRow],
            updatedAt: Date?
        ) {
            self.id = id
            self.connectionId = connectionId
            self.accountId = accountId
            self.institutionName = institutionName
            self.rows = rows
            self.updatedAt = updatedAt
        }
    }

    /// Flattens every connection's cached balances into one row per known account — a connection
    /// with nothing cached yet (e.g. connected but never Manually Refreshed) still contributes one
    /// row, with `rows` empty and `updatedAt` `nil`, so it shows an honest
    /// "Balance not refreshed yet" instead of silently disappearing from the Dashboard. Accounts
    /// within a connection are sorted by `accountId` purely for stable, deterministic ordering.
    static func displays(for connections: [PlaidConnection]) -> [Display] {
        connections.flatMap { connection -> [Display] in
            guard let cached = connection.cachedBalances, !cached.isEmpty else {
                return [
                    Display(
                        id: connection.id,
                        connectionId: connection.id,
                        accountId: nil,
                        institutionName: connection.institutionName,
                        rows: [],
                        updatedAt: nil
                    )
                ]
            }
            return cached.values
                .sorted { $0.accountId < $1.accountId }
                .map { balance in
                    let asPlaidAccountBalance = PlaidAccountBalance(
                        accountId: balance.accountId,
                        name: balance.name,
                        officialName: nil,
                        mask: balance.mask,
                        type: balance.type,
                        subtype: balance.subtype,
                        currentBalance: balance.currentBalance,
                        availableBalance: balance.availableBalance,
                        creditLimit: balance.creditLimit,
                        isoCurrencyCode: balance.isoCurrencyCode,
                        unofficialCurrencyCode: balance.unofficialCurrencyCode
                    )
                    return Display(
                        id: "\(connection.id)-\(balance.accountId)",
                        connectionId: connection.id,
                        accountId: balance.accountId,
                        institutionName: connection.institutionName,
                        // Reuses PlaidBalanceFormatter — the single existing authoritative place
                        // that already knows a credit account's positive balance means "Balance
                        // Owed," never "Current Balance." Every row it produces is shown, matching
                        // Settings ▸ Connected Accounts' full presentation.
                        rows: PlaidBalanceFormatter.rows(for: asPlaidAccountBalance),
                        updatedAt: balance.updatedAt
                    )
                }
        }
    }
}
