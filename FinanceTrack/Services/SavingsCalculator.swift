import Foundation

/// Pure money math for manually-recorded `SavingsEntry` totals — takes plain arrays and
/// `DateInterval`s as input, never touches SwiftData or persistence itself, matching
/// `BudgetCalculator`/`MonthlyPlanCalculator`'s own established convention. The single
/// authoritative implementation for both Monthly Plan's "Saved This Month" card and the
/// Dashboard's Saved This Month Quick Stat — never duplicated independently in either place.
enum SavingsCalculator {

    /// Sum of every entry whose `date` falls inside `month` — typically
    /// `DateRangeHelper.currentMonthRange()`, the same canonical month-boundary helper used
    /// everywhere else in this app.
    static func savedThisMonth(_ entries: [SavingsEntry], in month: DateInterval) -> Decimal {
        entries.reduce(Decimal(0)) { total, entry in
            month.contains(entry.date) ? total + entry.amount : total
        }
    }

    /// Sum of every entry, across all months — the per-user `@Query` this is fed already scopes
    /// results to the current user's own per-user store, so no additional filtering is needed
    /// here.
    static func totalSavingsToDate(_ entries: [SavingsEntry]) -> Decimal {
        entries.reduce(Decimal(0)) { $0 + $1.amount }
    }
}
