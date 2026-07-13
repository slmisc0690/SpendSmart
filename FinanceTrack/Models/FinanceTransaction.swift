import Foundation
import SwiftData

/// The primary spending/money-movement record in FinanceTrack. Deliberately generic — not just
/// "expenses" — so it can represent manual entries today and Plaid-synced Amex transactions,
/// CSV imports, credit card payments, refunds, and balance adjustments later without a schema change.
@Model
final class FinanceTransaction {
    var id: UUID
    var amount: Decimal
    var date: Date
    var type: TransactionType
    var source: TransactionSource

    /// User-facing description. For manual entries (version 1) this is the transaction's name,
    /// e.g. "Trader Joe's". For a future synced transaction this may be left blank in favor of
    /// `merchantName`/`originalDescription`.
    var note: String

    /// Whether this transaction counts toward the weekly spending limit shown on the dashboard.
    /// Lets a real expense (e.g. one that will be reimbursed) be logged without skewing the budget.
    var countsTowardWeeklyBudget: Bool
    /// Whether this transaction counts toward overall monthly spending totals — independent of
    /// `countsTowardWeeklyBudget` (an expense can count toward one, both, or neither). Exists so
    /// a Manual Account used purely as a register (e.g. tracking a loan or asset) doesn't skew
    /// monthly totals just because an expense was logged against it; initialized from
    /// `Account.defaultCountsTowardMonthlySpending` at entry time, then stored independently —
    /// never recomputed from the account after that. `true` is the schema-level default so a
    /// lightweight SwiftData migration backfills every pre-existing transaction as still counting
    /// (preserving current historical totals exactly).
    var countsTowardMonthlySpending: Bool = true
    /// Whether this transaction is hidden from all spending reports/totals entirely.
    var isExcludedFromReports: Bool

    var isPending: Bool
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Reserved for future Plaid/Amex sync (always nil/false in version 1)

    /// A future Plaid `transaction_id`, used to dedupe on sync.
    var externalTransactionId: String?
    /// A future Plaid `pending_transaction_id`, used to match a pending transaction to the
    /// posted transaction that later replaces it.
    var pendingTransactionId: String?
    /// The clean merchant name a sync provider reports (e.g. "Amazon"), distinct from the raw
    /// bank description.
    var merchantName: String?
    /// The raw, unedited description a bank/sync provider reports (e.g. "AMAZON.COM*1A2B3").
    var originalDescription: String?
    /// A future Plaid `account_id`, kept separate from the local `account` relationship.
    var plaidAccountId: String?
    /// The date a card network authorized the transaction, which can precede `postedDate`.
    var authorizedDate: Date?
    /// The date the transaction posted/settled.
    var postedDate: Date?
    /// Whether this synced transaction has been matched to a pre-existing manual expense
    /// (via `TransactionMatcher`), so the manual entry isn't double-counted.
    var isMatchedToManualExpense: Bool
    /// The `id` of the `FinanceTransaction` this one has been matched to, if any.
    var matchedTransactionId: UUID?

    var account: Account?
    var category: Category?

    /// For `.transfer` and `.creditCardPayment` transactions, the account money moved *to*
    /// (`account` is the source). Nil for all other types.
    var transferDestinationAccount: Account?

    init(
        id: UUID = UUID(),
        amount: Decimal,
        date: Date = .now,
        type: TransactionType = .expense,
        source: TransactionSource = .manual,
        note: String = "",
        countsTowardWeeklyBudget: Bool = true,
        countsTowardMonthlySpending: Bool = true,
        isExcludedFromReports: Bool = false,
        isPending: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        externalTransactionId: String? = nil,
        pendingTransactionId: String? = nil,
        merchantName: String? = nil,
        originalDescription: String? = nil,
        plaidAccountId: String? = nil,
        authorizedDate: Date? = nil,
        postedDate: Date? = nil,
        isMatchedToManualExpense: Bool = false,
        matchedTransactionId: UUID? = nil,
        account: Account? = nil,
        category: Category? = nil,
        transferDestinationAccount: Account? = nil
    ) {
        self.id = id
        self.amount = amount
        self.date = date
        self.type = type
        self.source = source
        self.note = note
        self.countsTowardWeeklyBudget = countsTowardWeeklyBudget
        self.countsTowardMonthlySpending = countsTowardMonthlySpending
        self.isExcludedFromReports = isExcludedFromReports
        self.isPending = isPending
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.externalTransactionId = externalTransactionId
        self.pendingTransactionId = pendingTransactionId
        self.merchantName = merchantName
        self.originalDescription = originalDescription
        self.plaidAccountId = plaidAccountId
        self.authorizedDate = authorizedDate
        self.postedDate = postedDate
        self.isMatchedToManualExpense = isMatchedToManualExpense
        self.matchedTransactionId = matchedTransactionId
        self.account = account
        self.category = category
        self.transferDestinationAccount = transferDestinationAccount
    }

    /// The best available display name: prefers the merchant name from a future sync, then the
    /// original bank description, then falls back to the manually entered note.
    var displayName: String {
        if let merchantName, !merchantName.isEmpty { return merchantName }
        if let originalDescription, !originalDescription.isEmpty { return originalDescription }
        return note
    }
}
