import Foundation
import SwiftData

/// Which of the two directly-synced fields (`weeklySpendingLimit`/`monthlyGoal`) the user most
/// recently, explicitly edited — drives which explanatory message `SettingsView` shows under
/// Weekly Spending Limit. `nil` means neither has ever been edited through the synced path
/// (e.g. an existing user's settings from before this sync existed).
enum WeeklyMonthlySyncSource: String, Codable {
    case weekly
    case monthly
}

/// Singleton-style settings record for the user's budget configuration.
/// The app expects exactly one `BudgetSettings` instance; a default is created on first launch
/// by `RootView` in `FinanceTrackApp.swift` if none exists yet.
@Model
final class BudgetSettings {
    var id: UUID
    var weeklySpendingLimit: Decimal
    var weekStartsOnSunday: Bool
    var includePendingTransactions: Bool
    var hideBalancesByDefault: Bool
    var requireFaceID: Bool
    var monthlyGoal: Decimal?
    /// Percentage (0...1) of the limit at which spending is flagged as "warning" rather than "good".
    /// Defaults to 0.70, matching the dashboard's 0–69% "on track" / 70–99% "getting close" /
    /// 100%+ "over" bands.
    var warningThreshold: Double
    /// Whether SpendSmart should automatically write a local backup file shortly after finance
    /// data changes (see `AutoBackupManager`). Defaults to on — this only ever writes to this
    /// device's own Documents directory, never anywhere off-device.
    ///
    /// Optional (rather than a plain `Bool`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed — SwiftData's lightweight migration
    /// can't backfill a mandatory non-optional attribute, but a `nil` optional attribute migrates
    /// with no issue. Every read site treats `nil` as "on" via `?? true`.
    var autoBackupEnabled: Bool?
    /// Whether Spend Sense (local, deterministic financial observations) is enabled. Defaults to
    /// on — Spend Sense never networks or reads/writes Supabase; this only ever governs whether
    /// its local, on-device output is shown.
    ///
    /// Optional (rather than a plain `Bool`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed — SwiftData's lightweight migration
    /// can't backfill a mandatory non-optional attribute, but a `nil` optional attribute migrates
    /// with no issue. Every read site treats `nil` as "on" via `?? true`.
    var spendSenseEnabled: Bool?
    /// Set whenever the user explicitly commits either `weeklySpendingLimit` or `monthlyGoal`
    /// through the direct two-way sync (see `SettingsView.saveWeeklyLimit`/`saveMonthlyGoal` and
    /// `WeeklyLimitEditView`/`MonthlyGoalEditView`'s `commitAutosaveNow`). Optional so a
    /// lightweight SwiftData migration backfills every pre-existing record as `nil` — "never
    /// synced through this path yet" — rather than guessing which field an existing user
    /// considers primary.
    var weeklyMonthlySyncSource: WeeklyMonthlySyncSource?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        weeklySpendingLimit: Decimal = 0,
        weekStartsOnSunday: Bool = true,
        includePendingTransactions: Bool = true,
        hideBalancesByDefault: Bool = false,
        requireFaceID: Bool = false,
        monthlyGoal: Decimal? = nil,
        warningThreshold: Double = 0.70,
        autoBackupEnabled: Bool = true,
        spendSenseEnabled: Bool = true,
        weeklyMonthlySyncSource: WeeklyMonthlySyncSource? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.weeklySpendingLimit = weeklySpendingLimit
        self.weekStartsOnSunday = weekStartsOnSunday
        self.includePendingTransactions = includePendingTransactions
        self.hideBalancesByDefault = hideBalancesByDefault
        self.requireFaceID = requireFaceID
        self.monthlyGoal = monthlyGoal
        self.warningThreshold = warningThreshold
        self.autoBackupEnabled = autoBackupEnabled
        self.spendSenseEnabled = spendSenseEnabled
        self.weeklyMonthlySyncSource = weeklyMonthlySyncSource
        self.updatedAt = updatedAt
    }

    /// The single, canonical implementation of the direct Weekly Spending Limit -> Monthly
    /// Savings Goal sync, called by every commit site (`SettingsView.saveWeeklyLimit`,
    /// `WeeklyLimitEditView.commitAutosaveNow`) so the real persisted-model behavior is
    /// identical everywhere and directly unit-testable without hosting any SwiftUI view.
    func applyWeeklySpendingLimitCommit(_ weeklyLimit: Decimal) {
        weeklySpendingLimit = weeklyLimit
        monthlyGoal = weeklyLimit * 4
        weeklyMonthlySyncSource = .weekly
        updatedAt = .now
    }

    /// The single, canonical implementation of the direct Monthly Savings Goal -> Weekly
    /// Spending Limit sync, called by every commit site (`SettingsView.saveMonthlyGoal`,
    /// `MonthlyGoalEditView.commitAutosaveNow`). `nil` means "clear the goal" — a deliberate
    /// distinct state that never touches `weeklySpendingLimit`.
    func applyMonthlySavingsGoalCommit(_ goal: Decimal?) {
        guard let goal else {
            monthlyGoal = nil
            updatedAt = .now
            return
        }
        monthlyGoal = goal
        weeklySpendingLimit = goal / 4
        weeklyMonthlySyncSource = .monthly
        updatedAt = .now
    }
}
