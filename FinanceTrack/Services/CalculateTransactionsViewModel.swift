import Foundation
import Observation

/// PERFORMANCE PHASE — the verified root cause of "Calculate Transactions loads slowly" was NOT
/// a missing loading spinner: every derived value on `CalculateTransactionsView` (account
/// eligibility across every Manual + connected account, the full selection set resolved by
/// scanning ALL transactions, and a per-account selected summary that re-filtered the WHOLE
/// transaction table once per account) was a plain SwiftUI computed property — recomputed from
/// scratch on EVERY `body` evaluation, which SwiftUI triggers on every single state change,
/// including toggling ONE checkbox. For an app with a real transaction history across several
/// accounts, that is an O(accounts × allTransactions) scan PLUS an O(accounts × allTransactions)
/// summary rebuild, repeated on the very first render AND on every subsequent interaction — never
/// once.
///
/// This type moves that O(accounts × transactions) work to ONE explicit `prepare(...)` call,
/// invoked only when the underlying SwiftData query results actually change (see
/// `CalculateTransactionsView`'s own `.task(id:)`), never on a per-render or per-selection basis.
/// Everything selection-dependent afterward (Grand Total, Account Subtotal, the cross-account
/// summary) reads from the precomputed dictionaries here — O(selectedCount) or
/// O(accounts × thatAccount'sOwnTransactionCount), never O(allTransactions) again.
///
/// EXCLUDED-ONLY MODE PHASE — the same `prepare(...)` call also builds `allEligibleTransactions`
/// (every eligible account's transactions, deduplicated once) and `accountOptionIDByTransactionID`
/// (for row account labeling), so switching the "Excluded Transactions" toggle — which now swaps
/// the whole list from "this account" to "every Budget-Excluded transaction across accounts" —
/// is a cheap filter over an already-built array, never a fresh per-account flatten.
@Observable
final class CalculateTransactionsViewModel {
    private(set) var accountOptions: [CalculateTransactionsCalculator.AccountOption] = []
    /// O(1) lookup for resolving the global `Set<UUID>` selection back into real transactions —
    /// see `CalculateTransactionsCalculator.selectedTransactions(selectedIDs:transactionsByID:)`.
    private(set) var transactionsByID: [UUID: FinanceTransaction] = [:]
    /// Keyed by `AccountOption.id` — each account's own FULL (unfiltered-by-date) transaction
    /// list, computed once here instead of re-filtering the whole table per account on every
    /// render (`CalculateTransactionsCalculator.allTransactions(for:in:)`'s own per-render cost
    /// before this phase).
    private(set) var accountTransactionsByOptionID: [String: [FinanceTransaction]] = [:]
    /// EXCLUDED-ONLY MODE — every transaction belonging to ANY eligible account (manual or
    /// connected), deduplicated by `id` (a transfer's destination account can otherwise cause the
    /// same transaction to appear under two `AccountOption`s). This is the pool the "Excluded
    /// Transactions" toggle filters down to Budget-Excluded rows across every account when it
    /// overrides the selected-account filter — computed once here, never re-flattened per render.
    private(set) var allEligibleTransactions: [FinanceTransaction] = []
    /// O(1) lookup from a transaction's stable id to the `AccountOption.id` it belongs to — used
    /// only to label each row with its source account while excluded-only mode is showing
    /// transactions from multiple accounts at once (Part 6's own "identify the account" row
    /// requirement). If a transaction matches more than one option (a transfer destination), the
    /// first account encountered during `prepare(...)` wins — display-only, never affects totals.
    private(set) var accountOptionIDByTransactionID: [UUID: String] = [:]
    /// `true` until the first `prepare(...)` completes — drives the screen's brief "Loading
    /// transactions…" shell state (Part 6's own "shell first, then populate" requirement) rather
    /// than a frozen transition.
    private(set) var isPreparing = true

    #if DEBUG
    /// PERFORMANCE MEASUREMENT — DEBUG-only, never compiled into Release (matches this project's
    /// own established `DeveloperOptions`/`#if DEBUG` convention elsewhere for build-time-only
    /// diagnostics). Counts full `allTransactions`-scale scans actually performed, so a regression
    /// test can assert "a selection change triggers zero of these" without a brittle wall-clock
    /// timing assertion tied to one Mac's speed.
    private(set) var fullScanCount = 0
    #endif

    /// The ONE place the O(accounts × transactions) work happens. Call only when
    /// `allTransactions`/`manualAccounts`/`connections` themselves change — never from a
    /// selection-only state change (toggling a checkbox, switching the date filter, or flipping
    /// the Excluded Transactions toggle must never call this again).
    func prepare(manualAccounts: [Account], allTransactions: [FinanceTransaction], connections: [PlaidConnection]) {
        #if DEBUG
        fullScanCount += 1
        #endif

        var byID: [UUID: FinanceTransaction] = [:]
        byID.reserveCapacity(allTransactions.count)
        for transaction in allTransactions {
            byID[transaction.id] = transaction
        }
        transactionsByID = byID

        let options = CalculateTransactionsCalculator.accountOptions(
            manualAccounts: manualAccounts,
            transactions: allTransactions,
            connections: connections
        )
        accountOptions = options

        var byAccount: [String: [FinanceTransaction]] = [:]
        byAccount.reserveCapacity(options.count)
        var eligibleByID: [UUID: FinanceTransaction] = [:]
        var optionIDByTransactionID: [UUID: String] = [:]
        for option in options {
            let accountTransactions = CalculateTransactionsCalculator.allTransactions(for: option, in: allTransactions)
            byAccount[option.id] = accountTransactions
            for transaction in accountTransactions {
                if eligibleByID[transaction.id] == nil {
                    eligibleByID[transaction.id] = transaction
                }
                if optionIDByTransactionID[transaction.id] == nil {
                    optionIDByTransactionID[transaction.id] = option.id
                }
            }
        }
        accountTransactionsByOptionID = byAccount
        allEligibleTransactions = Array(eligibleByID.values)
        accountOptionIDByTransactionID = optionIDByTransactionID

        isPreparing = false
    }

    /// O(1) — the per-account precomputed list, or empty if this option somehow isn't indexed yet
    /// (only possible for one frame while `isPreparing` is still true).
    func transactions(forAccountOptionID accountOptionID: String) -> [FinanceTransaction] {
        accountTransactionsByOptionID[accountOptionID] ?? []
    }

    /// O(1) — the display name of the account a transaction belongs to, or `nil` if it isn't
    /// indexed (shouldn't happen for anything drawn from `allEligibleTransactions`).
    func accountDisplayName(forTransactionID transactionID: UUID) -> String? {
        guard let optionID = accountOptionIDByTransactionID[transactionID] else { return nil }
        return accountOptions.first { $0.id == optionID }?.displayName
    }

    /// O(selectedCount), never O(allTransactions) — see this type's own header.
    func selectedTransactions(selectedIDs: Set<UUID>) -> [FinanceTransaction] {
        CalculateTransactionsCalculator.selectedTransactions(selectedIDs: selectedIDs, transactionsByID: transactionsByID)
    }
}
