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
        /// The single most relevant labeled amount for this account (e.g. "Balance Owed" for a
        /// credit card, "Current Balance" for checking) — `nil` when this connection has no
        /// cached balance yet for any account. Always the raw cached
        /// `CachedPlaidAccountBalance.currentBalance`, unmodified — Plaid's own `current` balance
        /// for a credit account is already the value the institution itself displays; no pending
        /// or posted transaction arithmetic is ever applied here (a prior attempt to derive a
        /// "posted-only" balance by subtracting pending charges was confirmed by live device data
        /// to double-count already-included pending authorizations and was removed).
        let primaryRow: PlaidBalanceFormatter.DisplayRow?
        let updatedAt: Date?

        init(
            id: String,
            connectionId: String,
            accountId: String?,
            institutionName: String,
            primaryRow: PlaidBalanceFormatter.DisplayRow?,
            updatedAt: Date?
        ) {
            self.id = id
            self.connectionId = connectionId
            self.accountId = accountId
            self.institutionName = institutionName
            self.primaryRow = primaryRow
            self.updatedAt = updatedAt
        }
    }

    /// Flattens every connection's cached balances into one row per known account — a connection
    /// with nothing cached yet (e.g. connected but never Manually Refreshed) still contributes one
    /// row, with `primaryRow`/`updatedAt` both `nil`, so it shows an honest
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
                        primaryRow: nil,
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
                        // Owed," never "Current Balance." Only the first (most relevant) row is
                        // shown here, matching the Dashboard's glance-only presentation.
                        primaryRow: PlaidBalanceFormatter.rows(for: asPlaidAccountBalance).first,
                        updatedAt: balance.updatedAt
                    )
                }
        }
    }
}
