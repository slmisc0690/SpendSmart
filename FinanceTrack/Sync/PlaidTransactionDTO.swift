import Foundation

/// The shape of one transaction as returned by the SpendSmart backend's `sync-transactions`
/// function, which itself normalizes Plaid's `/transactions/sync` response. This struct never
/// carries a Plaid access token, client secret, or any credential — just transaction data that's
/// safe to hold on-device and display for review.
struct PlaidTransactionDTO {
    let externalTransactionId: String
    /// Plaid's `pending_transaction_id`: links a pending transaction to the posted transaction
    /// that later replaces it.
    let pendingTransactionId: String?
    let plaidAccountId: String
    let amount: Decimal
    let merchantName: String?
    let originalDescription: String
    let authorizedDate: Date?
    let postedDate: Date?
    let isPending: Bool
    /// Plaid's own category guess (e.g. "Food and Drink"), if it returned one. Mapping this to a
    /// local `Category` is left to the caller — this DTO only carries the raw guess through.
    let categoryGuess: String?
}

/// The full result of one `syncTransactions()` call — mirrors what Plaid's `/transactions/sync`
/// itself distinguishes (added vs. modified vs. removed), so `PlaidTransactionImportService` can
/// apply each category correctly instead of treating every returned transaction as brand new.
struct PlaidSyncResult {
    let added: [PlaidTransactionDTO]
    let modified: [PlaidTransactionDTO]
    /// Plaid's own `transaction_id` for each removed transaction — never a full transaction
    /// object, since Plaid's `removed` entries don't carry one.
    let removedExternalIds: [String]
}
