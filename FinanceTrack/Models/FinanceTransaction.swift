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

    /// BILL PAYMENT TAGGING — set only for a Manual Account register entry that pays a specific
    /// Fixed Bill (`RecurringExpense`): automatically by Pay Bills (which already knows exactly
    /// which bill it's paying), or manually via the "Is this a Bill?" picker on a Manual Account
    /// entry ("Pay an Existing Fixed Bill" or "New Monthly Bill" — the latter creates the
    /// `RecurringExpense` first, then links to it). That bill's PLANNED amount is already
    /// subtracted once, every month, inside `MonthlyPlanCalculator.flexibleSpendingAvailable` (via
    /// Fixed Bills) — a linked transaction therefore never counts again toward Weekly/Monthly
    /// Spending (see `BudgetCalculator.spendingDelta`'s own header); only the planned-vs-actual
    /// DIFFERENCE for this bill, computed once by `MonthlyPlanCalculator.billPaymentVariance`,
    /// adjusts the monthly baseline. `nil` for every other transaction, including a plain Manual
    /// Account entry and one tagged `isOneTimeBillEntry` — neither was ever priced into Fixed
    /// Bills, so both count in full, exactly like today.
    var linkedRecurringExpense: RecurringExpense?

    /// BILL PAYMENT TAGGING — set only via the "One Time Entry" choice in a Manual Account entry's
    /// "Is this a Bill?" picker. Purely a classification label: a one-time entry was never priced
    /// into Fixed Bills (unlike `linkedRecurringExpense`), so it counts toward Weekly/Monthly
    /// Spending exactly like an ordinary, untagged Manual Account entry — this flag exists only so
    /// the user can later distinguish "an expected one-off bill" from everyday spending, never to
    /// change any money math. `false` (the schema-level default) for every pre-existing row and
    /// every transaction created any other way.
    var isOneTimeBillEntry: Bool = false

    /// BILL-TAG SIMPLIFICATION — set when the user tags a Manual Account entry as "Beginning of
    /// Month Bill" / "Mid-Month Bill" / "End of Month Bill" but the timing group couldn't be
    /// resolved to exactly one active `RecurringExpense` (zero, or more than one, sharing that
    /// timing — see `uniqueActiveBill(timing:)` in `AddExpenseView`/`TransactionBillTagEditView`).
    /// A label ONLY: unlike `linkedRecurringExpense`, this never excludes the transaction from
    /// Weekly/Monthly Spending and never feeds `billPaymentVariance` — there is no single specific
    /// bill's planned amount to compare against, so the transaction counts in full, exactly like
    /// an ordinary untagged entry. Always `nil` when `linkedRecurringExpense` is set (the two are
    /// mutually exclusive — a precise link is always preferred over a label-only tag).
    var billTiming: PlanTiming?

    /// TRANSFER TRACKING — for a `.transferWithdrawal`/`.transferDeposit` entry, the OTHER Manual
    /// Account on the far side of the transfer, when that far side is itself a Manual Account
    /// (rather than a Connected/Plaid account — see `transferCounterpartyPlaidAccountId` below).
    /// Exactly one of these two fields is ever set for a transfer entry, never both — the far side
    /// is either a Manual Account we hold a real relationship to, or a Connected account we can
    /// only reference by its stable Plaid id (same pattern `plaidAccountId` already uses as an
    /// optional "which card/account" reference tag). `nil` for every other transaction type.
    var transferCounterpartyAccount: Account?

    /// TRANSFER TRACKING — for a `.transferWithdrawal`/`.transferDeposit` entry whose far side is a
    /// Connected/Plaid account rather than a Manual Account: that account's stable Plaid
    /// `account_id`, purely a reference tag (never a local balance to mutate — Plaid balances are
    /// never locally owned). `nil` for every other transaction type, and always `nil` whenever
    /// `transferCounterpartyAccount` is set (mutually exclusive with it).
    var transferCounterpartyPlaidAccountId: String?

    /// The Supabase auth user UUID that locally owns this row on this device. `nil` for any row
    /// created before per-user local data isolation existed (or not yet backfilled) — a `nil`
    /// value must never be treated as "belongs to the current user." Optional in this phase by
    /// design (see `UserDataStoreManager`/`LegacyDataMigrator`); not yet enforced or required.
    var ownerUserID: UUID?

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
        transferDestinationAccount: Account? = nil,
        linkedRecurringExpense: RecurringExpense? = nil,
        isOneTimeBillEntry: Bool = false,
        billTiming: PlanTiming? = nil,
        transferCounterpartyAccount: Account? = nil,
        transferCounterpartyPlaidAccountId: String? = nil,
        ownerUserID: UUID? = nil
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
        self.linkedRecurringExpense = linkedRecurringExpense
        self.isOneTimeBillEntry = isOneTimeBillEntry
        self.billTiming = billTiming
        self.transferCounterpartyAccount = transferCounterpartyAccount
        self.transferCounterpartyPlaidAccountId = transferCounterpartyPlaidAccountId
        self.ownerUserID = ownerUserID
    }

    /// The best available display name: prefers the merchant name from a future sync, then the
    /// original bank description, then falls back to the manually entered note.
    var displayName: String {
        if let merchantName, !merchantName.isEmpty { return merchantName }
        if let originalDescription, !originalDescription.isEmpty { return originalDescription }
        return note
    }
}
