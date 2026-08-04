import Foundation
import SwiftData

/// Singleton-style settings record for the user's budget configuration.
/// The app expects exactly one `BudgetSettings` instance; a default is created on first launch
/// by `RootView` in `FinanceTrackApp.swift` if none exists yet.
@Model
final class BudgetSettings {
    var id: UUID
    /// Always derived — see `applyMonthlyPlanAutoCalculate`. Manual editing of this field was
    /// removed; the Monthly Plan's own `monthlySavingsGoal`, its optional buffer, and
    /// `MonthlyPlanCalculator.monthlySpendRemaining` (which itself uses
    /// `BudgetCalculator.monthlySpent` for actual spending) are the sole authoritative inputs.
    var weeklySpendingLimit: Decimal
    var weekStartsOnSunday: Bool
    var includePendingTransactions: Bool
    var hideBalancesByDefault: Bool
    var requireFaceID: Bool
    /// Always derived — see `applyMonthlyPlanAutoCalculate`. Manual editing of this field was
    /// removed; it always mirrors `MonthlyPlanSettings.monthlySavingsGoal`.
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
    /// How many distinct calendar days of iCloud daily backups `CloudBackupManager` keeps before
    /// pruning the oldest — user-configurable (Data Backup screen), since backup file size here is
    /// negligible (tens of KB/day) and it's the user's own iCloud storage being spent. Defaults to
    /// 7. Every read site treats `nil`, `0`, or negative as "use the default 7" via
    /// `CloudBackupManager.normalizedRetentionDays(_:)` — never a literal 0-day retention, which
    /// would prune every backup immediately including the one just written.
    ///
    /// Optional (rather than a plain `Int`) so it migrates cleanly for installs that already had a
    /// `BudgetSettings` record before this field existed — SwiftData's lightweight migration can't
    /// backfill a mandatory non-optional attribute, but a `nil` optional attribute migrates with no
    /// issue. Same pattern as `autoBackupEnabled` immediately above.
    var cloudBackupRetentionDays: Int?
    /// Whether Spend Sense (local, deterministic financial observations) is enabled. Defaults to
    /// on — Spend Sense never networks or reads/writes Supabase; this only ever governs whether
    /// its local, on-device output is shown.
    ///
    /// Optional (rather than a plain `Bool`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed — SwiftData's lightweight migration
    /// can't backfill a mandatory non-optional attribute, but a `nil` optional attribute migrates
    /// with no issue. Every read site treats `nil` as "on" via `?? true`.
    var spendSenseEnabled: Bool?
    /// Whether the Dashboard's "Monthly Spending" Quick Stat is shown. Defaults to on.
    ///
    /// Optional (rather than a plain `Bool`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed — SwiftData's lightweight migration
    /// can't backfill a mandatory non-optional attribute, but a `nil` optional attribute migrates
    /// with no issue. Every read site treats `nil` as "on" via `?? true`.
    var showMonthlySpendingQuickStat: Bool?
    /// Whether the Dashboard's Saved This Month / Total Savings to Date Quick Stat is shown.
    /// Defaults to on. Controls the Dashboard Quick Stat only — never hides the Monthly Plan
    /// "Saved This Month" card itself.
    ///
    /// Optional (rather than a plain `Bool`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed — SwiftData's lightweight migration
    /// can't backfill a mandatory non-optional attribute, but a `nil` optional attribute migrates
    /// with no issue. Every read site treats `nil` as "on" via `?? true`.
    var showSavedThisMonthQuickStat: Bool?
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
        cloudBackupRetentionDays: Int = 7,
        spendSenseEnabled: Bool = true,
        showMonthlySpendingQuickStat: Bool = true,
        showSavedThisMonthQuickStat: Bool = true,
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
        self.cloudBackupRetentionDays = cloudBackupRetentionDays
        self.spendSenseEnabled = spendSenseEnabled
        self.showMonthlySpendingQuickStat = showMonthlySpendingQuickStat
        self.showSavedThisMonthQuickStat = showSavedThisMonthQuickStat
        self.updatedAt = updatedAt
    }

    /// The single, canonical implementation of the Monthly Plan → Budget Settings derived-value
    /// sync — the ONLY way `monthlyGoal`/`weeklySpendingLimit` are ever set. Budget Settings no
    /// longer supports manual editing of either field at all (see `MonthlyGoalEditView`/
    /// `WeeklyLimitEditView`, both now permanently read-only, and `SettingsView`'s own inline
    /// fields, also permanently disabled). Every call site (`MonthlyPlanView`'s lifecycle hooks,
    /// `SettingsView`'s `onAppear` reconciliation and reset-to-factory-defaults path) calls this
    /// one method so the real persisted-model behavior is identical everywhere.
    ///
    /// Formula (locked product behavior — never 4.33, always exactly 4):
    ///   monthlyGoal = monthlyPlanSavingsGoal
    ///   weeklySpendingLimit = monthlySpendRemaining / 4
    ///
    /// `monthlySpendRemaining` must always be the existing, unmodified
    /// `MonthlyPlanCalculator.monthlySpendRemaining` result (built from money after bills, the
    /// savings goal, the optional buffer, and `BudgetCalculator.monthlySpent` — actual spending
    /// subtracted exactly once, never reimplemented here) — already clamped at 0, so no further
    /// clamping is needed at this step.
    func applyMonthlyPlanAutoCalculate(monthlyPlanSavingsGoal: Decimal, monthlySpendRemaining: Decimal) {
        monthlyGoal = monthlyPlanSavingsGoal
        weeklySpendingLimit = monthlySpendRemaining / 4
        updatedAt = .now
    }
}
