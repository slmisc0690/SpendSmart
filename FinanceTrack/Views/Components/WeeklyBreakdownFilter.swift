import Foundation

/// Display filter for the Weekly Breakdown's daily list — deliberately its own type, not a reuse
/// of `TransactionListFilter` (which the Monthly screen still uses unchanged): the two screens'
/// populations diverged once Weekly needed to separate locally entered Manual Transactions from
/// imported connected-account activity, and `TransactionListFilter`'s `.allCounted`/`.pending`/
/// `.excluded` labels no longer describe that split accurately.
enum WeeklyBreakdownFilter: String, CaseIterable, Identifiable {
    case manualTransactions = "Manual Transactions"
    case accountPending = "Account Pending"
    case accountAll = "Account All"
    var id: String { rawValue }
}
