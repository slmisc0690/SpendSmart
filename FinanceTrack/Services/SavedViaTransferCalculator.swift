import Foundation

/// Pure money math for the "Saved" Quick Stat — a NET total for a given month: `.transferToSavings`
/// entries add (money moving into a Savings account), and a transfer moving money OUT of a Savings
/// account subtracts (`.transferWithdrawal` sourced from a Savings account, or `.transferDeposit`
/// whose counterparty was a Savings account) — e.g. deposit $1,000 to savings then withdraw $500
/// from it the same month nets to $500 Saved. Per Scott's explicit product decision, the result
/// never goes negative (a month with only withdrawals floors at $0 rather than showing a negative
/// "Saved"). Deliberately separate from `SavingsCalculator` (which totals manually-logged
/// `SavingsEntry` rows for the existing "Saved This Month" card): these are two independent ways of
/// tracking savings, and conflating them would double-count money the user tracks both ways. Takes
/// plain arrays/sets and a `DateInterval` as input, never touches SwiftData itself, matching
/// `BudgetCalculator`/`SavingsCalculator`'s own established convention.
enum SavedViaTransferCalculator {

    /// Half-open (`>= start`, `< end`) containment — matches `BudgetCalculator`'s own convention,
    /// avoiding the double-count bug a closed interval produces for a transaction dated exactly at
    /// a month boundary (see `BudgetCalculator.intervalContainsHalfOpen`'s own header for the full
    /// history of that fix).
    private static func intervalContainsHalfOpen(_ interval: DateInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }

    /// A transfer's Manual Account leg qualifies as "Savings" the exact same way
    /// `AddExpenseView.hasSavingsAccount`/`transferToOptions` already do for the "Transfer To
    /// Savings" destination picker — never a second, diverging definition of "is this a savings
    /// account."
    private static func isSavingsAccount(_ account: Account?) -> Bool {
        account?.type == .savings
    }

    /// A transfer's Connected/Plaid leg qualifies as "Savings" via Plaid's own reported `subtype`,
    /// resolved by the caller (`savingsPlaidAccountIds`) exactly the way `ConnectedAccountOption`
    /// already resolves it for the "Transfer To Savings" destination picker — this calculator never
    /// reaches into `PlaidConnectionManager` itself, staying a plain-input pure function.
    private static func isSavingsPlaidAccount(_ accountId: String?, savingsPlaidAccountIds: Set<String>) -> Bool {
        guard let accountId else { return false }
        return savingsPlaidAccountIds.contains(accountId)
    }

    /// Net sum, for transactions dated inside `month`, of: `.transferToSavings` amounts (added),
    /// minus any `.transferWithdrawal`/`.transferDeposit` amount whose Savings-account leg is the
    /// side money left FROM (subtracted) — floored at zero (see this type's own header for why).
    /// `month` is typically `DateRangeHelper.currentMonthRange()`, the same canonical
    /// month-boundary helper used everywhere else in this app. `isExcludedFromReports` transactions
    /// are skipped, same as every other totals calculation in this app — "Exclude From Reports"
    /// always means excluded from every total, with no per-feature exception. `savingsPlaidAccountIds`
    /// (Plaid `account_id`s Plaid itself reports as `subtype == "savings"`) defaults to empty, so
    /// existing callers that haven't been updated to pass it simply never subtract a Connected
    /// Savings withdrawal — never a crash or a wrong positive total.
    static func savedThisMonth(
        _ transactions: [FinanceTransaction],
        in month: DateInterval,
        savingsPlaidAccountIds: Set<String> = []
    ) -> Decimal {
        let total = transactions.reduce(Decimal(0)) { total, transaction in
            guard !transaction.isExcludedFromReports,
                  intervalContainsHalfOpen(month, transaction.date)
            else { return total }
            switch transaction.type {
            case .transferToSavings:
                return total + transaction.amount
            case .transferWithdrawal where isSavingsAccount(transaction.account):
                return total - transaction.amount
            case .transferDeposit where isSavingsAccount(transaction.transferCounterpartyAccount)
                || isSavingsPlaidAccount(transaction.transferCounterpartyPlaidAccountId, savingsPlaidAccountIds: savingsPlaidAccountIds):
                return total - transaction.amount
            default:
                return total
            }
        }
        return max(total, 0)
    }
}
