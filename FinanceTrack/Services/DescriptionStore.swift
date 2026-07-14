import Foundation

/// Pure display-ordering for a description list — case-insensitive, locale-aware via
/// `localizedStandardCompare` (matching `CategorySorting`), with the string itself as the
/// deterministic tie breaker. Never mutates its input.
enum DescriptionSorting {
    static func sortedAlphabetically(_ descriptions: [String]) -> [String] {
        descriptions.sorted { lhs, rhs in
            let comparison = lhs.localizedStandardCompare(rhs)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs < rhs
        }
    }
}

/// A single global, reusable list of transaction descriptions shared across every Manual
/// Account — the user asked for "the ability to add descriptions that I can pick from," which is
/// one shared list, not a per-account copy. Persisted to `UserDefaults` as a JSON-encoded array
/// (non-sensitive UI preference data, not financial data), following the same namespaced-key,
/// injectable-`UserDefaults` pattern as `PlaidConnectionManager`/`TransactionPreferenceStore`.
struct DescriptionStore {
    private static let key = "transactionDescriptions.list.v1"

    /// Spelled exactly as supplied — never altered, reordered, or corrected here. Only used to
    /// seed a store that has never been written to.
    static let defaultDescriptions: [String] = [
        "Amex",
        "Citi Card",
        "Amazon",
        "Car Loan(Lisa)",
        "Car Loan(Scott)",
        "HELOC(JMAFCU)",
        "Water",
        "Waterscape",
        "Bestbuy",
        "Disney",
        "Xfinity",
        "AT&T",
        "Rooms2go",
        "Electric",
        "Mortgage",
        "Gas(Natural)"
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seedIfNeeded()
    }

    /// Only seeds when no value has ever been written under `key` — an existing empty array
    /// (the user deleted every description, if that ever becomes possible) is left alone rather
    /// than re-seeded, and a store that already has the defaults or any user additions is never
    /// touched again.
    private func seedIfNeeded() {
        guard defaults.object(forKey: Self.key) == nil else { return }
        persist(Self.defaultDescriptions)
    }

    /// Raw stored order — callers that need display order should sort via
    /// `DescriptionSorting.sortedAlphabetically` instead of relying on this order.
    func all() -> [String] {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Trims whitespace, rejects empty input, and rejects a case-insensitive duplicate of an
    /// existing entry — returning that existing entry's exact stored spelling instead of adding a
    /// second, differently-capitalized copy. Returns the description that should be selected
    /// (either the newly added one, or the pre-existing match), or `nil` if the trimmed input was
    /// empty.
    @discardableResult
    func add(_ description: String) -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let existing = all()
        if let match = existing.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match
        }

        persist(existing + [trimmed])
        return trimmed
    }

    private func persist(_ descriptions: [String]) {
        guard let data = try? JSONEncoder().encode(descriptions) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
