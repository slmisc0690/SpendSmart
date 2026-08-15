import Foundation

/// Pure money math for the "Saved" Quick Stat — sums `.transferToSavings` Manual Account register
/// entries (Checking → Savings, etc.) for a given month. Deliberately separate from
/// `SavingsCalculator` (which totals manually-logged `SavingsEntry` rows for the existing "Saved
/// This Month" card): these are two independent ways of tracking savings, and conflating them
/// would double-count money the user tracks both ways. Takes a plain array and a `DateInterval` as
/// input, never touches SwiftData itself, matching `BudgetCalculator`/`SavingsCalculator`'s own
/// established convention.
enum SavedViaTransferCalculator {

    /// Half-open (`>= start`, `< end`) containment — matches `BudgetCalculator`'s own convention,
    /// avoiding the double-count bug a closed interval produces for a transaction dated exactly at
    /// a month boundary (see `BudgetCalculator.intervalContainsHalfOpen`'s own header for the full
    /// history of that fix).
    private static func intervalContainsHalfOpen(_ interval: DateInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }

    /// Sum of every `.transferToSavings` transaction's `amount` dated inside `month` — typically
    /// `DateRangeHelper.currentMonthRange()`, the same canonical month-boundary helper used
    /// everywhere else in this app. `isExcludedFromReports` transactions are skipped, same as
    /// every other totals calculation in this app — "Exclude From Reports" always means excluded
    /// from every total, with no per-feature exception.
    static func savedThisMonth(_ transactions: [FinanceTransaction], in month: DateInterval) -> Decimal {
        transactions.reduce(Decimal(0)) { total, transaction in
            guard transaction.type == .transferToSavings,
                  !transaction.isExcludedFromReports,
                  intervalContainsHalfOpen(month, transaction.date)
            else { return total }
            return total + transaction.amount
        }
    }
}
