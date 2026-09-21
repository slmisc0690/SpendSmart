import Foundation

/// CONNECTED ACCOUNT ALIASES — a user-chosen display name for a Connected/Plaid account (e.g.
/// "Wells Fargo ····1234" → "Wells Fargo Savings") — Scott's own explicit request, after noticing
/// two Wells Fargo accounts were indistinguishable by their default institution-name-only labels.
///
/// Backed by `UserDefaults`, keyed by Plaid's own `account_id` (confirmed stable across syncs —
/// see `ConnectedAccountOptionPresenter`'s own header), never a display name, index, or position.
///
/// NOT namespaced per authenticated user (unlike `PlaidConnectionManager`'s own identical-looking
/// namespacing): `AuthenticationService.currentUserId` is `@MainActor`-isolated, and this store is
/// read from several non-view, non-actor-isolated contexts (`ConnectedAccountOptionPresenter`,
/// `ActivityTabPresenter`, `AskSpendSmartToolContext`) as a plain default-parameter value, which a
/// `@MainActor` read cannot satisfy. This is an accepted, low-stakes tradeoff — a cosmetic label
/// only, never financial data — for a household sharing the SAME physical device across two
/// signed-in accounts; each `PlaidConnectionManager` (and therefore each user's own connected
/// accounts) is already fully isolated regardless, so this can only ever affect what NAME an
/// account shows, never which account's data is shown.
struct ConnectedAccountAliasStore {
    private static let keyPrefix = "connectedAccount.alias.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(accountId: String) -> String {
        "\(Self.keyPrefix).\(accountId)"
    }

    /// The user's own alias for `accountId`, trimmed — `nil` when never set, or cleared to blank.
    func alias(forAccountId accountId: String) -> String? {
        guard let stored = defaults.string(forKey: key(accountId: accountId)) else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Sets `accountId`'s alias — a `nil` or blank (whitespace-only) value clears it back to no
    /// alias (never persists an empty string as "the alias").
    func setAlias(_ alias: String?, forAccountId accountId: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: key(accountId: accountId))
        } else {
            defaults.removeObject(forKey: key(accountId: accountId))
        }
    }

    /// The label to actually display: the user's own alias if set, else `fallback` — the ONE
    /// place this decision is made, so every call site stays consistent rather than each
    /// reimplementing the same fallback rule.
    func resolvedLabel(accountId: String, fallback: String) -> String {
        alias(forAccountId: accountId) ?? fallback
    }
}
