import Foundation

/// Computes spending totals and budget status against `BudgetSettings`. Takes date ranges from
/// `DateRangeHelper` rather than computing its own — this file is money math only.
enum BudgetCalculator {

    /// Which spending total a caller is computing — determines which per-transaction "counts
    /// toward" flag gates BOTH an `.expense` and a `.refund` row, symmetrically. A refund must be
    /// gated the same way its originating expense would be: if a purchase never raised monthly
    /// spending (because its account/transaction opted out), a refund of that same purchase must
    /// not lower monthly spending either — otherwise the total drifts negative for money that
    /// never counted in the first place. Each context's flag is independent, so a transaction can
    /// count toward weekly, monthly, both, or neither.
    enum SpendingContext {
        case weekly
        case monthly
    }

    /// Net spending for the *weekly* budget: expenses that count toward the weekly budget, minus
    /// refunds that ALSO count toward the weekly budget (a refund is gated the same way its
    /// originating expense would be — never unconditional), within `interval`. Transfers, credit
    /// card payments, balance adjustments, and income never contribute. Respects
    /// `isExcludedFromReports` and, when `includePending` is false, drops pending transactions
    /// entirely.
    static func weeklySpent(_ transactions: [FinanceTransaction], in interval: DateInterval, includePending: Bool = true) -> Decimal {
        netSpending(transactions, in: interval, includePending: includePending, context: .weekly)
    }

    /// Net spending for the *monthly* view: same rules as `weeklySpent`, except an `.expense` row
    /// is gated by `countsTowardMonthlySpending` instead of `countsTowardWeeklyBudget` — the two
    /// flags are independent, so a transaction can count toward one, both, or neither total.
    static func monthlySpent(_ transactions: [FinanceTransaction], in interval: DateInterval, includePending: Bool = true) -> Decimal {
        netSpending(transactions, in: interval, includePending: includePending, context: .monthly)
    }

    /// Driven by the same `spendingDelta` eligibility check `categoryTotals`/`accountTotals` use
    /// below, so every spend total in this file is computed from one shared per-transaction rule
    /// rather than each maintaining its own drift-prone copy of the same logic.
    private static func netSpending(
        _ transactions: [FinanceTransaction],
        in interval: DateInterval,
        includePending: Bool,
        context: SpendingContext
    ) -> Decimal {
        transactions.reduce(Decimal(0)) { total, transaction in
            total + (spendingDelta(for: transaction, in: interval, includePending: includePending, context: context) ?? 0)
        }
    }

    /// Whether `transaction` (an `.expense` or `.refund`) counts toward `context`'s total — the
    /// one place this decision is made, so every function below stays consistent. Applied
    /// symmetrically to both types: a refund is gated by the exact same flag its originating
    /// expense would have been.
    private static func countsToward(_ transaction: FinanceTransaction, context: SpendingContext) -> Bool {
        switch context {
        case .weekly: return transaction.countsTowardWeeklyBudget
        case .monthly: return transaction.countsTowardMonthlySpending
        }
    }

    static func remaining(limit: Decimal, spent: Decimal) -> Decimal {
        limit - spent
    }

    /// How much `spent` exceeds `limit` by, floored at 0 (never negative when under budget).
    static func overBudgetAmount(spent: Decimal, limit: Decimal) -> Decimal {
        max(spent - limit, 0)
    }

    static func status(spent: Decimal, limit: Decimal, warningThreshold: Double) -> SpendingStatus {
        guard limit > 0 else { return .over }
        let ratio = NSDecimalNumber(decimal: spent / limit).doubleValue
        if ratio >= 1.0 { return .over }
        if ratio >= warningThreshold { return .warning }
        return .good
    }

    static func progress(spent: Decimal, limit: Decimal) -> Double {
        guard limit > 0 else { return 1 }
        let ratio = NSDecimalNumber(decimal: spent / limit).doubleValue
        return min(max(ratio, 0), 1)
    }

