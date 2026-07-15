import Foundation
import SwiftData

/// The kind of financial account. Balance sign conventions:
/// - `.checking` / `.savings` / `.cash` / `.other`: positive balance = money you have.
/// - `.creditCard`: positive balance = money you owe.
enum AccountType: String, Codable, CaseIterable, Identifiable {
    case checking
    case savings
    case creditCard
    case cash
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Card"
        case .cash: return "Cash"
        case .other: return "Other"
        }
    }

    var systemIconName: String {
        switch self {
        case .checking: return "building.columns.fill"
        case .savings: return "banknote.fill"
        case .creditCard: return "creditcard.fill"
        case .cash: return "dollarsign.circle.fill"
        case .other: return "wallet.pass.fill"
        }
    }
}

/// A manually tracked financial account (checking, savings, credit card, cash, or other).
/// Version 1 balances are entered and updated by hand; `connectionType` and `externalIdentifier`
/// are reserved so a future Plaid-linked account can populate the same model.
@Model
final class Account {
    var id: UUID
    var name: String
    var type: AccountType
    var currentBalance: Decimal
    var institutionName: String?
    /// Last 4 digits of the card/account number, shown in the UI (e.g. "•••• 4821"). Never the full number.
    var lastFourDigits: String?
    /// For credit cards: the statement limit, used to show utilization. Nil for non-credit-card accounts.
    var creditLimit: Decimal?
    /// For credit cards: `creditLimit - currentBalance`, tracked separately since it can be reported
    /// directly by a future bank sync rather than always derived locally.
    var availableCredit: Decimal?
    /// For credit cards: the next statement due date.
    var paymentDueDate: Date?
    /// For credit cards: the minimum payment due by `paymentDueDate`.
    var minimumPayment: Decimal?
    var colorHex: String
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    /// Reserved for future bank sync. Always `.manual` in version 1.
    var connectionType: TransactionSource
    /// Reserved for a future Plaid `account_id`. Always nil in version 1.
    var externalIdentifier: String?

    /// The default `FinanceTransaction.countsTowardMonthlySpending` value for a NEW expense
    /// created against this account — nothing more. Changing this on an existing account never
    /// rewrites any prior transaction's own stored choice; each transaction keeps whatever value
    /// it was saved with forever. `true` is the schema-level default so a lightweight SwiftData
    /// migration backfills every pre-existing account as still contributing to monthly spending
    /// (preserving current totals) — `AddAccountView` explicitly overrides this to `false` for a
    /// BRAND NEW account, matching the product's register-only-first intent; only the init's own
    /// default (used by callers other than that view, e.g. tests/previews) stays `true`.
    var defaultCountsTowardMonthlySpending: Bool = true

    /// Whether this account's transactions may appear in the Dashboard's Recent Activity list —
    /// purely a display filter; never affects the account balance, spending eligibility, budget
    /// calculations, or Budget Spend Sense. `true` is the schema-level default so every
    /// pre-existing account (whose activity already appeared in Recent Activity before this
    /// setting existed) keeps that exact behavior after a lightweight SwiftData migration
    /// backfills this field, and so a brand-new account also starts visible — same pattern as
    /// `defaultCountsTowardMonthlySpending` above.
    var showsInRecentActivity: Bool = true

    @Relationship(deleteRule: .cascade, inverse: \FinanceTransaction.account)
    var transactions: [FinanceTransaction]? = []

    init(
        id: UUID = UUID(),
        name: String,
        type: AccountType,
        currentBalance: Decimal = 0,
        institutionName: String? = nil,
        lastFourDigits: String? = nil,
        creditLimit: Decimal? = nil,
        availableCredit: Decimal? = nil,
        paymentDueDate: Date? = nil,
        minimumPayment: Decimal? = nil,
        colorHex: String = "#5D9CFF",
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        connectionType: TransactionSource = .manual,
        externalIdentifier: String? = nil,
        defaultCountsTowardMonthlySpending: Bool = true,
        showsInRecentActivity: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.currentBalance = currentBalance
        self.institutionName = institutionName
        self.lastFourDigits = lastFourDigits
        self.creditLimit = creditLimit
        self.availableCredit = availableCredit
        self.paymentDueDate = paymentDueDate
        self.minimumPayment = minimumPayment
        self.colorHex = colorHex
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.connectionType = connectionType
        self.externalIdentifier = externalIdentifier
        self.defaultCountsTowardMonthlySpending = defaultCountsTowardMonthlySpending
        self.showsInRecentActivity = showsInRecentActivity
    }
}
