import Foundation
import SwiftData

/// Pure validation + commit logic for the Monthly Plan draft forms (`IncomeSource`,
/// `RecurringExpense`). Shared between the SwiftUI autosave flow, which debounces calls into
/// these, and unit tests, which call them directly — bypassing the debounce/UI layer entirely so
/// the "does autosave create blank records / does it double-create" rules are testable without
/// spinning up a view.
enum AutosaveCommitter {

    // MARK: - Income Source

    /// INCOME SCHEDULING PHASE: validates the Deposit Schedule fields relevant to `frequency` —
    /// see `AddEditIncomeSourceView`'s own header for exactly which fields apply to which
    /// frequency. Plain-language messages only (no jargon), matching this screen's existing
    /// convention; `Save` stays disabled whenever this returns a non-empty array.
    static func incomeSourceValidationMessages(
        name: String,
        amount: Decimal?,
        frequency: PlanFrequency,
        hasNextPayDate: Bool,
        monthlyDepositDay: MonthlyDepositDay? = nil,
        twiceMonthlyFirstDeposit: MonthlyDepositDay? = nil,
        twiceMonthlySecondDeposit: MonthlyDepositDay? = nil
    ) -> [String] {
        var messages: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            messages.append("Name is required.")
        }
        if amount == nil || (amount ?? 0) <= 0 {
            messages.append("Amount must be greater than 0.")
        }
        switch frequency {
        case .oneTime:
            if !hasNextPayDate {
                messages.append("One-time income needs a date to know which month it counts toward.")
            }
        case .weekly, .biweekly:
            if !hasNextPayDate {
                messages.append("Choose the next deposit date so future deposits can be calculated.")
            }
        case .yearly:
            if !hasNextPayDate {
                messages.append("Choose the annual deposit date.")
            }
        case .monthly:
            if monthlyDepositDay == nil {
                messages.append("Choose the day this income deposits each month.")
            }
        case .twiceMonthly:
            if twiceMonthlyFirstDeposit == nil || twiceMonthlySecondDeposit == nil {
                messages.append("Choose both monthly deposit days.")
            } else if twiceMonthlyFirstDeposit == twiceMonthlySecondDeposit {
                messages.append("The two deposit days must be different.")
            }
        case .quarterly:
            if !hasNextPayDate {
                messages.append("Choose the next deposit date so future deposits can be calculated.")
            }
        }
        return messages
    }

    /// Creates `existing` is `nil`, otherwise updates it in place. Never inserts a second record
    /// for the same draft — callers must pass the same `existing` reference back in on every
    /// subsequent commit once one has been created.
    @discardableResult
    static func commitIncomeSource(
        existing: IncomeSource?,
        name: String,
        amount: Decimal,
        frequency: PlanFrequency,
        timing: PlanTiming,
        dayOfMonth: Int?,
        nextPayDate: Date?,
        monthlyDepositDayIsLastDay: Bool = false,
        twiceMonthlyFirstDayNumber: Int? = nil,
        twiceMonthlyFirstDayIsLastDay: Bool = false,
        twiceMonthlySecondDayNumber: Int? = nil,
        twiceMonthlySecondDayIsLastDay: Bool = false,
        note: String,
        modelContext: ModelContext
    ) -> IncomeSource {
        if let existing {
            existing.name = name
            existing.amount = amount
            existing.frequency = frequency
            existing.timing = timing
            existing.dayOfMonth = dayOfMonth
            existing.nextPayDate = nextPayDate
            existing.monthlyDepositDayIsLastDay = monthlyDepositDayIsLastDay
            existing.twiceMonthlyFirstDayNumber = twiceMonthlyFirstDayNumber
            existing.twiceMonthlyFirstDayIsLastDay = twiceMonthlyFirstDayIsLastDay
            existing.twiceMonthlySecondDayNumber = twiceMonthlySecondDayNumber
            existing.twiceMonthlySecondDayIsLastDay = twiceMonthlySecondDayIsLastDay
            existing.note = note
            existing.updatedAt = .now
            return existing
        }
        let created = IncomeSource(
            name: name,
            amount: amount,
            frequency: frequency,
            timing: timing,
            dayOfMonth: dayOfMonth,
            nextPayDate: nextPayDate,
            monthlyDepositDayIsLastDay: monthlyDepositDayIsLastDay,
            twiceMonthlyFirstDayNumber: twiceMonthlyFirstDayNumber,
            twiceMonthlyFirstDayIsLastDay: twiceMonthlyFirstDayIsLastDay,
            twiceMonthlySecondDayNumber: twiceMonthlySecondDayNumber,
            twiceMonthlySecondDayIsLastDay: twiceMonthlySecondDayIsLastDay,
            note: note
        )
        modelContext.insert(created)
        return created
    }

    // MARK: - Recurring Expense

    static func recurringExpenseValidationMessages(
        name: String,
        amount: Decimal?,
        frequency: PlanFrequency,
        hasDueDate: Bool
    ) -> [String] {
        var messages: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            messages.append("Name is required.")
        }
        if amount == nil || (amount ?? 0) <= 0 {
            messages.append("Amount must be greater than 0.")
        }
        if frequency == .oneTime, !hasDueDate {
            messages.append("One-time expenses need a due date to know which month they count toward.")
        }
        return messages
    }

    @discardableResult
    static func commitRecurringExpense(
        existing: RecurringExpense?,
        name: String,
        amount: Decimal,
        category: Category?,
        frequency: PlanFrequency,
        timing: PlanTiming,
        dayOfMonth: Int?,
        dueDate: Date?,
        paymentAccount: Account?,
        isEssential: Bool,
        note: String,
        modelContext: ModelContext
    ) -> RecurringExpense {
        if let existing {
            existing.name = name
            existing.amount = amount
            existing.category = category
            existing.frequency = frequency
            existing.timing = timing
            existing.dayOfMonth = dayOfMonth
            existing.dueDate = dueDate
            existing.paymentAccount = paymentAccount
            existing.isEssential = isEssential
            existing.note = note
            existing.updatedAt = .now
            return existing
        }
        let created = RecurringExpense(
            name: name,
            amount: amount,
            category: category,
            frequency: frequency,
            timing: timing,
            dayOfMonth: dayOfMonth,
            dueDate: dueDate,
            paymentAccount: paymentAccount,
            isEssential: isEssential,
            note: note
        )
        modelContext.insert(created)
        return created
    }
}
