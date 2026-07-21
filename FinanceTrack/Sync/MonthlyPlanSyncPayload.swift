import Foundation

/// Wire shape for `MonthlyPlanSettings`, sent to `sync-monthly-plan-data`. Mirrors
/// `supabase/functions/_shared/monthlyPlan.ts`'s `RawMonthlyPlanSettingsInput` field-for-field. No
/// `id`/`owner_user_id` field — settings is a singleton keyed by the server's own verified caller
/// identity (see migration 0012's own header for why).
struct MonthlyPlanSettingsPayload: Encodable, Equatable {
    let monthly_savings_goal: String
    let buffer_amount: String?
    let auto_update_weekly_budget_from_plan: Bool
    let created_at: String
    let updated_at: String
}

/// Wire shape for one `IncomeSource`, sent to `sync-monthly-plan-data`.
struct MonthlyPlanIncomeSourcePayload: Encodable, Equatable {
    let id: String
    let name: String
    let amount: String
    let frequency: String
    let is_active: Bool
    let next_pay_date: String?
    let note: String?
    let created_at: String
    let updated_at: String
}

/// Wire shape for one `RecurringExpense`, sent to `sync-monthly-plan-data`.
struct MonthlyPlanRecurringExpensePayload: Encodable, Equatable {
    let id: String
    let name: String
    let amount: String
    let frequency: String
    let is_active: Bool
    let due_date: String?
    let is_essential: Bool
    let category_name: String?
    let note: String?
    let created_at: String
    let updated_at: String
}

/// Full request body for `sync-monthly-plan-data`.
struct MonthlyPlanSyncRequest: Encodable, Equatable {
    let settings: MonthlyPlanSettingsPayload?
    let income_sources: [MonthlyPlanIncomeSourcePayload]
    let recurring_expenses: [MonthlyPlanRecurringExpensePayload]
    let deleted_income_source_ids: [String]
    let deleted_recurring_expense_ids: [String]
}

/// Pure mapping from local SwiftData models to the wire payloads above — no I/O, no SwiftData
/// context access, fully unit-testable. Mirrors `ManualDataSyncPayloadBuilder`'s exact structure
/// (Phase 5).
enum MonthlyPlanSyncPayloadBuilder {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isoString(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    /// Resolves `date` to its LOCAL calendar-day components and formats as a bare "YYYY-MM-DD"
    /// string — identical discipline to `ManualDataSyncPayloadBuilder.bareDateString(from:)`, see
    /// that function's own doc comment for the full argument (this is the same fix already
    /// locked for Plaid dates and Manual Transaction dates, applied here to
    /// IncomeSource.nextPayDate/RecurringExpense.dueDate).
    static func bareDateString(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            let fallback = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", fallback.year ?? 1970, fallback.month ?? 1, fallback.day ?? 1)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func settingsPayload(for settings: MonthlyPlanSettings) -> MonthlyPlanSettingsPayload {
        MonthlyPlanSettingsPayload(
            monthly_savings_goal: NSDecimalNumber(decimal: settings.monthlySavingsGoal).stringValue,
            buffer_amount: settings.bufferAmount.map { NSDecimalNumber(decimal: $0).stringValue },
            auto_update_weekly_budget_from_plan: settings.autoUpdateWeeklyBudgetFromPlan,
            created_at: isoString(from: settings.createdAt),
            updated_at: isoString(from: settings.updatedAt)
        )
    }

    static func incomeSourcePayload(for source: IncomeSource) -> MonthlyPlanIncomeSourcePayload {
        MonthlyPlanIncomeSourcePayload(
            id: source.id.uuidString,
            name: source.name,
            amount: NSDecimalNumber(decimal: source.amount).stringValue,
            frequency: source.frequency.rawValue,
            is_active: source.isActive,
            next_pay_date: source.nextPayDate.map { bareDateString(from: $0) },
            note: source.note.isEmpty ? nil : source.note,
            created_at: isoString(from: source.createdAt),
            updated_at: isoString(from: source.updatedAt)
        )
    }

    static func recurringExpensePayload(for expense: RecurringExpense) -> MonthlyPlanRecurringExpensePayload {
        MonthlyPlanRecurringExpensePayload(
            id: expense.id.uuidString,
            name: expense.name,
            amount: NSDecimalNumber(decimal: expense.amount).stringValue,
            frequency: expense.frequency.rawValue,
            is_active: expense.isActive,
            due_date: expense.dueDate.map { bareDateString(from: $0) },
            is_essential: expense.isEssential,
            category_name: expense.category?.name,
            note: expense.note.isEmpty ? nil : expense.note,
            created_at: isoString(from: expense.createdAt),
            updated_at: isoString(from: expense.updatedAt)
        )
    }
}
