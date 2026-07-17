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
        let days = Set(transactions.map { calendar.startOfDay(for: $0.date) }).sorted(by: >)
        return days.map { day in
            let rows = transactions
                .filter { calendar.isDate($0.date, inSameDayAs: day) }
                .sorted { $0.date > $1.date }
            let rawTotal = rows.reduce(Decimal(0)) { $0 + spendingDelta(for: $1) }
            return DayGroup(day: day, transactions: rows, total: max(rawTotal, 0))
        }
    }
}
