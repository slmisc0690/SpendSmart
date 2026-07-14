import Foundation

/// Pure display-ordering for a category list — never mutates or reorders its input in place,
/// always returns a new array, and never touches `Category.transactions`, spending totals, or any
/// stored relationship.
enum CategorySorting {
    /// `categories` sorted alphabetically by `name` — case-insensitive and locale-aware via
    /// `localizedStandardCompare` (the same comparison `Finder`/`Files` use for filenames, so
    /// "iCloud" and "Icloud" sort the way a user expects). When two names compare equal, `id`
    /// (lexical `UUID` string) is the stable tie breaker, so the result never depends on the
    /// input array's original order.
    static func sortedAlphabetically(_ categories: [Category]) -> [Category] {
        categories.sorted { lhs, rhs in
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
