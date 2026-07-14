import Foundation
import SwiftData

/// Centralizes safe deletion (with account-balance reversal) for `FinanceTransaction` rows, so
/// every UI entry point — the Activity list, a Manual Account's register, Credit Card detail —
/// shares exactly one implementation rather than duplicating the reversal math per screen.
enum ManualTransactionDeletionService {

    enum Eligibility: Equatable {
        case eligible
        /// Plaid-imported transactions stay read-only through this control — they're removed
        /// only by Plaid's own sync reporting them gone (`PlaidTransactionImportService`), never
        /// by a direct user delete here.
        case blockedPlaidImport
    }

    static func eligibility(for transaction: FinanceTransaction) -> Eligibility {
        transaction.source == .plaid ? .blockedPlaidImport : .eligible
    }

    /// User-facing confirmation copy for deleting `transaction` — one fixed message per
    /// transaction type, per the approved design. `isRecurringGenerated` is accepted for
    /// forward-compatibility with a future recurring-expense-to-transaction generation feature;
    /// nothing in the app sets it today (no code path links a `FinanceTransaction` to a
    /// `RecurringExpense`), so this branch is currently unreachable but kept so the copy exists
    /// the moment that linkage is added, rather than being designed twice.
    struct ConfirmationCopy {
        let title: String
        let message: String
        let destructiveActionTitle: String
    }

    static func confirmationCopy(for transaction: FinanceTransaction, isRecurringGenerated: Bool = false) -> ConfirmationCopy {
        if isRecurringGenerated {
            return ConfirmationCopy(
                title: "Delete This Occurrence?",
                message: "This removes only this transaction. The recurring item will continue creating future entries.",
                destructiveActionTitle: "Delete Occurrence"
            )
        }
        switch transaction.type {
        case .expense:
            return ConfirmationCopy(
                title: "Delete Expense?",
                message: "This entry will be removed from the account register. If it counts toward monthly or weekly spending, those totals will also change.",
                destructiveActionTitle: "Delete Expense"
            )
        case .refund:
            return ConfirmationCopy(
                title: "Delete Refund?",
                message: "This refund will be removed from the account register and spending totals will be recalculated.",
                destructiveActionTitle: "Delete Refund"
            )
        case .balanceAdjustment:
            return ConfirmationCopy(
                title: "Delete Balance Adjustment?",
                message: "Deleting this adjustment will reverse its effect on the account balance and remove the adjustment entry.",
                destructiveActionTitle: "Delete Adjustment"
            )
        case .creditCardPayment:
            return ConfirmationCopy(
                title: "Delete Credit Card Payment?",
                message: "Deleting this payment will reverse its effect on both the payment account and the credit-card balance.",
                destructiveActionTitle: "Delete Payment"
            )
        case .income:
            return ConfirmationCopy(
                title: "Delete Deposit?",
                message: "This deposit will be removed from the account register and the balance will be adjusted.",
                destructiveActionTitle: "Delete Deposit"
            )
        case .transfer:
            // Never actually constructed anywhere in the app today — generic fallback copy kept
            // only so this function is total over every `TransactionType` case.
            return ConfirmationCopy(
                title: "Delete Entry?",
                message: "This entry will be removed and any totals it affected will be recalculated.",
                destructiveActionTitle: "Delete"
            )
        }
    }

    /// Reverses `transaction`'s effect on whatever account balance(s) it touched, defensively
    /// clears a matched-transaction relationship on both sides if one is somehow set (no live
    /// code path sets `isMatchedToManualExpense`/`matchedTransactionId` today — the "Match"
    /// review action is an unbuilt placeholder — this is future-proofing, not currently
    /// reachable), then deletes the row and saves. Returns `false` without changing anything —
    /// no balance mutation, no row deletion — if `transaction` isn't eligible (a Plaid import) or
    /// a required account relationship is missing (see `hasRequiredAccountRelationships`).
    @discardableResult
    static func delete(_ transaction: FinanceTransaction, context: ModelContext) -> Bool {
        guard eligibility(for: transaction) == .eligible else { return false }
        guard hasRequiredAccountRelationships(transaction) else { return false }

        reverseBalanceEffect(of: transaction)
        clearMatchedRelationship(of: transaction, context: context)

        context.delete(transaction)
        try? context.save()
        return true
    }

