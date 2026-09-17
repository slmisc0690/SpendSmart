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
    /// AUTO-CALCULATE WEEKLY/MONTHLY FROM CONNECTED-ACCOUNT TRANSACTIONS — the set of Plaid
    /// `account_id`s (the same stable identifier `FinanceTransaction.plaidAccountId`/
    /// `ConnectedAccountsDashboardPresenter.Display.accountId` already use — never a display
    /// name/institution name/last-four, none of which are stable) whose imported transactions
    /// should count toward Weekly/Monthly spending. Empty/`nil` means no connected account
    /// participates automatically — manual expenses are unaffected either way. Per-user by
    /// construction: `BudgetSettings` already lives in this user's own isolated per-user SwiftData
    /// container (see `UserDataStoreManager`), so this field is automatically isolated the same
    /// way every other setting on this model already is — no new storage mechanism needed.
    ///
    /// Optional (rather than a plain `[String]`) so it migrates cleanly for installs that already
    /// had a `BudgetSettings` record before this field existed — SwiftData's lightweight migration
    /// can't backfill a mandatory non-optional attribute, but a `nil` optional attribute migrates
    /// with no issue. Same pattern as `autoBackupEnabled`/`cloudBackupRetentionDays` above. Every
    /// read site treats `nil` as "no accounts selected" via `?? []`.
    var autoCalculateConnectedAccountIds: [String]?
    /// EXCLUDE TRANSACTIONS — master on/off for the whole feature (Dashboard "Budget Exclusions"
    /// section). Defaults to off/unchecked. When `false`, `excludedTransactionIDs` below is never
    /// applied by any budgeting calculation, even if it still holds a non-empty set from a prior
    /// session — every read site gates on this flag first, so turning the feature off is a true
    /// "as if it never existed" state, not just an empty-list state.
    ///
    /// Optional (rather than a plain `Bool`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed. Every read site treats `nil` as "off"
    /// via `?? false`.
    var excludeTransactionsEnabled: Bool?
    /// EXCLUDE TRANSACTIONS — the set of `FinanceTransaction.id` values (this app's own stable,
    /// already-persisted per-row identifier — never Plaid's `externalTransactionId`, which is
    /// `nil` for every manually-entered transaction and so cannot represent both sources) the user
    /// has chosen to exclude from Weekly/Monthly budget calculations. Applied as the FINAL filter,
    /// after Manual + Auto-Tracked eligibility — see `BudgetCalculator`'s own "AUTO-TRACKED
    /// CONNECTED-ACCOUNT BUDGETING"/exclusion section. An excluded transaction is never hidden,
    /// deleted, edited, recategorized, or otherwise mutated anywhere else in the app — Recent
    /// Activity, All Transactions, Search, and every report continue showing it exactly as before;
    /// only budget-total arithmetic skips it. `FinanceTransaction.id` is stable across a Plaid
    /// pending→posted merge (`PlaidTransactionImportService.applySync` re-keys the SAME persisted
    /// row in place — see that function's own header — never creates a new one), so an exclusion
    /// survives that transition automatically with no reconciliation step needed here.
    ///
    /// Optional (rather than a plain `[UUID]`) so it migrates cleanly for installs that already
    /// had a `BudgetSettings` record before this field existed. Every read site treats `nil` as
    /// "nothing excluded" via `?? []`.
    var excludedTransactionIDs: [UUID]?
    /// ACCOUNT REGISTER AUTO DEPOSIT — master on/off. When on, a posted Connected-account deposit
    /// (see `AccountRegisterAutoDepositService.isEligibleDeposit`) is offered for review the next
    /// time the app opens, for mirroring into every Account Register listed in
    /// `accountRegisterAutoDepositAccountIds` below. Defaults to off. Scott's own explicit request
    /// (2026-09-15).
    ///
    /// Optional (rather than a plain `Bool`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed. Every read site treats `nil` as "off"
    /// via `?? false`.
    var accountRegisterAutoDepositEnabled: Bool?
    /// ACCOUNT REGISTER AUTO DEPOSIT — which Account Register(s) (`Account.id`) receive a
    /// confirmed deposit entry. Selecting more than one means EVERY confirmed deposit is mirrored
    /// into EVERY selected register (a deliberate broadcast, not a per-source-account mapping) —
    /// per Scott's own "they can do all or 1 by 1" framing. Ignored entirely while
    /// `accountRegisterAutoDepositEnabled` is off/`nil`.
    ///
    /// Optional (rather than a plain `[UUID]`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed. Every read site treats `nil` as "no
    /// registers selected" via `?? []`.
    var accountRegisterAutoDepositAccountIds: [UUID]?
    /// ACCOUNT REGISTER AUTO DEPOSIT — REVIEW STEP (added 2026-09-15, see
    /// `AccountRegisterAutoDepositService`'s own header for why this exists): every Connected
    /// transaction id (`FinanceTransaction.id`) already shown to the user in a deposit-review
    /// prompt, whether they chose to include it or not. A transaction only ever appears in
    /// `AccountRegisterDepositReviewView` once — this is what prevents that. Never touched by
    /// anything except that review flow; unrelated to `excludedTransactionIDs` above, which governs
    /// budget totals, not this feature.
    ///
    /// Optional (rather than a plain `[UUID]`) so it migrates cleanly for installs that already had
    /// a `BudgetSettings` record before this field existed. Every read site treats `nil` as "nothing
    /// reviewed yet" via `?? []`.
    var accountRegisterAutoDepositReviewedTransactionIds: [UUID]?
    /// ACCOUNT REGISTER AUTO DEPOSIT — DATE FLOOR (added 2026-09-17, closing a real incident: with
    /// no date floor at all, `AccountRegisterAutoDepositService.pendingDeposits` matched every
    /// eligible deposit ever, going back through an account's FULL history — combined with a
    /// one-time full Plaid resync, this surfaced months of old paychecks (back to June) as
    /// "pending review" all at once, and all-defaulted-to-checked meant a single "Done" tap added
    /// $50,000 Scott never intended). Stamped to "now" the moment the master toggle is switched
    /// ON (see `AccountSettingsView`'s toggle binding) — `pendingDeposits` only ever offers a
    /// transaction dated ON OR AFTER this instant, never anything from before the feature was
    /// actually turned on. Re-stamped every time the toggle goes off→on again, so a later
    /// re-enable never resurrects an old backlog either.
    ///
    /// Optional or not, this ALWAYS gates `pendingDeposits` — a `nil` value (an install that
    /// enabled the feature before this field existed) is treated as "nothing eligible yet" rather
    /// than "no floor," the safe direction after this incident. `AccountSettingsView.onAppear`
    /// self-heals a `nil` value to `.now` the first time it's seen if the toggle is already on, so
    /// this converges to a real timestamp on next launch without ever silently reopening the old
    /// unbounded-history bug.
    var accountRegisterAutoDepositEnabledAt: Date?
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
        autoCalculateConnectedAccountIds: [String] = [],
        excludeTransactionsEnabled: Bool = false,
        excludedTransactionIDs: [UUID] = [],
        accountRegisterAutoDepositEnabled: Bool = false,
        accountRegisterAutoDepositAccountIds: [UUID] = [],
        accountRegisterAutoDepositReviewedTransactionIds: [UUID] = [],
        accountRegisterAutoDepositEnabledAt: Date? = nil,
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
        self.autoCalculateConnectedAccountIds = autoCalculateConnectedAccountIds
        self.excludeTransactionsEnabled = excludeTransactionsEnabled
        self.excludedTransactionIDs = excludedTransactionIDs
        self.accountRegisterAutoDepositEnabled = accountRegisterAutoDepositEnabled
        self.accountRegisterAutoDepositAccountIds = accountRegisterAutoDepositAccountIds
        self.accountRegisterAutoDepositReviewedTransactionIds = accountRegisterAutoDepositReviewedTransactionIds
        self.accountRegisterAutoDepositEnabledAt = accountRegisterAutoDepositEnabledAt
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
