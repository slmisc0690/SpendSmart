import Foundation

/// Pure presentation filter for the Monthly Plan's Fixed Bills list — never mutates its input,
/// never touches `MonthlyPlanCalculator`, and never reads/writes any stored `RecurringExpense`
/// field. `timing == nil` means "All": returns `expenses` unchanged, in the same order. A non-nil
/// `timing` narrows to bills whose existing `timing` matches, preserving `expenses`' own relative
/// order (Swift's `Array.filter` never reorders).
enum FixedBillsTimingFilter {
    static func apply(_ expenses: [RecurringExpense], timing: PlanTiming?) -> [RecurringExpense] {
        guard let timing else { return expenses }
        return expenses.filter { $0.timing == timing }
    }

    /// FIXED-BILLS TOTAL CORRECTION PHASE — the exact value displayed for one bill row: the raw
    /// stored `amount`, matching `RecurringExpenseRow`'s own unconditional
    /// `PrivacyAmountView(amount: expense.amount, ...)` rendering. Deliberately NOT
    /// `MonthlyPlanCalculator.monthlyAmount(for:frequency:)` — that applies a frequency-based
    /// monthly-equivalent CONVERSION (e.g. a `.quarterly` bill's amount ÷ 3) the row itself never
    /// shows, which is exactly the "row displays one number, total contributes a different one"
    /// defect this phase corrects. The single function every Fixed Bills total in the app must
    /// route through.
    static func displayAmount(for expense: RecurringExpense) -> Decimal {
        expense.amount
    }

    /// The displayed total for `expenses` — sum of `displayAmount(for:)`, never a separate
    /// normalization/exclusion path (no frequency conversion, no one-time-due-date filtering, no
    /// re-derived activity check). `expenses` is expected to already be the exact collection
    /// rendered as rows (typically the result of `apply(_:timing:)` above) — this function adds no
    /// filtering of its own, so a row that's visible is always included here, and nothing not
    /// visible is ever silently added.
    static func displayedTotal(for expenses: [RecurringExpense]) -> Decimal {
        expenses.reduce(Decimal.zero) { $0 + displayAmount(for: $1) }
    }
}
