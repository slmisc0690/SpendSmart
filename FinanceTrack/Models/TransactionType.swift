import Foundation

/// The nature of a `FinanceTransaction`, independent of where it came from.
enum TransactionType: String, Codable, CaseIterable, Identifiable {
    case expense
    /// A manual deposit into a Manual Account — a plain positive credit, e.g. cash added to a
    /// register-tracked account. Displayed to the user as "Deposit" (see `label`); kept as
    /// `.income` at the model/rawValue level rather than adding a new case, since the two
    /// concepts are identical (money added, never spending) and this case was otherwise unused.
    case income
    case transfer
    case creditCardPayment
    case refund
    case balanceAdjustment
    /// TRANSFER TRACKING — a Manual Account register entry for money moving OUT of this account
    /// to another account (manual or connected), tracked distinctly from `.transfer` (which
    /// remains unused by any current UI) so a Manual Account entry can pick "Transfer WD"
    /// specifically. Unlike `.income`/`.transfer`, this respects the same
    /// `countsTowardWeeklyBudget`/`countsTowardMonthlySpending` toggles `.expense`/`.refund` do —
    /// see `BudgetCalculator.spendingDelta`'s own header — since the user explicitly wants to
    /// decide per-entry whether a given transfer affects their spending totals.
    case transferWithdrawal
    /// TRANSFER TRACKING — the deposit-direction counterpart to `.transferWithdrawal`: money
    /// moving INTO this account from another account (manual or connected). Also respects the
    /// per-entry Weekly/Monthly toggles, same as `.transferWithdrawal`.
    case transferDeposit
    /// SAVED-TRACKING — money moving OUT of this account into a Savings-type Manual Account,
    /// per Scott's explicit request for a dedicated, trackable "Transfer To Savings" type distinct
    /// from a plain `.transferWithdrawal`. Unlike every other transfer case, this one does NOT
    /// respect the per-entry Weekly/Monthly toggles — `BudgetCalculator.countsToward` forces both
    /// to `false` structurally, so a save can never accidentally affect Monthly Remaining or
    /// Projected Available. Feeds the Dashboard's "Saved" Quick Stat (`SavedViaTransferCalculator`)
    /// instead.
    case transferToSavings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .expense: return "Expense"
        case .income: return "Deposit"
        case .transfer: return "Transfer"
        case .creditCardPayment: return "Credit Card Payment"
        case .refund: return "Refund"
        case .balanceAdjustment: return "Balance Adjustment"
        case .transferWithdrawal: return "Transfer WD"
        case .transferDeposit: return "Transfer Dep"
        case .transferToSavings: return "Transfer To Savings"
        }
    }

    /// Whether this type reduces money available to spend (used for weekly/monthly totals).
    var countsAsSpending: Bool {
        switch self {
        case .expense: return true
        case .income, .transfer, .creditCardPayment, .refund, .balanceAdjustment,
             .transferWithdrawal, .transferDeposit, .transferToSavings:
            return false
        }
    }
}
