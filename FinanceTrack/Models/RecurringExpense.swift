import Foundation
import SwiftData

/// A recurring (or one-time) fixed bill used to plan a month — e.g. rent, a car payment, or
/// insurance. Purely for forecasting: this never creates `FinanceTransaction` records or pays
/// anything on its own. `category`/`paymentAccount` are optional, unidirectional references to
/// the existing `Category`/`Account` models — no relationship changes were made to those models.
@Model
final class RecurringExpense {
    var id: UUID
    var name: String
    var amount: Decimal
    var category: Category?
    var frequency: PlanFrequency
    var timing: PlanTiming
    /// Day of the month this is typically due (1...31), when relevant to `timing`.
    var dayOfMonth: Int?
    /// For `.oneTime` expenses, the specific due date — required for it to count toward any
    /// particular month. For recurring expenses, an optional "next known due date" reference.
    var dueDate: Date?
    var paymentAccount: Account?
    /// Essential bills (rent, insurance) vs. discretionary recurring costs (a subscription) —
    /// shown in the UI as a badge; not used in the money math itself.
    var isEssential: Bool
    var isActive: Bool
    var note: String
    var createdAt: Date
    var updatedAt: Date

    /// The Supabase auth user UUID that locally owns this row on this device. `nil` for any row
    /// created before per-user local data isolation existed (or not yet backfilled) — a `nil`
    /// value must never be treated as "belongs to the current user." Optional in this phase by
    /// design (see `UserDataStoreManager`/`LegacyDataMigrator`); not yet enforced or required.
    var ownerUserID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        category: Category? = nil,
        frequency: PlanFrequency = .monthly,
        timing: PlanTiming = .beginningMonth,
        dayOfMonth: Int? = nil,
        dueDate: Date? = nil,
        paymentAccount: Account? = nil,
        isEssential: Bool = true,
        isActive: Bool = true,
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        ownerUserID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.category = category
        self.frequency = frequency
        self.timing = timing
        self.dayOfMonth = dayOfMonth
        self.dueDate = dueDate
        self.paymentAccount = paymentAccount
        self.isEssential = isEssential
        self.isActive = isActive
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ownerUserID = ownerUserID
    }
}
