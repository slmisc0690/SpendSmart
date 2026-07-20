import Foundation
import SwiftData

/// Singleton-style settings record for the Monthly Plan feature. The app expects exactly one
/// instance; `RootView` creates a default on first launch, the same pattern as `BudgetSettings`.
@Model
final class MonthlyPlanSettings {
    var id: UUID
    var monthlySavingsGoal: Decimal
    /// Extra cushion subtracted from flexible spending before dividing into a weekly limit —
    /// optional, defaults to none.
    var bufferAmount: Decimal?
    /// Whether the Monthly Plan screen should present the recommended weekly limit as the
    /// "primary" number (display preference only; does not by itself change `BudgetSettings`).
    var useRecommendedWeeklyBudget: Bool
    /// When true, applying the Monthly Plan (or any recalculation) writes the recommended weekly
    /// limit straight into `BudgetSettings.weeklySpendingLimit`. When false (default), the user
    /// must tap "Use Recommended Weekly Limit" explicitly.
    var autoUpdateWeeklyBudgetFromPlan: Bool
    var createdAt: Date
    var updatedAt: Date

    /// The Supabase auth user UUID that locally owns this row on this device. `nil` for any row
    /// created before per-user local data isolation existed (or not yet backfilled) — a `nil`
    /// value must never be treated as "belongs to the current user." Optional in this phase by
    /// design (see `UserDataStoreManager`/`LegacyDataMigrator`); not yet enforced or required.
    var ownerUserID: UUID?

    init(
        id: UUID = UUID(),
        monthlySavingsGoal: Decimal = 0,
        bufferAmount: Decimal? = nil,
        useRecommendedWeeklyBudget: Bool = false,
        autoUpdateWeeklyBudgetFromPlan: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        ownerUserID: UUID? = nil
    ) {
        self.id = id
        self.monthlySavingsGoal = monthlySavingsGoal
        self.bufferAmount = bufferAmount
        self.useRecommendedWeeklyBudget = useRecommendedWeeklyBudget
        self.autoUpdateWeeklyBudgetFromPlan = autoUpdateWeeklyBudgetFromPlan
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ownerUserID = ownerUserID
    }
}
