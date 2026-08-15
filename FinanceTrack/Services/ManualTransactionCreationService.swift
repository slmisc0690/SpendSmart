import Foundation
import SwiftData

/// PAY BILLS BATCH ENTRY — the one shared authority for creating "a normal Manual Account
/// withdrawal," used by the Pay Bills batch flow (`PayBillsView`). Replicates the exact same
/// `FinanceTransaction` shape and `AccountBalanceManager` call `AddExpenseView.attemptSave()`
/// produces for a preselected-account expense (`type: .expense`, `source: .manual`, plain
/// defaults for `countsTowardWeeklyBudget`/`countsTowardMonthlySpending`/`isExcludedFromReports`/
/// `isPending`). `AddExpenseView` itself is left untouched: its existing, physically-verified-
/// working single-entry flow is not modified to route through this — this service exists purely
/// so Pay Bills' batch path never re-derives its own, potentially diverging, transaction-creation
/// logic.
///
/// OWNERSHIP CORRECTION — `ownerUserID` is assigned immediately from `account.ownerUserID`, never
/// left `nil` the way `AddExpenseView` leaves it (relying on the next app-launch/resolve
/// backfill). `account` is the authoritative source: it's the exact account this transaction
/// belongs to, and by the time a Manual Account is visible in the UI at all, at least one
/// `UserDataStoreManager.resolve(for:)` cycle has already run and backfilled it via
/// `OwnerUserIDBackfill` (backfill runs synchronously as part of the same resolve call that
/// attaches the container the UI then queries) — so `account.ownerUserID` is reliably non-nil in
/// practice, and using it costs nothing new (no additional environment dependency, no fabricated
/// UUID, no reach into an unrelated/global source). If `account.ownerUserID` is still `nil` in
/// some edge case, the created transaction simply inherits that same `nil` — identical to
/// `AddExpenseView`'s own existing safe fallback — and is picked up by the exact same backfill
/// mechanism on the next resolve, never a new/different recovery path.
enum ManualTransactionCreationService {
    /// BILL PAYMENT TAGGING — `linkedRecurringExpense` defaults to `nil` for every existing caller
    /// (an ordinary Manual Account withdrawal), but Pay Bills passes `row.bill` explicitly: it
    /// already knows exactly which `RecurringExpense` this payment is for, so it never needs the
    /// "Is this a Bill?" picker a manually-entered register transaction uses instead. See
    /// `BudgetCalculator.spendingDelta`'s own header for why a linked transaction never counts
    /// twice toward Weekly/Monthly Spending.
    @discardableResult
    static func createExpense(
        amount: Decimal,
        date: Date,
        note: String,
        account: Account,
        category: Category?,
        linkedRecurringExpense: RecurringExpense? = nil,
        context: ModelContext
    ) -> FinanceTransaction {
        let transaction = FinanceTransaction(
            amount: amount,
            date: date,
            type: .expense,
            source: .manual,
            note: note,
            account: account,
            category: category,
            linkedRecurringExpense: linkedRecurringExpense,
            ownerUserID: account.ownerUserID
        )
        context.insert(transaction)
        AccountBalanceManager.applyExpense(amount: amount, to: account)
        return transaction
    }
}
