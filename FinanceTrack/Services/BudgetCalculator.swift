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

    /// HALF-OPEN INTERVAL BOUNDARY FIX — every `DateInterval` this file is handed (week/month
    /// blocks from `DateRangeHelper`) is documented as half-open (`end` is the exclusive instant
    /// the next period begins), but `Foundation.DateInterval.contains(_:)` does NOT honor that: it
    /// treats both `start` and `end` as inclusive. Two consecutive blocks built to exactly touch
    /// (`DateRangeHelper.fourWeekBlocks(in:)` builds Week N's `end` as Week N+1's `start`) therefore
    /// let a transaction dated exactly at that shared instant match BOTH blocks via `.contains()` —
    /// a real bug that double-counted any Plaid/Amex transaction dated exactly at a week boundary
    /// (Plaid transactions are parsed to exact local midnight, so this was not a rare edge case).
    /// This is the ONE place that check happens for spend-total purposes — both `spendingDelta` and
    /// `autoTrackedDelta` route through this instead of `interval.contains(_:)` directly.
    private static func intervalContainsHalfOpen(_ interval: DateInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
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

    // MARK: - AUTO-TRACKED CONNECTED-ACCOUNT BUDGETING (read-only query layer)

    /// Manual Spending PLUS Auto-Tracked Spending (see `ActualSpendingBreakdown`'s own header for
    /// the exact definition of each) — the ONE canonical "Actual Weekly Spending" every consumer
    /// (Dashboard This Week, Weekly Budget, Monthly Plan's per-week comparisons, Week-by-Week)
    /// must read, rather than each screen computing its own combination. `autoTrackedAccountIds`
    /// is the user's current `BudgetSettings.autoCalculateConnectedAccountIds` selection, passed
    /// in by the caller (this file never touches SwiftData/`BudgetSettings` directly) — an empty
    /// set means no connected account participates, which is exactly `weeklySpent`'s own
    /// pre-existing behavior, so every caller that doesn't yet pass a real selection keeps its
    /// exact prior behavior unchanged.
    static func weeklyActualSpending(
        _ transactions: [FinanceTransaction],
        in interval: DateInterval,
        includePending: Bool = true,
        autoTrackedAccountIds: Set<String> = [],
        excludedTransactionIDs: Set<UUID> = []
    ) -> Decimal {
        weeklyActualBreakdown(transactions, in: interval, includePending: includePending, autoTrackedAccountIds: autoTrackedAccountIds, excludedTransactionIDs: excludedTransactionIDs).total
    }

    /// Same combination as `weeklyActualSpending`, for the *monthly* total — `monthlySpent`
    /// (`countsTowardMonthlySpending`) for the manual half, never `weeklySpent`'s flag.
    static func monthlyActualSpending(
        _ transactions: [FinanceTransaction],
        in interval: DateInterval,
        includePending: Bool = true,
        autoTrackedAccountIds: Set<String> = [],
        excludedTransactionIDs: Set<UUID> = []
    ) -> Decimal {
        monthlyActualBreakdown(transactions, in: interval, includePending: includePending, autoTrackedAccountIds: autoTrackedAccountIds, excludedTransactionIDs: excludedTransactionIDs).total
    }

    /// Manual Spending vs. Auto-Tracked Spending, broken out separately — lets a caller (e.g. a
    /// future Dashboard breakdown) show the two components without recomputing anything, while
    /// `weeklyActualSpending`/`monthlyActualSpending` above stay the single source every existing
    /// consumer reads for the combined total today.
    struct ActualSpendingBreakdown: Equatable {
        /// Qualifying spending entered manually through Add Expense — exactly `weeklySpent`'s/
        /// `monthlySpent`'s own pre-existing, UNCHANGED formula (`countsTowardWeeklyBudget`/
        /// `countsTowardMonthlySpending`, `isExcludedFromReports`, pending policy — all untouched).
        /// Since only manually-entered transactions have ever had those flags set to `true` (a
        /// freshly-imported Plaid transaction is always created with them `false`/`true` and
        /// nothing in this app ever flips them — see `PlaidTransactionImportService
        /// .mapToFinanceTransaction`'s own header), this naturally excludes every imported
        /// transaction without needing an explicit `source` filter.
        let manual: Decimal
        /// Qualifying imported transactions belonging to a connected account currently selected
        /// under "Auto Calculate Weekly/Monthly Based on Transactions for:" — see
        /// `autoTrackedDelta`'s own header for the exact eligibility rule. Computed ENTIRELY
        /// independently of `countsTowardWeeklyBudget`/`countsTowardMonthlySpending`/
        /// `isExcludedFromReports`, which this function never reads for the imported side — those
        /// three fields remain exactly what a user's own manual choice (or, for an imported
        /// transaction, the untouched import default) says they are, never rewritten by account
        /// selection.
        let autoTracked: Decimal
        var total: Decimal { manual + autoTracked }
    }

    static func weeklyActualBreakdown(
        _ transactions: [FinanceTransaction],
        in interval: DateInterval,
        includePending: Bool = true,
        autoTrackedAccountIds: Set<String> = [],
        excludedTransactionIDs: Set<UUID> = []
    ) -> ActualSpendingBreakdown {
        let eligible = excludeTransactions(excludedTransactionIDs, from: transactions)
        return ActualSpendingBreakdown(
            manual: weeklySpent(eligible, in: interval, includePending: includePending),
            autoTracked: autoTrackedSpending(eligible, in: interval, includePending: includePending, accountIds: autoTrackedAccountIds)
        )
    }

    static func monthlyActualBreakdown(
        _ transactions: [FinanceTransaction],
        in interval: DateInterval,
        includePending: Bool = true,
        autoTrackedAccountIds: Set<String> = [],
        excludedTransactionIDs: Set<UUID> = []
    ) -> ActualSpendingBreakdown {
        let eligible = excludeTransactions(excludedTransactionIDs, from: transactions)
        return ActualSpendingBreakdown(
            manual: monthlySpent(eligible, in: interval, includePending: includePending),
            autoTracked: autoTrackedSpending(eligible, in: interval, includePending: includePending, accountIds: autoTrackedAccountIds)
        )
    }

    /// EXCLUDE TRANSACTIONS — the FINAL budgeting filter, applied AFTER Manual/Auto-Tracked
    /// eligibility is otherwise determined (removing a transaction from the candidate set before
    /// summing produces the identical total as removing its already-computed delta afterward,
    /// since exclusion is a whole-transaction, not a partial-amount, operation — this is simply
    /// the cheaper place to do it). Keyed by `FinanceTransaction.id` — this app's own stable,
    /// already-persisted per-row identifier, present for both manually-entered and imported
    /// transactions alike (unlike Plaid's `externalTransactionId`, which is `nil` for a manual
    /// row) — never a display name, list index, or row number. An empty `excludedTransactionIDs`
    /// (the default, and the state whenever `BudgetSettings.excludeTransactionsEnabled` is off)
    /// is a true no-op: this function returns `transactions` itself, not a filtered copy, so
    /// every existing caller that hasn't been updated to pass real exclusions keeps its exact
    /// prior behavior with zero performance cost.
    private static func excludeTransactions(_ excludedTransactionIDs: Set<UUID>, from transactions: [FinanceTransaction]) -> [FinanceTransaction] {
        guard !excludedTransactionIDs.isEmpty else { return transactions }
        return transactions.filter { !excludedTransactionIDs.contains($0.id) }
    }

    private static func autoTrackedSpending(
        _ transactions: [FinanceTransaction],
        in interval: DateInterval,
        includePending: Bool,
        accountIds: Set<String>
    ) -> Decimal {
        guard !accountIds.isEmpty else { return 0 }
        return transactions.reduce(Decimal(0)) { total, transaction in
            total + (autoTrackedDelta(for: transaction, in: interval, includePending: includePending, accountIds: accountIds) ?? 0)
        }
    }

    /// This transaction's contribution to Auto-Tracked spending, or `nil` if ineligible. Eligible
    /// ONLY when ALL of: (1) `source == .plaid` (the canonical imported-transaction marker); (2)
    /// its own `plaidAccountId` — the stable Plaid `account_id`, never display name/institution/
    /// last-four — is in `accountIds`; (3) `interval.contains(transaction.date)`; (4) pending
    /// policy allows it (`includePending || !transaction.isPending`); (5) `transaction.type` is
    /// `.expense` (positive contribution) or `.refund` (negative, symmetric with how a refund
    /// reduces manual spending elsewhere in this file) — `.income`/`.transfer`/
    /// `.creditCardPayment`/`.balanceAdjustment` never contribute, exactly the same type-based
    /// exclusion `spendingDelta` below already applies to manual transactions, so a paycheck
    /// deposit or an account transfer can never be miscounted as spending merely because its
    /// account is selected for Auto Tracking.
    ///
    /// Deliberately NEVER reads `countsTowardWeeklyBudget`/`countsTowardMonthlySpending`/
    /// `isExcludedFromReports` — those are a transaction's own classification/visibility, entirely
    /// independent of whether its account happens to be selected for Auto Tracking (LOCKED RULE:
    /// visible transaction does not automatically mean budget-counted transaction, and the
    /// reverse: an Auto-Tracked transaction's `isExcludedFromReports` stays whatever it already
    /// was — usually `true`, since imported transactions are never reviewed/approved today — and
    /// this function counts it anyway, because that flag governs REPORTS visibility, not Auto
    /// Tracking budget participation).
    private static func autoTrackedDelta(
        for transaction: FinanceTransaction,
        in interval: DateInterval,
        includePending: Bool,
        accountIds: Set<String>
    ) -> Decimal? {
        guard transaction.source == .plaid else { return nil }
        guard let plaidAccountId = transaction.plaidAccountId, accountIds.contains(plaidAccountId) else { return nil }
        guard intervalContainsHalfOpen(interval, transaction.date) else { return nil }
        guard includePending || !transaction.isPending else { return nil }
        switch transaction.type {
        case .expense: return transaction.amount
        case .refund: return -transaction.amount
        // A Plaid-imported transaction is never created as a Transfer WD/Dep (those are a Manual
        // Account entry concept only — see `TransactionType.transferWithdrawal`'s own header), so
        // these two cases can never actually be hit here; excluded for the same reason `.income`/
        // `.transfer`/etc. already are.
        case .income, .transfer, .creditCardPayment, .balanceAdjustment, .transferWithdrawal, .transferDeposit:
            return nil
        }
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
        // See spendingDelta's own header — a Fixed Bill payment never counts directly.
        guard transaction.linkedRecurringExpense == nil else { return false }
        switch transaction.type {
        case .expense, .refund, .transferWithdrawal, .transferDeposit: return countsToward(transaction, context: context)
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
    /// FIXED BILL PAYMENT EXCLUSION — `transaction.linkedRecurringExpense` is set only when a
    /// Manual Account register entry pays a Fixed Bill (directly, via the "Is this a Bill?" picker,
    /// or automatically by Pay Bills — see `ManualTransactionCreationService.createExpense`'s own
    /// header). That bill's PLANNED amount is already subtracted once, every month, inside
    /// `MonthlyPlanCalculator.flexibleSpendingAvailable` (via Fixed Bills) — counting the payment
    /// AGAIN here would double-subtract the same money. Only the planned-vs-actual DIFFERENCE for
    /// that bill matters, which `MonthlyPlanCalculator.billPaymentVariance` applies separately,
    /// once, to the monthly baseline — never here, and never per-transaction. A normal Manual
    /// Account register entry (no linked bill) and an `isOneTimeBillEntry`-tagged transaction both
    /// count in full, exactly like any other manual transaction — neither was ever priced into
    /// Fixed Bills, so there is nothing to avoid double-counting.
    private static func spendingDelta(for transaction: FinanceTransaction, in interval: DateInterval, includePending: Bool, context: SpendingContext) -> Decimal? {
        guard intervalContainsHalfOpen(interval, transaction.date), !transaction.isExcludedFromReports else { return nil }
        guard includePending || !transaction.isPending else { return nil }
        guard transaction.linkedRecurringExpense == nil else { return nil }
        switch transaction.type {
        case .expense: return countsToward(transaction, context: context) ? transaction.amount : nil
        // TRANSFER TRACKING — a Transfer WD entry behaves like an expense (money leaving this
        // account); a Transfer Dep entry behaves like a refund (money arriving offsets spending).
        // Both are gated by the SAME per-entry `countsToward` flag `.expense`/`.refund` already
        // use — unlike `.income`/`.transfer` below, which never count regardless of the toggles —
        // so the user can decide, per entry, whether a given transfer should affect their totals.
        case .refund, .transferDeposit: return countsToward(transaction, context: context) ? -transaction.amount : nil
        case .transferWithdrawal: return countsToward(transaction, context: context) ? transaction.amount : nil
        case .income, .transfer, .creditCardPayment, .balanceAdjustment: return nil
        }
    }
}