    /// Whether `transaction` has every account relationship its type's balance reversal depends
    /// on. A `.creditCardPayment` or `.transfer` missing either side would otherwise silently
    /// delete the row without reversing any balance — this guard makes that a no-op failure
    /// instead, consistent with every other precondition here (no partial state, ever).
    private static func hasRequiredAccountRelationships(_ transaction: FinanceTransaction) -> Bool {
        switch transaction.type {
        case .creditCardPayment, .transfer:
            return transaction.account != nil && transaction.transferDestinationAccount != nil
        case .expense, .refund, .balanceAdjustment:
            return true
        case .income:
            return true
        }
    }

    /// Undoes exactly what `AccountBalanceManager`'s corresponding `apply...` method did when
    /// this transaction was created — the inverse operation for each type, using only the
    /// transaction's own stored `account`/`transferDestinationAccount`/`amount` fields, never
    /// recomputed from current balances (so it's correct regardless of what's happened to the
    /// account since).
    private static func reverseBalanceEffect(of transaction: FinanceTransaction) {
        switch transaction.type {
        case .expense:
            // Undo an expense the same way a refund would: give the money back.
            if let account = transaction.account {
                AccountBalanceManager.applyRefund(amount: transaction.amount, to: account)
            }
        case .refund:
            // Undo a refund the same way an expense would: take the money back out.
            if let account = transaction.account {
                AccountBalanceManager.applyExpense(amount: transaction.amount, to: account)
            }
        case .balanceAdjustment:
            // `BalanceAdjustmentView` stores the SIGNED DELTA (newBalance - previousBalance) as
            // `amount`, not the absolute target balance — so subtracting it back out is exactly
            // correct regardless of what's happened to the account since, the same as reversing
            // any other additive transaction.
            if let account = transaction.account {
                account.currentBalance -= transaction.amount
                account.updatedAt = .now
            }
        case .creditCardPayment:
            // Inverse of `applyCreditCardPayment`: give both sides their money back.
            if let sourceAccount = transaction.account, let creditCardAccount = transaction.transferDestinationAccount {
                sourceAccount.currentBalance += transaction.amount
                creditCardAccount.currentBalance += transaction.amount
                sourceAccount.updatedAt = .now
                creditCardAccount.updatedAt = .now
            }
        case .transfer:
            // Inverse of `applyTransfer`. Never actually constructed today, but reversed
            // correctly on the chance a future screen creates one.
            if let sourceAccount = transaction.account, let destinationAccount = transaction.transferDestinationAccount {
                sourceAccount.currentBalance += transaction.amount
                destinationAccount.currentBalance -= transaction.amount
                sourceAccount.updatedAt = .now
                destinationAccount.updatedAt = .now
            }
        case .income:
            // Undo a deposit the same way an expense would: take the money back out.
            if let account = transaction.account {
                AccountBalanceManager.applyExpense(amount: transaction.amount, to: account)
            }
        }
    }

    /// Clears `isMatchedToManualExpense`/`matchedTransactionId` on both `transaction` and
    /// whichever row it's matched to (if any) before deleting `transaction` — so the counterpart
    /// is never left pointing at a now-deleted id. Never deletes the counterpart itself.
    private static func clearMatchedRelationship(of transaction: FinanceTransaction, context: ModelContext) {
        guard transaction.isMatchedToManualExpense, let matchedId = transaction.matchedTransactionId else { return }
        let descriptor = FetchDescriptor<FinanceTransaction>(predicate: #Predicate { $0.id == matchedId })
        if let counterpart = try? context.fetch(descriptor).first {
            counterpart.isMatchedToManualExpense = false
            counterpart.matchedTransactionId = nil
            counterpart.updatedAt = .now
        }
        transaction.isMatchedToManualExpense = false
        transaction.matchedTransactionId = nil
    }
}
