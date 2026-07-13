import Foundation

/// Contract for a future external transaction source (e.g. Plaid, which will also carry
/// American Express transactions). No conforming type exists yet in version 1 — this file
/// contains no networking code, no API keys, and no credentials. It exists purely so the rest
/// of the app (models, views, budget math) can be written against a stable interface now.
protocol TransactionSyncProvider {
    /// Human-readable name shown in Settings, e.g. "Plaid".
    var providerName: String { get }

    /// Whether this provider is currently linked to an account. Always `false` until a real
    /// implementation exists.
    var isConnected: Bool { get }

    /// Fetches new or updated transactions since the last sync. A real implementation would
    /// call out to the provider's API; the placeholder never does.
    func fetchLatestTransactions() async throws -> [SyncedTransaction]
}

/// A provider-agnostic transaction shape returned by `TransactionSyncProvider`, mapped into
/// a `FinanceTransaction` (with `source == .plaid`) by a future sync service.
struct SyncedTransaction {
    let externalTransactionId: String
    let amount: Decimal
    let merchantName: String
    let date: Date
    let isPending: Bool
}

enum TransactionSyncError: Error {
    case notImplemented
}