    /// Whether `transaction` currently contributes to `context`'s spend total, given the
    /// `includePendingTransactions` setting. Shared by the Weekly and Monthly screens' "All
    /// Counted" filter chip — kept here so both screens' chip agrees with that screen's own ring
    /// total above, not with each other's (a transaction can be "counted" for one and not the
    /// other).
    static func isCounted(_ transaction: FinanceTransaction, includePending: Bool, context: SpendingContext) -> Bool {
        guard !transaction.isExcludedFromReports else { return false }
        guard includePending || !transaction.isPending else { return false }
        switch transaction.type {
        case .expense, .refund: return countsToward(transaction, context: context)
        case .income, .transfer, .creditCardPayment, .balanceAdjustment: return false
        }
    }

    // MARK: - Category / account breakdowns

    /// `category` is `nil` for an eligible transaction that simply has no category set — grouped
    /// under its own bucket rather than dropped, so a breakdown's sum never silently falls short
    /// of the period's overall total. Callers label the `nil` case for display (e.g.
    /// "Uncategorized"); no synthetic `Category` is ever created or persisted for this.
    struct CategoryTotal: Identifiable {
        let category: Category?
        let total: Decimal
        var id: String { category?.id.uuidString ?? "uncategorized" }
    }

    struct AccountTotal: Identifiable {
        let account: Account
        let total: Decimal
        var id: UUID { account.id }
    }

    /// Net spend per category within `interval` for `context` (expenses and refunds that BOTH
    /// count toward `context`, symmetrically), used by both the Weekly and Monthly breakdown
    /// views — each passing its own context so the breakdown always agrees with that screen's
    /// own ring total. An eligible transaction with no category is grouped under a `nil`-category
    /// bucket rather than dropped, so this breakdown's total never silently falls short of
    /// `weeklySpent`/`monthlySpent`'s own total for the same transactions.
    static func categoryTotals(_ transactions: [FinanceTransaction], in interval: DateInterval, includePending: Bool = true, context: SpendingContext) -> [CategoryTotal] {
        var totals: [UUID?: Decimal] = [:]
        var categoriesById: [UUID?: Category] = [:]

        for transaction in transactions {
            guard let delta = spendingDelta(for: transaction, in: interval, includePending: includePending, context: context) else { continue }
            let key = transaction.category?.id
            if let category = transaction.category { categoriesById[key] = category }
            totals[key, default: 0] += delta
        }

        return totals.map { key, total in
            CategoryTotal(category: categoriesById[key], total: total)
        }.sorted { $0.total > $1.total }
    }

    /// Net spend per account within `interval` for `context` (expenses and refunds that BOTH
    /// count toward `context`, symmetrically). Transactions with no account are skipped.
    static func accountTotals(_ transactions: [FinanceTransaction], in interval: DateInterval, includePending: Bool = true, context: SpendingContext) -> [AccountTotal] {
        var totals: [UUID: Decimal] = [:]
        var accountsById: [UUID: Account] = [:]

        for transaction in transactions {
            guard let delta = spendingDelta(for: transaction, in: interval, includePending: includePending, context: context) else { continue }
            guard let account = transaction.account else { continue }
            accountsById[account.id] = account
            totals[account.id, default: 0] += delta
        }

        return totals.compactMap { id, total in
            accountsById[id].map { AccountTotal(account: $0, total: total) }
        }.sorted { $0.total > $1.total }
    }

    /// This transaction's contribution to `context`'s spend total (expense = +amount, refund =
    /// -amount), or `nil` if it's out of range, excluded, pending-when-not-wanted, a non-spending
    /// type, or an expense/refund that doesn't count toward `context`.
    private static func spendingDelta(for transaction: FinanceTransaction, in interval: DateInterval, includePending: Bool, context: SpendingContext) -> Decimal? {
        guard interval.contains(transaction.date), !transaction.isExcludedFromReports else { return nil }
        guard includePending || !transaction.isPending else { return nil }
        switch transaction.type {
        case .expense: return countsToward(transaction, context: context) ? transaction.amount : nil
        case .refund: return countsToward(transaction, context: context) ? -transaction.amount : nil
        case .income, .transfer, .creditCardPayment, .balanceAdjustment: return nil
        }
    }
}
