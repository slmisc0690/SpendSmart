import Foundation

/// The transaction-entry toggle values worth remembering between visits — everything on the Add
/// Transaction screen the user actually chooses, excluding the amount/date/note/account/category
/// (those are per-transaction, never defaults).
struct TransactionEntryPreferences: Codable, Equatable {
    var countsTowardWeeklyBudget: Bool
    var countsTowardMonthlySpending: Bool
    var isExcludedFromReports: Bool
    var isPending: Bool
}

/// Remembers the last successfully saved `TransactionEntryPreferences`, independently for every
/// (Manual Account, `TransactionType`) pair, so opening Add Transaction for the same account and
/// type starts from what the user last chose there rather than a fixed default. Backed by
/// `UserDefaults` — this is non-sensitive UI preference only, never financial data — following
/// the same namespaced-key, injectable-`UserDefaults` pattern as `PlaidConnectionManager`.
///
/// Keyed by the account's stable `UUID` and the transaction type's `rawValue` — never a display
/// name, `hashValue`, object identity, or array position, so two accounts sharing a name (or
/// renamed later) never collide or lose their independent preferences.
struct TransactionPreferenceStore {
    private static let keyPrefix = "transactionEntry.preferences.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(accountID: UUID, type: TransactionType) -> String {
        "\(Self.keyPrefix).\(accountID.uuidString).\(type.rawValue)"
    }

    /// `nil` when this account/type combination has never had a successful save — callers fall
    /// back to the screen's own existing defaults in that case.
    func preferences(accountID: UUID, type: TransactionType) -> TransactionEntryPreferences? {
        guard let data = defaults.data(forKey: key(accountID: accountID, type: type)) else { return nil }
        return try? JSONDecoder().decode(TransactionEntryPreferences.self, from: data)
    }

    /// Overwrites whatever was previously remembered for this exact account/type pair — every
    /// other (account, type) combination's stored preferences are untouched, since each lives
    /// under its own key.
    func save(_ preferences: TransactionEntryPreferences, accountID: UUID, type: TransactionType) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key(accountID: accountID, type: type))
    }

    /// The toggle values a screen should show for `(accountID, type)`: that pair's own remembered
    /// preferences if a transaction of that type has ever been successfully saved for that
    /// account, otherwise `fallback` — the one place this decision is made, so a view (or a test)
    /// never has to reimplement the fallback logic itself. `accountID == nil` (no account chosen
    /// yet) always resolves to `fallback`, since there is nothing to look up.
    func resolvedPreferences(
        accountID: UUID?,
        type: TransactionType,
        fallback: TransactionEntryPreferences
    ) -> TransactionEntryPreferences {
        if let accountID, let remembered = preferences(accountID: accountID, type: type) {
            return remembered
        }
        return fallback
    }
}
