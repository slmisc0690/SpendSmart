import Foundation

/// Applies a `FinanceTransaction`'s effect to the `Account` balance(s) it touches. Each method is
/// a pure mutation on the passed-in `Account` object(s) — it does not create the `FinanceTransaction`
/// record or touch persistence; callers create/insert the transaction separately and then call the
/// matching method here so the two stay in sync.
///
/// Sign convention: `currentBalance` is positive on checking/savings/cash/other accounts when it
/// represents money the user has, and positive on a credit card when it represents money owed.
enum AccountBalanceManager {

    /// An expense increases what's owed on a credit card, or decreases what's available in any
    /// other account type.
    static func applyExpense(amount: Decimal, to account: Account) {
        switch account.type {
        case .creditCard:
            account.currentBalance += amount
        case .checking, .savings, .cash, .other:
            account.currentBalance -= amount
        }
        account.updatedAt = .now
    }

    /// A refund is the inverse of an expense: it reduces what's owed on a credit card, or
    /// increases the balance of any other account type.
    static func applyRefund(amount: Decimal, to account: Account) {
        switch account.type {
        case .creditCard:
            account.currentBalance -= amount
        case .checking, .savings, .cash, .other:
            account.currentBalance += amount
        }
        account.updatedAt = .now
    }

    /// Paying a credit card moves money out of the paying account and reduces what's owed on
    /// the card by the same amount.
    static func applyCreditCardPayment(amount: Decimal, from sourceAccount: Account, to creditCardAccount: Account) {
        sourceAccount.currentBalance -= amount
        creditCardAccount.currentBalance -= amount
        sourceAccount.updatedAt = .now
        creditCardAccount.updatedAt = .now
    }

    /// A transfer moves money out of the source account and into the destination account.
    static func applyTransfer(amount: Decimal, from sourceAccount: Account, to destinationAccount: Account) {
        sourceAccount.currentBalance -= amount
        destinationAccount.currentBalance += amount
        sourceAccount.updatedAt = .now
        destinationAccount.updatedAt = .now
    }

    /// A balance adjustment directly sets an account's balance (e.g. to correct drift from manual
    /// entry) rather than applying a delta, and never counts as spending.
    static func applyBalanceAdjustment(account: Account, newBalance: Decimal) {
        account.currentBalance = newBalance
        account.updatedAt = .now
    }

    /// Sum of `currentBalance` across non-archived accounts whose type is in `types`. Used for
    /// the Accounts screen's summary tiles (e.g. total cash, total credit card balance) — pulled
    /// out as a pure function so archiving behavior is testable without SwiftUI.
    static func totalBalance(of accounts: [Account], types: Set<AccountType>) -> Decimal {
        accounts
            .filter { types.contains($0.type) && !$0.isArchived }
            .reduce(Decimal(0)) { $0 + $1.currentBalance }
    }
}
