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
    /// Present only when the server-side Item-sync engine's automatic post-sync `/accounts/get`
    /// balance refresh (see `_shared/itemTransactionSync.ts`) refreshed this Item's accounts since
    /// this device's last acknowledged pull — empty on most calls, exactly matching how rarely a
    /// fresh balance snapshot is actually available. `PlaidConnectionManager.pullSyncedTransactions`
    /// forwards this straight into the existing `updateCachedBalances`, the same cache every manual
    /// balance refresh already writes to — never a second, competing balance store. Defaulted to
    /// `[]` so every pre-existing call site (test or production) that predates this field keeps
    /// compiling unchanged.
    let accountBalances: [PlaidAccountBalance]
    /// The server's own snapshot instant for this response — echoed back to
    /// `PlaidBackendService.acknowledgeTransactionsSync` ONLY after this batch has actually been
    /// persisted locally (see `PlaidConnectionManager.pullSyncedTransactions`). Nil only for a
    /// test double that predates this field; `SupabasePlaidBackendService` always populates it.
    /// See `ack-transactions-sync/index.ts`'s own header for the full rationale — this is the
    /// client-confirmed-delivery fix for a real data-loss bug found 2026-09-16, where the server
    /// used to mark a batch "delivered" the instant it sent the response, whether or not the
    /// client ever actually saved it.
    let syncToken: String?

    init(
        added: [PlaidTransactionDTO],
        modified: [PlaidTransactionDTO],
        removedExternalIds: [String],
        accountBalances: [PlaidAccountBalance] = [],
        syncToken: String? = nil
    ) {
        self.added = added
        self.modified = modified
        self.removedExternalIds = removedExternalIds
        self.accountBalances = accountBalances
        self.syncToken = syncToken
    }
}
