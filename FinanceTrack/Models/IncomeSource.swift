import Foundation
import SwiftData

/// A recurring (or one-time) source of income used to plan a month — e.g. a paycheck or VA
/// benefits. Purely for forecasting: this never creates `FinanceTransaction` records on its own.
@Model
final class IncomeSource {
    var id: UUID
    var name: String
    var amount: Decimal
    var frequency: PlanFrequency
    var timing: PlanTiming
    /// Day of the month this typically lands on (1...31), when relevant to `timing`.
    var dayOfMonth: Int?
    /// For `.oneTime` income, the specific date it's expected — required for it to count toward
    /// any particular month. For recurring income, an optional "next known payday" reference.
    var nextPayDate: Date?
    var isActive: Bool
    var note: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        frequency: PlanFrequency = .monthly,
        timing: PlanTiming = .beginningMonth,
        dayOfMonth: Int? = nil,
        nextPayDate: Date? = nil,
        isActive: Bool = true,
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.frequency = frequency
        self.timing = timing
        self.dayOfMonth = dayOfMonth
        self.nextPayDate = nextPayDate
        self.isActive = isActive
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
