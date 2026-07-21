import Foundation
import SwiftData

/// Centralizes safe deletion of a Manual `Account`. A plain `context.delete(account)` would rely
/// on `Account`'s own `@Relationship(deleteRule: .cascade, inverse: \FinanceTransaction.account)`
/// to remove that account's ordinary expense/refund/balance-adjustment rows — safe on its own,
/// but SwiftData has no matching rule for `transferDestinationAccount` (a `.creditCardPayment` or
/// `.transfer` row pointing at this account from the OTHER side), so deleting an account that
/// participates in one of those would silently nullify that reference and permanently orphan the
/// other account's balance history with no way to reverse it. This service exists to catch that
/// case and refuse before anything is touched, rather than after.
enum ManualAccountDeletionService {

    enum Eligibility: Equatable {
        case eligible
        /// A Plaid-connected account is never deletable through this manual-only flow.
        case blockedPlaidAccount
        /// `otherAccountName` is the other side of a `.creditCardPayment` this account
        /// participates in (source or destination) — nil if that account's name genuinely
        /// couldn't be resolved (never a balance, mask, description, or id).
        case blockedCreditCardPayment(otherAccountName: String?)
        /// Same as above, for a `.transfer`.
        case blockedTransfer(otherAccountName: String?)
    }

    /// `transactions` must be the full, app-wide transaction list (not just this account's own) —
    /// a cross-account reference to `account` can live on another transaction's
    /// `transferDestinationAccount`, which `Account.transactions` (the cascade-inverse
    /// relationship) never surfaces.
    static func eligibility(for account: Account, transactions: [FinanceTransaction]) -> Eligibility {
        guard account.connectionType == .manual else { return .blockedPlaidAccount }

        for transaction in transactions {
            guard transaction.type == .creditCardPayment || transaction.type == .transfer else { continue }
            let isSource = transaction.account?.id == account.id
            let isDestination = transaction.transferDestinationAccount?.id == account.id
            guard isSource || isDestination else { continue }

            let otherAccountName = isSource ? transaction.transferDestinationAccount?.name : transaction.account?.name
            switch transaction.type {
            case .creditCardPayment: return .blockedCreditCardPayment(otherAccountName: otherAccountName)
            case .transfer: return .blockedTransfer(otherAccountName: otherAccountName)
            default: continue
            }
        }
        return .eligible
    }

    /// Safe, user-facing explanation for a blocked deletion — names the relationship type and,
    /// when available, the other account's name. Never includes a balance, mask, transaction
    /// description, or id. `nil` when `eligibility` is `.eligible` (nothing to explain).
    static func blockedMessage(for eligibility: Eligibility) -> String? {
        switch eligibility {
        case .eligible:
            return nil
        case .blockedPlaidAccount:
            return "This account is connected through Plaid and can't be deleted here."
        case .blockedCreditCardPayment(let otherAccountName):
            let other = otherAccountName ?? "another account"
            return "This account is used by a credit-card payment involving \(other). Delete or reverse that payment before deleting this account."
        case .blockedTransfer(let otherAccountName):
            let other = otherAccountName ?? "another account"
            return "This account is used by a transfer involving \(other). Delete or reverse that transfer before deleting this account."
        }
    }

    /// Deletes `account` and, via SwiftData's existing cascade rule, its own ordinary
    /// expense/refund/balance-adjustment transactions. Returns `false` — no relationship touched,
    /// nothing saved — if `account` isn't eligible or the save itself throws. Never deletes Plaid
    /// Items, Plaid accounts, Plaid-imported transactions, categories, budgets, or any other
    /// account/transaction.
    ///
    /// Also records a `PendingCloudDeletion` tombstone — in the SAME save as the delete itself, so
    /// the two can never desync — when `account.ownerUserID` is set (a manual, non-Plaid account
    /// this device has already backfilled ownership for; see `PendingCloudDeletion`'s own doc
    /// comment for why this is how `ManualDataCloudSyncManager` finds out a cloud row needs
    /// removing). No tombstone is recorded for a Plaid-connected account (never eligible here
    /// anyway) or one with a still-nil `ownerUserID` (nothing was ever synced to the cloud for it).
    @discardableResult
    static func delete(_ account: Account, transactions: [FinanceTransaction], context: ModelContext) -> Bool {
        guard eligibility(for: account, transactions: transactions) == .eligible else { return false }

        if let ownerUserID = account.ownerUserID {
            context.insert(PendingCloudDeletion(entityType: .manualAccount, recordID: account.id, ownerUserID: ownerUserID))
        }
        context.delete(account)
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
