import Foundation

/// One account's contribution to a given week's spending — Amex, Wells Fargo, etc. — plus, when
/// that account is where bills get paid from, the Bill Payment Variance for whatever bill(s) were
/// actually paid from it during that specific week. Built for the Dashboard's Monthly Outlook
/// drill-down (tap Monthly Outlook → all 4 weeks at once → per-account breakdown per week), so the
/// same weekly "Actual Spent" figure `BudgetCalculator`/`MonthlyPlanCalculator` already produce can
/// be traced back to its source, instead of visiting Week 1, Week 2, etc. one at a time.
struct WeeklyAccountSpendingEntry: Identifiable, Equatable {
    /// Stable identity for `ForEach`/diffing — "manual:<uuid>" or "plaid:<accountId>", never a
    /// display name (which can repeat across institutions, e.g. two accounts both named "Amex").
    let id: String
    let manualAccountId: UUID?
    /// Resolved eagerly here (unlike `plaidAccountId`, whose label needs `[PlaidConnection]` — a
    /// UI-layer concern resolved by the view via `ConnectedAccountOptionPresenter`), since
    /// `Account.name` is a plain stored string already available on the transaction's own
    /// `account` relationship at breakdown time — no external dependency needed.
    let manualAccountName: String?
    let plaidAccountId: String?
    /// This account's share of the week's regular (non-bill) spending — expenses/refunds/transfer
    /// withdrawals/deposits eligible under the exact same rules
    /// `BudgetCalculator.weeklyActualSpending` itself uses, just grouped by account instead of
    /// summed into one total.
    let spent: Decimal
    /// Non-nil only when at least one bill payment (`linkedRecurringExpense != nil`) was dated in
    /// this week from this account — planned minus actual for just those bills, matching
    /// `MonthlyPlanCalculator.BillPaymentVarianceEntry`'s own sign convention (positive = paid
    /// less than planned, negative = paid more). `nil`, not zero, when no bill was paid from this
    /// account this week, so the UI can distinguish "no bill activity" from "paid exactly as
    /// planned."
    let billVariance: Decimal?
}

struct WeeklyOutlookBreakdown: Identifiable, Equatable {
    let weekIndex: Int
    let weekInterval: DateInterval
    let recommended: Decimal
    let actualSpent: Decimal
    let status: SpendingStatus
    let accounts: [WeeklyAccountSpendingEntry]
    var id: Int { weekIndex }
}

enum WeeklyOutlookBreakdownCalculator {
    /// Splits `month` into the same 4 canonical weeks `MonthlyPlanCalculator.summary` uses
    /// (`DateRangeHelper.fourWeekBlocks`), and for each week computes the same `actualSpent`/
    /// `status` `WeeklyPlanComparison` already shows, PLUS a per-account breakdown — never a
    /// second, independently-derived total, so this can never disagree with the numbers already
    /// on screen.
    static func breakdown(
        recurringExpenses: [RecurringExpense],
        transactions: [FinanceTransaction],
        in month: DateInterval,
        recommendedWeekly: Decimal,
        includePending: Bool,
        autoTrackedAccountIds: Set<String>,
        excludedTransactionIDs: Set<UUID>,
        warningThreshold: Double
    ) -> [WeeklyOutlookBreakdown] {
        DateRangeHelper.fourWeekBlocks(in: month).enumerated().map { index, week in
            guard let clipped = DateRangeHelper.clampedInterval(week, to: month) else {
                return WeeklyOutlookBreakdown(
                    weekIndex: index + 1, weekInterval: week, recommended: recommendedWeekly,
                    actualSpent: 0, status: .good, accounts: []
                )
            }
            let actualSpent = BudgetCalculator.weeklyActualSpending(
                transactions, in: clipped, includePending: includePending,
                autoTrackedAccountIds: autoTrackedAccountIds, excludedTransactionIDs: excludedTransactionIDs
            )
            let status = BudgetCalculator.status(spent: actualSpent, limit: recommendedWeekly, warningThreshold: warningThreshold)
            let accounts = accountBreakdown(
                recurringExpenses: recurringExpenses, transactions: transactions, in: clipped,
                includePending: includePending, autoTrackedAccountIds: autoTrackedAccountIds,
                excludedTransactionIDs: excludedTransactionIDs
            )
            return WeeklyOutlookBreakdown(
                weekIndex: index + 1, weekInterval: clipped, recommended: recommendedWeekly,
                actualSpent: actualSpent, status: status, accounts: accounts
            )
        }
    }

