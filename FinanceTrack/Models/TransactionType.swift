import Foundation

/// The nature of a `FinanceTransaction`, independent of where it came from.
enum TransactionType: String, Codable, CaseIterable, Identifiable {
    case expense
    case income
    case transfer
    case creditCardPayment
    case refund
    case balanceAdjustment

    var id: String { rawValue }

    var label: String {
        switch self {
        case .expense: return "Expense"
        case .income: return "Income"
        case .transfer: return "Transfer"
        case .creditCardPayment: return "Credit Card Payment"
        case .refund: return "Refund"
        case .balanceAdjustment: return "Balance Adjustment"
        }
    }

    /// Whether this type reduces money available to spend (used for weekly/monthly totals).
    var countsAsSpending: Bool {
        switch self {
        case .expense: return true
        case .income, .transfer, .creditCardPayment, .refund, .balanceAdjustment: return false
        }
    }
}
