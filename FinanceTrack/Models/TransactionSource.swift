import Foundation

/// Where a transaction originated. Version 1 only ever produces `.manual` transactions;
/// `.plaid` and `.csvImport` exist now so the schema never needs to migrate when
/// bank syncing (Plaid, including Amex-via-Plaid) is added later.
enum TransactionSource: String, Codable, CaseIterable, Identifiable {
    case manual
    case plaid
    case csvImport

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .plaid: return "Synced"
        case .csvImport: return "CSV Import"
        }
    }
}