    /// Mirrors `BudgetCalculator`'s own manual (`spendingDelta`) and Auto-Tracked
    /// (`autoTrackedDelta`) eligibility rules exactly, grouped by account instead of summed into
    /// one total — see those functions' own headers for the authoritative rules this replicates.
    private static func accountBreakdown(
        recurringExpenses: [RecurringExpense],
        transactions: [FinanceTransaction],
        in interval: DateInterval,
        includePending: Bool,
        autoTrackedAccountIds: Set<String>,
        excludedTransactionIDs: Set<UUID>
    ) -> [WeeklyAccountSpendingEntry] {
        let eligible = excludedTransactionIDs.isEmpty
            ? transactions
            : transactions.filter { !excludedTransactionIDs.contains($0.id) }

        var spentByKey: [String: Decimal] = [:]
        var manualAccountByKey: [String: UUID] = [:]
        var manualAccountNameByKey: [String: String] = [:]
        var plaidAccountByKey: [String: String] = [:]

        // Manual side — same eligibility BudgetCalculator.spendingDelta applies
        // (countsTowardWeeklyBudget, isExcludedFromReports, pending policy, half-open interval,
        // linkedRecurringExpense excluded so bill payments are never double-counted here — they're
        // captured separately below, via Bill Payment Variance), just grouped by
        // transaction.account instead of summed into one total.
        for transaction in eligible {
            guard transaction.date >= interval.start, transaction.date < interval.end,
                  !transaction.isExcludedFromReports,
                  includePending || !transaction.isPending,
                  transaction.linkedRecurringExpense == nil,
                  transaction.countsTowardWeeklyBudget,
                  let account = transaction.account
            else { continue }
            let delta: Decimal?
            switch transaction.type {
            case .expense, .transferWithdrawal: delta = transaction.amount
            case .refund, .transferDeposit: delta = -transaction.amount
            case .income, .transfer, .creditCardPayment, .balanceAdjustment, .transferToSavings: delta = nil
            }
            guard let delta else { continue }
            let key = "manual:\(account.id.uuidString)"
            spentByKey[key, default: 0] += delta
            manualAccountByKey[key] = account.id
            manualAccountNameByKey[key] = account.name
        }

        // Auto-Tracked (connected account) side — same eligibility
        // BudgetCalculator.autoTrackedDelta applies, grouped by plaidAccountId.
        for transaction in eligible {
            guard transaction.source == .plaid,
                  let plaidAccountId = transaction.plaidAccountId, autoTrackedAccountIds.contains(plaidAccountId),
                  transaction.date >= interval.start, transaction.date < interval.end,
                  includePending || !transaction.isPending
            else { continue }
            let delta: Decimal?
            switch transaction.type {
            case .expense: delta = transaction.amount
            case .refund: delta = -transaction.amount
            case .income, .transfer, .creditCardPayment, .balanceAdjustment, .transferWithdrawal, .transferDeposit, .transferToSavings: delta = nil
            }
            guard let delta else { continue }
            let key = "plaid:\(plaidAccountId)"
            spentByKey[key, default: 0] += delta
            plaidAccountByKey[key] = plaidAccountId
        }

        // Bill Payment Variance, scoped to bills actually paid from an account DURING this
        // specific week — same matching/sign convention as
        // `MonthlyPlanCalculator.billPaymentVarianceBreakdown`, just keyed by (account, bill)
        // instead of (bill) alone, and scoped to `interval` instead of the full month.
        let billsByID = Dictionary(uniqueKeysWithValues: recurringExpenses.map { ($0.id, $0) })
        var actualPaidByAccountAndBill: [String: [UUID: Decimal]] = [:]
        for transaction in eligible {
            guard let bill = transaction.linkedRecurringExpense,
                  transaction.date >= interval.start, transaction.date < interval.end,
                  let account = transaction.account
            else { continue }
            let key = "manual:\(account.id.uuidString)"
            switch transaction.type {
            case .expense: actualPaidByAccountAndBill[key, default: [:]][bill.id, default: 0] += transaction.amount
            case .refund: actualPaidByAccountAndBill[key, default: [:]][bill.id, default: 0] -= transaction.amount
            case .income, .transfer, .creditCardPayment, .balanceAdjustment, .transferWithdrawal, .transferDeposit, .transferToSavings:
                continue
            }
            manualAccountByKey[key] = account.id
            manualAccountNameByKey[key] = account.name
        }
        var billVarianceByKey: [String: Decimal] = [:]
        for (key, paidByBill) in actualPaidByAccountAndBill {
            var totalVariance: Decimal = 0
            for (billID, actual) in paidByBill {
                guard let bill = billsByID[billID] else { continue }
                totalVariance += FixedBillsTimingFilter.displayAmount(for: bill) - actual
            }
            billVarianceByKey[key] = totalVariance
        }

        let allKeys = Set(spentByKey.keys).union(billVarianceByKey.keys)
        return allKeys.map { key in
            WeeklyAccountSpendingEntry(
                id: key,
                manualAccountId: manualAccountByKey[key],
                manualAccountName: manualAccountNameByKey[key],
                plaidAccountId: plaidAccountByKey[key],
                spent: spentByKey[key] ?? 0,
                billVariance: billVarianceByKey[key]
            )
        }.sorted { $0.spent > $1.spent }
    }
}
