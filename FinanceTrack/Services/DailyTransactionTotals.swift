import Foundation

/// Groups a set of transactions by calendar day and sums each day's VISIBLE spending — for UI
/// sections where a date heading must equal exactly what's displayed beneath it (imported
/// connected-account activity), never a budget-eligibility total like `BudgetCalculator.
/// weeklySpent`/`monthlySpent`, which can legitimately diverge from what's on screen (imported
/// rows always have `countsTowardWeeklyBudget`/`countsTowardMonthlySpending == false`, so a
/// budget-eligibility total over them is always $0.00 regardless of how many rows are shown).
///
/// Never reads `countsTowardWeeklyBudget`/`countsTowardMonthlySpending`/`isExcludedFromReports`
/// — callers pass in exactly the rows they intend to display, already filtered, and this sums
/// exactly those. Manual Transactions keep using `BudgetCalculator` directly; this type is only
/// for populations `BudgetCalculator` was never meant to total (imported account activity).
///
/// The day `total` is a NONNEGATIVE "amount spent" figure (purchases minus refunds/credits,
/// floored at zero) — never a negative net-cash-flow number. A day showing "-$40.00" and
/// "-$12.50" individual rows (each row keeps its own existing signed display, e.g.
/// `ConnectedTransactionRow`'s "-" prefix for an expense) must read "$52.50" as its heading, not
/// "-$52.50": the heading answers "how much did I spend," and a negative heading for ordinary
/// spending reads as a bug, not a feature. A refund reduces the heading below what purchases
/// alone would produce; if credits exceed purchases for a day, the heading floors at $0.00 rather
/// than showing a negative "spent" figure (no existing SpendSmart screen displays a net-credit
/// day as negative spending — `BudgetCalculator`'s "spent" total is the only other precedent, and
/// it is never floored, but it also is never described to the user as "amount spent for this
/// specific connected account," which is what this heading represents).
enum DailyTransactionTotals {
    struct DayGroup: Identifiable {
        let day: Date
        let transactions: [FinanceTransaction]
        let total: Decimal
        var id: Date { day }
    }

    /// This transaction's contribution to a day's SPENDING total — a purchase (`.expense`) adds
    /// to spending, a refund/credit (`.refund`/`.income`) reduces it; everything else
    /// (transfer/creditCardPayment/balanceAdjustment) contributes zero. Note this is the OPPOSITE
    /// sign convention from each row's own individual display (`ConnectedTransactionRow` shows an
    /// expense as "-$X.XX") — that row-level convention is unchanged; this is purely the
    /// heading-total accumulator, which answers "how much was spent," not "what was the net cash
    /// flow."
    static func spendingDelta(for transaction: FinanceTransaction) -> Decimal {
        switch transaction.type {
        case .expense: return transaction.amount
        case .refund, .income: return -transaction.amount
        case .transfer, .creditCardPayment, .balanceAdjustment: return 0
        }
    }

    /// Groups `transactions` by calendar day (newest first); each day's `total` is the exact sum
    /// of `spendingDelta` for that day's own rows, floored at zero, so it can never disagree with
    /// what's displayed underneath it and never shows a negative sign for ordinary spending.
    static func groups(for transactions: [FinanceTransaction], calendar: Calendar = .current) -> [DayGroup] {
        genericGroups(for: transactions, calendar: calendar, date: { $0.date }, delta: spendingDelta)
            .map { DayGroup(day: $0.day, transactions: $0.items, total: $0.total) }
    }

    /// One day's worth of items grouped by `genericGroups`, generic over any read-only
    /// presentation type — never `FinanceTransaction`-specific, so this can group Primary-shared
    /// Activity entries (which must never become `FinanceTransaction`/touch SwiftData) using the
    /// exact same day-bucketing/flooring rules as owned connected-account activity above.
    struct GenericDayGroup<T>: Identifiable {
        let day: Date
        let items: [T]
        let total: Decimal
        var id: Date { day }
    }

    /// Same day-bucketing/summing/flooring logic as `groups(for:calendar:)`, generalized via
    /// caller-supplied `date`/`delta` accessors instead of hardcoding `FinanceTransaction.date`/
    /// `spendingDelta(for:)` — `groups(for:calendar:)` itself now just calls this with those two
    /// accessors, so owned behavior/output is unchanged (same sort, same flooring at zero).
    static func genericGroups<T>(
        for items: [T],
        calendar: Calendar = .current,
        date: (T) -> Date,
        delta: (T) -> Decimal
    ) -> [GenericDayGroup<T>] {
        let days = Set(items.map { calendar.startOfDay(for: date($0)) }).sorted(by: >)
        return days.map { day in
            let rows = items
                .filter { calendar.isDate(date($0), inSameDayAs: day) }
                .sorted { date($0) > date($1) }
            let rawTotal = rows.reduce(Decimal(0)) { $0 + delta($1) }
            return GenericDayGroup(day: day, items: rows, total: max(rawTotal, 0))
        }
    }
}
