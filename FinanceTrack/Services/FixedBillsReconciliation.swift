import Foundation

/// URGENT MONTHLY PLAN CALCULATION CORRECTION (Part 2) — a focused, testable per-bill diagnostic
/// for the Fixed Bills total. Mirrors `MonthlyPlanCalculator.estimatedMonthlyFixedExpenses`'s
/// exact inclusion/normalization rules (never a second, competing formula), but reports one
/// `Entry` per bill instead of only a final sum — so a mismatch between "what's displayed" and
/// "what's totaled" can be diagnosed bill-by-bill, against the REAL stored records, rather than
/// only compared as two opaque totals.
enum FixedBillsReconciliation {
    struct Entry: Identifiable {
        let id: UUID
        let name: String
        let rawAmount: Decimal
        let frequency: PlanFrequency
        let timing: PlanTiming
        let isActive: Bool
        /// The amount actually contributed to the total — `0` when excluded.
        let normalizedAmount: Decimal
        let isIncluded: Bool
        /// `nil` when included; a short, specific reason otherwise (e.g. "inactive", "one-time
        /// bill not due in this month").
        let exclusionReason: String?
    }

    /// One `Entry` per bill in `expenses`, in the same order — never filtered, so a genuinely
    /// excluded bill is still reported (with its reason) rather than silently dropped from the
    /// diagnostic itself.
    static func entries(for expenses: [RecurringExpense], in month: DateInterval) -> [Entry] {
        expenses.map { expense in
            guard expense.isActive else {
                return Entry(id: expense.id, name: expense.name, rawAmount: expense.amount, frequency: expense.frequency, timing: expense.timing, isActive: false, normalizedAmount: 0, isIncluded: false, exclusionReason: "inactive")
            }
            if expense.frequency == .oneTime {
                if let date = expense.dueDate, month.contains(date) {
                    return Entry(id: expense.id, name: expense.name, rawAmount: expense.amount, frequency: expense.frequency, timing: expense.timing, isActive: true, normalizedAmount: expense.amount, isIncluded: true, exclusionReason: nil)
                }
                let reason = expense.dueDate == nil ? "one-time bill has no due date" : "one-time bill not due in this month"
                return Entry(id: expense.id, name: expense.name, rawAmount: expense.amount, frequency: expense.frequency, timing: expense.timing, isActive: true, normalizedAmount: 0, isIncluded: false, exclusionReason: reason)
            }
            let normalized = MonthlyPlanCalculator.monthlyAmount(for: expense.amount, frequency: expense.frequency)
            return Entry(id: expense.id, name: expense.name, rawAmount: expense.amount, frequency: expense.frequency, timing: expense.timing, isActive: true, normalizedAmount: normalized, isIncluded: true, exclusionReason: nil)
        }
    }

    /// Sum of every included entry's `normalizedAmount` — must always equal
    /// `MonthlyPlanCalculator.estimatedMonthlyFixedExpenses(expenses, in: month)` exactly, since
    /// both apply the identical per-bill rule (proven by
    /// `testCorrectionsReconciliationTotalMatchesAuthoritativeFormula`).
    static func total(for expenses: [RecurringExpense], in month: DateInterval) -> Decimal {
        entries(for: expenses, in: month).filter(\.isIncluded).reduce(Decimal(0)) { $0 + $1.normalizedAmount }
    }
}
