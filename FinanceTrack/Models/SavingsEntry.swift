import Foundation
import SwiftData

/// A single manually-recorded savings amount — actual money the user says they truly saved,
/// distinct from `MonthlyPlanSettings.monthlySavingsGoal` (the user's target) and
/// `MonthlyPlanCalculator.projectedMonthlySavings` (the calculator's forecast). `date` is set
/// once at creation and never edited afterward — correcting a mistake is delete-and-re-add, not
/// in-place edit (see `SavingsCalculator`/`AddSavingsEntryView`).
///
/// Local-only for this phase: no `ownerUserID`. Per-user isolation is already provided by
/// `UserDataStoreManager`'s separate `ModelContainer` per authenticated user — the same reason
/// `Category` (also purely local, never synced) has no `ownerUserID` either. `ownerUserID` only
/// exists on models that participate in cloud sync (`Account`, `FinanceTransaction`,
/// `IncomeSource`, `RecurringExpense`, `MonthlyPlanSettings`), which this is explicitly not, yet.
@Model
final class SavingsEntry {
    var id: UUID
    /// Always > 0 — enforced at every write site (`AddSavingsEntryView`), never persisted as
    /// zero or negative.
    var amount: Decimal
    /// The date this entry represents — captured once from `.now` at creation, never mutated.
    var date: Date
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        amount: Decimal,
        date: Date = .now,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.amount = amount
        self.date = date
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
