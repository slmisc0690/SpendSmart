import Foundation

/// Wire shape for one Manual Account, sent to `sync-manual-data`. Mirrors
/// `supabase/functions/_shared/manual.ts`'s `RawManualAccountInput` field-for-field. Carries no
/// owner identity field anywhere — the server derives ownership from the caller's own verified
/// session, never from this payload (see `sync-manual-data/index.ts`'s own header).
struct ManualAccountPayload: Encodable, Equatable {
    let id: String
    let name: String
    let account_type: String
    /// Sent as a STRING, matching this project's established money-field convention (see
    /// `PlaidBackendService`) — a JSON number would round-trip through Double and can silently
    /// corrupt exact cent values.
    let current_balance: String
    let institution_name: String?
    let last_four_digits: String?
    let shows_in_recent_activity: Bool
    let created_at: String
    let updated_at: String
}

/// Wire shape for one Manual Transaction, sent to `sync-manual-data`. Mirrors
/// `RawManualTransactionInput` field-for-field.
struct ManualTransactionPayload: Encodable, Equatable {
    let id: String
    let manual_account_id: String
    let amount: String
    let transaction_type: String
    /// A bare "YYYY-MM-DD" calendar-date string — see
    /// `ManualDataSyncPayloadBuilder.bareDateString(from:)` for why this must be the LOCAL calendar
    /// day, never an ISO8601 instant.
    let transaction_date: String
    let note: String
    let category_name: String?
    let is_pending: Bool
    let created_at: String
    let updated_at: String
}

/// Full request body for `sync-manual-data`.
struct ManualDataSyncRequest: Encodable, Equatable {
    let accounts: [ManualAccountPayload]
    let transactions: [ManualTransactionPayload]
    let deleted_account_ids: [String]
    let deleted_transaction_ids: [String]
}

/// Pure mapping from local SwiftData models to the wire payloads above — no I/O, no SwiftData
/// context access, fully unit-testable. `ManualDataCloudSyncManager` is the only caller.
enum ManualDataSyncPayloadBuilder {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isoString(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    /// Resolves `date` to its LOCAL calendar-day components (using the device's current calendar,
    /// the same calendar the app's own UI already displays this date under) and formats them as a
    /// bare "YYYY-MM-DD" string — never an ISO8601 instant. This is the exact same discipline
    /// already locked for Plaid dates (see `PlaidBackendService`'s `parseBareDate` doc comment and
    /// migration 0011's own DATE SEMANTICS comment): a `FinanceTransaction.date` is a genuine
    /// `Date` (an instant) on the Swift side, but represents a user-SELECTED CALENDAR DAY with no
    /// intrinsic meaningful time-of-day — sending it as an ISO8601 timestamp and letting the server
    /// (or a later reader) re-derive a calendar day from it is exactly the UTC-midnight-shift bug
    /// class already fixed once. Resolving to local calendar components HERE, before the value
    /// ever leaves the device, makes that entire bug class structurally impossible downstream.
    static func bareDateString(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            // Should be unreachable for any real Date/Calendar pair — Calendar always resolves
            // year/month/day for a valid Date. Falls back to the same components computed via the
            // POSIX calendar rather than crashing, so a pathological input never takes the app down.
            let fallback = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", fallback.year ?? 1970, fallback.month ?? 1, fallback.day ?? 1)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func accountPayload(for account: Account) -> ManualAccountPayload {
        ManualAccountPayload(
            id: account.id.uuidString,
            name: account.name,
            account_type: account.type.rawValue,
            current_balance: NSDecimalNumber(decimal: account.currentBalance).stringValue,
            institution_name: account.institutionName,
            last_four_digits: account.lastFourDigits,
            shows_in_recent_activity: account.showsInRecentActivity,
            created_at: isoString(from: account.createdAt),
            updated_at: isoString(from: account.updatedAt)
        )
    }

    /// `nil` if `transaction` has no local `account` relationship — a transaction must belong to
    /// an account to be synced at all (mirrors the server's own FK requirement); this should not
    /// occur in practice (every manual transaction is created against an account), but is handled
    /// as a skip rather than a crash/force-unwrap.
    static func transactionPayload(for transaction: FinanceTransaction) -> ManualTransactionPayload? {
        guard let accountId = transaction.account?.id else { return nil }
        return ManualTransactionPayload(
            id: transaction.id.uuidString,
            manual_account_id: accountId.uuidString,
            amount: NSDecimalNumber(decimal: transaction.amount).stringValue,
            transaction_type: transaction.type.rawValue,
            transaction_date: bareDateString(from: transaction.date),
            note: transaction.note,
            category_name: transaction.category?.name,
            is_pending: transaction.isPending,
            created_at: isoString(from: transaction.createdAt),
            updated_at: isoString(from: transaction.updatedAt)
        )
    }
}
