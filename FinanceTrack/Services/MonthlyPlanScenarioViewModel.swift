import Foundation

/// MONTHLY PLAN SCENARIO BUILDER — a non-persistent, in-memory "what if" sandbox for the Monthly
/// Plan. Lets the Primary user build a scenario from Add/Remove/Change modifications across Income,
/// Mid Month, and End Month, and see the resulting effect via the SAME `MonthlyPlanCalculator` the
/// real Monthly Plan uses, without ever touching the local data store, the backend, on-device
/// preference storage, or any real `IncomeSource`/`RecurringExpense`/`MonthlyPlanSettings`/
/// `BudgetSettings`/`FinanceTransaction` record.
///
/// ONE AUTHORITATIVE CALCULATION PATH — this type holds no scenario state of its own (no item
/// arrays, no baseline copies). Every temporary modification lives in `engine` (a `ScenarioEngine`,
/// the Phase 1 architecture); this type is purely a thin, UI-facing adapter that (a) seeds `engine`
/// from real Monthly Plan data at `init`, (b) translates Builder actions (Add/Remove/Change) into
/// concrete `ScenarioAction`s and forwards them to `engine.apply(_:)`, and (c) bridges `engine`'s
/// items back to `MonthlyPlanCalculator.Summary` via `ScenarioSummaryBuilder` for display. There is
/// no second, competing calculation anywhere in this type.
///
/// NON-DESTRUCTIVE BY CONSTRUCTION: `engine` holds no reference to the app's model store at all, so
/// it — and this type, which only ever talks to `engine` — is structurally incapable of writing to
/// it.
///
/// `currentSummary` is computed ONCE at `init`, from the real, unfiltered baseline snapshot, and is
/// never recomputed afterward — no Scenario edit can ever change it. This is what makes "Current" a
/// stable comparison point throughout a Builder session.
///
/// TIMING-FILTER INDEPENDENCE: callers must always pass the COMPLETE, unfiltered active income/
/// expense arrays (e.g. `MonthlyPlanView.allIncomeSources`/`allRecurringExpenses`, never
/// `filteredRecurringExpenses`) — the Fixed Bills Timing Filter is presentation-only and lives
/// entirely in `MonthlyPlanView`; Scenario must never inherit whatever filter happens to be
/// selected there.
@Observable
final class MonthlyPlanScenarioViewModel {
    /// Which real-world thing an `ActiveModification` targets — used only for its own display
    /// grouping label. Deliberately NOT `ScenarioCategory`: that type only names two of
    /// `PlanTiming`'s five values (`.midMonth`/`.endMonth`), so a Fixed Bill on any other timing
    /// (Beginning/Weekly/Custom Date — all supported from Phase 4 onward) would have no correct
    /// `ScenarioCategory` to report itself under.
    enum ModificationContext: Equatable {
        case income
        case fixedBill(timing: PlanTiming)
        case monthlySavingsGoal
        case plannedWeeklySpending
    }

    /// One row for the Builder's "Active Changes" review list — derived read-only from
    /// `engine.activeActions` + `engine.baselineItems`, never a second, independently-mutated
    /// store (see `activeModifications`).
    struct ActiveModification: Identifiable {
        let id: UUID
        let context: ModificationContext
        let kind: String
        let itemName: String
        let originalAmount: Decimal?
        let newAmount: Decimal?

        /// "Income", "Monthly Savings Goal", or the bill's own real timing label (e.g.
        /// "Mid-Month", "Beginning of Month") — see `ModificationContext`'s own header.
        var groupLabel: String {
            switch context {
            case .income: return "Income"
            case .fixedBill(let timing): return timing.label
            case .monthlySavingsGoal: return "Monthly Savings Goal"
            case .plannedWeeklySpending: return "Planned Weekly Spending"
            }
        }
    }

    let engine: ScenarioEngine

    /// PHANTOM SCENARIO FIX — the ONE authoritative "is a Scenario actually active" check. A
    /// Scenario exists only when the user has made at least one real modification
    /// (`engine.activeActions`) — never merely because `engine.items` is non-empty or populated,
    /// since `items` always equals `baselineItems` (the real Monthly Plan, restated) whenever no
    /// action has been applied (see `ScenarioEngine.init`/`recompute()`). Every Scenario-presenting
    /// view must read this property rather than re-deriving its own active-state check, so there is
    /// exactly one place that answers "is a Scenario active." Scenario calculation properties below
    /// (`scenarioSummary`, `scenarioMonthlyAvailableAfterBills`, `scenarioWeeklyRecommendation`,
    /// etc.) deliberately keep calculating against the live `engine.items`/`engine.baselineItems`
    /// unconditionally — they remain available for the presentation layer to use once a Scenario
    /// does become active; this property exists so the presentation layer can decide whether to
    /// show those results as an active comparison at all.
    var hasActiveScenario: Bool { !engine.activeActions.isEmpty }

    /// Computed once, at init, from the real unfiltered baseline — never recomputed. This is
    /// deliberately a stored `let`, not a computed property re-deriving from `engine.baselineItems`
    /// on every access, so its identity as "the one true Current" is unambiguous.
    let currentSummary: MonthlyPlanCalculator.Summary

    private let planSettings: MonthlyPlanSettings?
    private let weeklyBudgetLimit: Decimal
    private let transactions: [FinanceTransaction]
    private let month: DateInterval
    private let weekInterval: DateInterval
    private let weekStartsOnSunday: Bool
    private let includePending: Bool
    private let warningThreshold: Double

    init(
        incomeSources: [IncomeSource],
        recurringExpenses: [RecurringExpense],
        planSettings: MonthlyPlanSettings?,
        weeklyBudgetLimit: Decimal,
        transactions: [FinanceTransaction],
        month: DateInterval,
        weekInterval: DateInterval,
        weekStartsOnSunday: Bool,
        includePending: Bool,
        warningThreshold: Double
    ) {
        let baseline = ScenarioLineItemFactory.baseline(incomeSources: incomeSources, recurringExpenses: recurringExpenses)
        self.engine = ScenarioEngine(baselineItems: baseline)

        self.planSettings = planSettings
        self.weeklyBudgetLimit = weeklyBudgetLimit
        self.transactions = transactions
        self.month = month
        self.weekInterval = weekInterval
        self.weekStartsOnSunday = weekStartsOnSunday
        self.includePending = includePending
        self.warningThreshold = warningThreshold

        self.currentSummary = ScenarioSummaryBuilder.summary(
            for: baseline,
            month: month,
            planSettings: planSettings,
            weeklyBudgetLimit: weeklyBudgetLimit,
            transactions: transactions,
            weekInterval: weekInterval,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold
        )
    }

    /// Rebuilt from `engine.items` on every access via `ScenarioSummaryBuilder` — the SAME bridge
    /// function `currentSummary` above used against the baseline, applied here to the live,
    /// modification-applied item set.
    var scenarioSummary: MonthlyPlanCalculator.Summary {
        ScenarioSummaryBuilder.summary(
            for: engine.items,
            month: month,
            planSettings: scenarioPlanSettings,
            weeklyBudgetLimit: weeklyBudgetLimit,
            transactions: transactions,
            weekInterval: weekInterval,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold
        )
    }

    /// The real, current Monthly Savings Goal — the SAME value driving the real Monthly Plan
    /// (`planSettings?.monthlySavingsGoal`), never a duplicated/cached copy. Used both to seed the
    /// Builder's Change-goal form with "Current Amount" and as the fallback when no Scenario
    /// override is active.
    var currentMonthlySavingsGoal: Decimal { planSettings?.monthlySavingsGoal ?? 0 }

    /// `planSettings` as `scenarioSummary` must see it: the real settings object, UNLESS
    /// `engine.savingsGoalOverride` is active, in which case a transient `MonthlyPlanSettings`
    /// (never inserted into any persistent store, never written back — the identical established
    /// pattern `ScenarioSummaryBuilder` already uses for transient `IncomeSource`/
    /// `RecurringExpense`) stands in with the hypothetical goal, copying the real `bufferAmount`
    /// unchanged. This reuses `MonthlyPlanCalculator.summary`'s existing
    /// `planSettings?.monthlySavingsGoal ?? 0` read completely unmodified — no fork, no duplicated
    /// formula.
    private var scenarioPlanSettings: MonthlyPlanSettings? {
        guard let override = engine.savingsGoalOverride else { return planSettings }
        return MonthlyPlanSettings(monthlySavingsGoal: override, bufferAmount: planSettings?.bufferAmount)
    }

    // MARK: - MONTHLY PLAN + SCENARIO CORRECTIONS PHASE — Planned Weekly Spending planning path
    //
    // ONE AUTHORITATIVE FORMULA PATH (Part 13): every value below is derived exclusively through
    // `MonthlyPlanCalculator`'s new planning functions, applied to `currentSummary`/`scenarioSummary`
    // (themselves the SAME `MonthlyPlanCalculator.summary` this type has always used) — never a
    // second, competing calculation.

    /// The real Planned Weekly Spending override — `nil` in automatic mode, matching
    /// `currentMonthlySavingsGoal`'s own "read the real settings object directly" pattern.
    var currentPlannedWeeklySpendingOverride: Decimal? { planSettings?.plannedWeeklySpendingOverride }

    /// The Scenario's effective Planned Weekly Spending override — the Scenario override when one
    /// is active, otherwise the real override (so a Scenario with no weekly-spending change still
    /// respects the user's real custom amount, exactly like `scenarioPlanSettings` does for the
    /// Savings Goal).
    private var scenarioPlannedWeeklySpendingOverride: Decimal? {
        engine.plannedWeeklySpendingOverride ?? currentPlannedWeeklySpendingOverride
    }

    /// Effective Planned Weekly Spending using the REAL baseline's Flexible Spending and override —
    /// unaffected by any active Scenario action, exactly like `currentSummary`.
    var currentPlannedWeeklySpending: Decimal {
        MonthlyPlanCalculator.effectivePlannedWeeklySpending(override: currentPlannedWeeklySpendingOverride, flexibleSpendingAvailable: currentSummary.flexibleSpendingAvailable)
    }

    /// Effective Planned Weekly Spending using the live, modification-applied Flexible Spending and
    /// override.
    var scenarioPlannedWeeklySpending: Decimal {
        MonthlyPlanCalculator.effectivePlannedWeeklySpending(override: scenarioPlannedWeeklySpendingOverride, flexibleSpendingAvailable: scenarioSummary.flexibleSpendingAvailable)
    }

    var currentPlannedMonthlySpending: Decimal {
        MonthlyPlanCalculator.plannedMonthlySpending(plannedWeeklySpending: currentPlannedWeeklySpending)
    }

    var scenarioPlannedMonthlySpending: Decimal {
        MonthlyPlanCalculator.plannedMonthlySpending(plannedWeeklySpending: scenarioPlannedWeeklySpending)
    }

    var currentAdditionalPlannedSavings: Decimal {
        MonthlyPlanCalculator.additionalPlannedSavings(flexibleSpendingAvailable: currentSummary.flexibleSpendingAvailable, plannedMonthlySpending: currentPlannedMonthlySpending)
    }

    var scenarioAdditionalPlannedSavings: Decimal {
        MonthlyPlanCalculator.additionalPlannedSavings(flexibleSpendingAvailable: scenarioSummary.flexibleSpendingAvailable, plannedMonthlySpending: scenarioPlannedMonthlySpending)
    }

    /// The planning-workflow Projected Monthly Savings (Part 6) — DISTINCT from
    /// `currentSummary.projectedMonthlySavings`/`scenarioSummary.projectedMonthlySavings` (the
    /// existing actual-spending-based formula, left completely unchanged for its other consumers).
    var currentProjectedMonthlySavingsPlan: Decimal {
        MonthlyPlanCalculator.projectedMonthlySavingsFromPlan(monthlySavingsGoal: currentMonthlySavingsGoal, additionalPlannedSavings: currentAdditionalPlannedSavings)
    }

    var scenarioProjectedMonthlySavingsPlan: Decimal {
        let goal = engine.savingsGoalOverride ?? currentMonthlySavingsGoal
        return MonthlyPlanCalculator.projectedMonthlySavingsFromPlan(monthlySavingsGoal: goal, additionalPlannedSavings: scenarioAdditionalPlannedSavings)
    }

    // MARK: - SCENARIO MONTHLY PLANNING CORRECTION — Bill Groups, Monthly Savings Goal, and
    // Monthly Planning authoritative formulas
    //
    // Built EXCLUSIVELY from the two exact PERIOD results (`currentMidMonthCashFlow`/
    // `currentEndMonthCashFlow` and their Scenario counterparts) — never monthly-equivalent
    // Flexible Spending, never normalized/estimated Fixed Bills, never actual transaction spending,
    // never a stale `MonthlyPlanCalculator.Summary` value. This is the ONE authoritative monthly-
    // planning path for the Scenario Results screen; `MonthlyPlanCalculator.Summary`'s own
    // `flexibleSpendingAvailable`/`estimatedMonthlyFixedExpenses` remain completely unchanged and
    // still drive the real Monthly Plan/Dashboard/Monthly Outlook elsewhere.

    /// FIXED BILLS $40 CORRECTION — the authoritative Bill Group total for one `PlanTiming` bucket,
    /// sharing the exact raw-amount convention `FixedBillsTimingFilter.displayAmount`/
    /// `displayedTotal` established for the real Fixed Bills screen (sum of each bill's raw
    /// `amount`, never `MonthlyPlanCalculator.estimatedMonthlyFixedExpenses`'s frequency
    /// conversion/one-time-date exclusion, which is what reintroduced the $1,949-vs-$1,989 gap into
    /// this screen). `currentBillGroupTotal`/`fixedBillsTotal(timingFilter:)` are the same value —
    /// this is a same-name Scenario counterpart reading `engine.items` instead of
    /// `engine.baselineItems`.
    func currentBillGroupTotal(_ timing: PlanTiming) -> Decimal {
        fixedBillsTotal(timingFilter: timing)
    }

    func scenarioBillGroupTotal(_ timing: PlanTiming) -> Decimal {
        engine.items.filter { $0.ledger == .expense && $0.isIncluded && $0.timing == timing }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// Part 7 — whether a Bill Group row should be shown at all: at least one eligible bill exists
    /// for `timing`, in either Current (the real baseline) or Scenario (so adding a hypothetical
    /// bill to a previously-empty group makes that group visible immediately, and removing every
    /// bill from a group hides it once nothing remains in either Current or Scenario).
    func billGroupIsVisible(_ timing: PlanTiming) -> Bool {
        engine.baselineItems.contains { $0.ledger == .expense && $0.timing == timing }
            || engine.items.contains { $0.ledger == .expense && $0.isIncluded && $0.timing == timing }
    }

    /// Monthly Available After Bills = Mid-Month Remaining + End-of-Month Remaining — Part 4's one
    /// authoritative formula, built directly from the two exact period results. Neither period's
    /// `remaining` includes the Monthly Savings Goal (see `ScenarioCashFlowCalculator`'s own header
    /// on why End-of-Month no longer allocates it) — the goal is applied once, below, at the
    /// monthly level.
    var currentMonthlyAvailableAfterBills: Decimal {
        currentMidMonthCashFlow().remaining + currentEndMonthCashFlow().remaining
    }

    var scenarioMonthlyAvailableAfterBills: Decimal {
        scenarioMidMonthCashFlow().remaining + scenarioEndMonthCashFlow().remaining
    }

    /// The Scenario's effective Monthly Savings Goal — the Scenario override when one is active,
    /// otherwise the real goal. Mirrors `scenarioPlannedWeeklySpendingOverride`'s own "Scenario
    /// override, else the real value" pattern.
    var scenarioMonthlySavingsGoal: Decimal { engine.savingsGoalOverride ?? currentMonthlySavingsGoal }

    /// Available After Planned Savings = Monthly Available After Bills − Monthly Savings Goal —
    /// Part 5's one authoritative formula. This is the Scenario's monthly amount available for
    /// discretionary spending after bills AND planned savings; it replaces "Planned Monthly
    /// Spending"'s prior `$650 × 4` value (a different concept — the user's manually selected
    /// planned spend, not the total monthly amount actually available) as the value shown under the
    /// renamed "Planned Monthly Spending Available" row (Part 9).
    var currentAvailableAfterPlannedSavings: Decimal {
        currentMonthlyAvailableAfterBills - currentMonthlySavingsGoal
    }

    var scenarioAvailableAfterPlannedSavings: Decimal {
        scenarioMonthlyAvailableAfterBills - scenarioMonthlySavingsGoal
    }

    // MARK: - WEEK-BY-WEEK RECALCULATION PHASE — authoritative Scenario weekly spending recommendation
    //
    // Distinct from `scenarioPlannedWeeklySpending` above (the Part 9/11 "Planned Weekly Spending"
    // Active-Changes comparison row, which intentionally shows the real custom override unmodified
    // until the user adds an explicit Scenario Planned-Weekly-Spending change — that row answers
    // "what is the Planned Weekly Spending setting," not "what should I spend this week under the
    // full Scenario"). This section answers the Week-by-Week card's actual question: how much can
    // be safely spent each week given EVERY active Scenario change (income, bills, savings goal, and
    // any explicit weekly override).
    //
    // SCENARIO MONTHLY PLANNING CORRECTION — the prior Custom-mode "current custom weekly + monthly
    // difference" direct-adjustment rule (and, before that, its divided-by-4 predecessor) are BOTH
    // replaced. The single, mode-independent rule is now: Scenario Planned Weekly Spending =
    // Scenario Available After Planned Savings ÷ 4 — this is the ONLY divisor-4 step anywhere in
    // this formula, applied to the new exact-period-based Available After Planned Savings, never to
    // monthly-equivalent Flexible Spending (Part 15 explicitly excludes that input here). This
    // applies identically whether the real plan is Automatic or Custom — Available After Planned
    // Savings already reflects the Scenario's own bills/income/goal, so there is no longer a
    // separate "adjust the custom baseline" branch to maintain.

    /// The Scenario's authoritative weekly spending recommendation, UNCLAMPED (may be negative — see
    /// `scenarioWeeklyRecommendationDisplay` for the zero-floored display value and
    /// `scenarioMonthlyShortfall` for the disclosed deficit).
    ///
    /// - An explicit Scenario Planned Weekly Spending override (`engine.plannedWeeklySpendingOverride`)
    ///   always wins outright.
    /// - Otherwise: `scenarioAvailableAfterPlannedSavings ÷ 4`.
    var scenarioWeeklyRecommendation: Decimal {
        engine.plannedWeeklySpendingOverride ?? (scenarioAvailableAfterPlannedSavings / 4)
    }

    /// `scenarioWeeklyRecommendation`, floored at zero — the Week-by-Week card must never display a
    /// negative recommended spend (see `scenarioMonthlyShortfall` for the deficit this hides).
    var scenarioWeeklyRecommendationDisplay: Decimal { max(0, scenarioWeeklyRecommendation) }

    /// The deficit to disclose when `scenarioWeeklyRecommendation` is negative — the amount by which
    /// the Scenario exceeds the available weekly plan, i.e. the absolute value of the negative raw
    /// result itself (no further conversion — the raw result already reflects the full, undivided
    /// Scenario monthly difference applied to the weekly baseline). Zero whenever there is no
    /// deficit — the deficit is never silently lost, just surfaced as a separate disclosed figure
    /// instead of a negative weekly one.
    var scenarioMonthlyShortfall: Decimal {
        scenarioWeeklyRecommendation < 0 ? -scenarioWeeklyRecommendation : 0
    }

    /// Whether `scenarioWeeklyRecommendation` reflects an explicit Scenario Planned Weekly Spending
    /// override, as opposed to the derived Automatic/Custom-adjustment formula — drives which info
    /// explanation the Week-by-Week card shows.
    var scenarioWeeklyRecommendationIsExplicitOverride: Bool { engine.plannedWeeklySpendingOverride != nil }

    /// The per-week Current/Scenario comparisons shown on the Week-by-Week card — reuses
    /// `scenarioSummary.weeklyComparisons` for its week intervals and actual-spending figures (Part
    /// 2: Actual must keep using the same qualifying-transaction rules, unchanged), but replaces
    /// each week's `recommendedLimit`/`status` with the authoritative `scenarioWeeklyRecommendationDisplay`
    /// derived above, instead of `MonthlyPlanCalculator.summary`'s own internal calendar-week-count
    /// formula (which this phase's investigation found does not respect a Planned Weekly Spending
    /// override and does not always divide by 4).
    var scenarioWeekByWeekComparisons: [MonthlyPlanCalculator.WeeklyPlanComparison] {
        // PHANTOM SCENARIO FIX — when no Scenario is active, the Week-by-Week card must show the
        // same $0.00 "no comparison is active" recommendation as the Results section's Planned
        // Weekly Spending row, never the automatic Scenario Available After Planned Savings ÷ 4
        // baseline (`scenarioWeeklyRecommendationDisplay` itself is left unchanged and still
        // calculates that baseline internally, for use once a Scenario becomes active).
        let recommended = hasActiveScenario ? scenarioWeeklyRecommendationDisplay : 0
        return scenarioSummary.weeklyComparisons.map { comparison in
            MonthlyPlanCalculator.WeeklyPlanComparison(
                weekInterval: comparison.weekInterval,
                recommendedLimit: recommended,
                actualSpent: comparison.actualSpent,
                status: BudgetCalculator.status(spent: comparison.actualSpent, limit: recommended, warningThreshold: warningThreshold)
            )
        }
    }

    func currentTiming(_ timing: PlanTiming) -> ScenarioTimingTotal {
        ScenarioSummaryBuilder.timingTotal(for: engine.baselineItems, timing: timing, month: month)
    }

    func scenarioTiming(_ timing: PlanTiming) -> ScenarioTimingTotal {
        ScenarioSummaryBuilder.timingTotal(for: engine.items, timing: timing, month: month)
    }

    /// "Extra Spending After [Timing] Bills" for Current/Scenario. `.endMonth` is the true
    /// whole-month figure — `flexibleSpendingAvailable` itself, which already includes every
    /// active item regardless of timing — so it is returned directly, never recomputed. Every
    /// other timing routes through `ScenarioSummaryBuilder.extraSpendingThroughCutoff` (see that
    /// function's own header for the corrected, no-double-counting formula).
    func currentExtraSpendingAfter(_ timing: PlanTiming) -> Decimal {
        if timing == .endMonth { return currentSummary.flexibleSpendingAvailable }
        return ScenarioSummaryBuilder.extraSpendingThroughCutoff(items: engine.baselineItems, cutoff: timing, month: month, planSettings: planSettings)
    }

    func scenarioExtraSpendingAfter(_ timing: PlanTiming) -> Decimal {
        if timing == .endMonth { return scenarioSummary.flexibleSpendingAvailable }
        return ScenarioSummaryBuilder.extraSpendingThroughCutoff(items: engine.items, cutoff: timing, month: month, planSettings: scenarioPlanSettings)
    }

    // MARK: - Cash-Flow Corrective Phase: real cumulative cash flow through Mid-Month/End-Month

    /// Genuine cumulative cash flow through the Mid-Month cutoff (the 15th) — REAL, current
    /// baseline data, unaffected by any active Scenario action, exactly like `currentSummary`/
    /// `currentTiming`. Replaces `currentExtraSpendingAfter(.midMonth)` in the UI (that method
    /// remains available, unmodified, for anything still referencing its narrower
    /// `ScenarioSummaryBuilder.extraSpendingThroughCutoff` formula — see
    /// `ScenarioCashFlowCalculator`'s own header for why this is the corrected replacement).
    func currentMidMonthCashFlow() -> ScenarioCashFlowCalculator.Breakdown {
        ScenarioCashFlowCalculator.midMonthPeriodCashFlow(items: engine.baselineItems, month: month)
    }

    /// The live, modification-applied counterpart to `currentMidMonthCashFlow()`.
    func scenarioMidMonthCashFlow() -> ScenarioCashFlowCalculator.Breakdown {
        ScenarioCashFlowCalculator.midMonthPeriodCashFlow(items: engine.items, month: month)
    }

    /// End-of-Month PERIOD cash flow (MONTHLY OUTLOOK + SCENARIO PERIOD-CASH-FLOW CORRECTION) —
    /// income/bills for the End-of-Month period ONLY, never cumulative from month start — REAL,
    /// current baseline data. Includes the full, un-prorated Monthly Savings Goal.
    func currentEndMonthCashFlow() -> ScenarioCashFlowCalculator.Breakdown {
        ScenarioCashFlowCalculator.endMonthPeriodCashFlow(items: engine.baselineItems, month: month, planSettings: planSettings)
    }

    /// The live, modification-applied counterpart to `currentEndMonthCashFlow()` — uses
    /// `scenarioPlanSettings` so an active Monthly Savings Goal override is respected, exactly like
    /// `scenarioSummary` itself.
    func scenarioEndMonthCashFlow() -> ScenarioCashFlowCalculator.Breakdown {
        ScenarioCashFlowCalculator.endMonthPeriodCashFlow(items: engine.items, month: month, planSettings: scenarioPlanSettings)
    }

    /// Active items excluded from the cash-flow rows above (no stored date, or an unsupported
    /// frequency) — surfaced so the Builder can disclose exactly what wasn't counted rather than
    /// silently under-reporting. Read against the live, modification-applied item set, matching
    /// what the Scenario cash-flow rows themselves show.
    var cashFlowExcludedItems: [ScenarioLineItem] {
        ScenarioCashFlowCalculator.excludedItems(in: engine.items)
    }

    // MARK: - Custom Date Range

    /// Totals for `[start, end]` (inclusive) using the REAL baseline — unaffected by any active
    /// Scenario action, exactly like `currentSummary`/`currentTiming`.
    func currentDateRangeTotals(start: Date, end: Date) -> ScenarioDateRangeCalculator.RangeTotals {
        ScenarioDateRangeCalculator.totals(for: engine.baselineItems, start: start, end: end)
    }

    /// Totals for `[start, end]` (inclusive) using the live, modification-applied item set —
    /// reflects every active Add/Remove/Change exactly like `scenarioSummary`/`scenarioTiming`.
    func scenarioDateRangeTotals(start: Date, end: Date) -> ScenarioDateRangeCalculator.RangeTotals {
        ScenarioDateRangeCalculator.totals(for: engine.items, start: start, end: end)
    }

    // MARK: - Builder: real items eligible for Remove/Change

    /// Real (never hypothetical) active income items, for the Income screen's Remove/Change
    /// pickers. Items with an already-active Remove action are excluded from the Remove picker —
    /// selecting "Remove" again for an already-removed item is meaningless (the underlying
    /// id-based replace rule in `ScenarioEngine.apply(_:)` would harmlessly no-op it anyway, but
    /// hiding it is clearer UX); the Change picker is NOT filtered this way (see
    /// `ScenarioAction.id`'s own header for why re-Changing a removed item is valid).
    func removableIncomeItems() -> [ScenarioLineItem] {
        removable(engine.eligibleSourceItems(in: .income))
    }

    func changeableIncomeItems() -> [ScenarioLineItem] {
        engine.eligibleSourceItems(in: .income)
    }

    /// Every `PlanTiming` value — the complete model, never narrowed. Kept for callers (and
    /// existing tests) that specifically need "every timing the model supports," as opposed to
    /// `availableFixedBillTimingFilters` below (Phase 5), which is what the Fixed Bills filter
    /// chips actually display.
    static let fixedBillTimingFilters = PlanTiming.allCases

    /// The `PlanTiming` values that actually have at least one active real Fixed Bill right now —
    /// in `PlanTiming.allCases` order — generated dynamically from the real baseline data, never a
    /// hardcoded list. This is what the Fixed Bills filter chips display ("All" plus only the
    /// categories that aren't empty); `fixedBillTimingFilters` above (every timing, including empty
    /// ones) remains available separately for anything that needs the full model.
    ///
    /// PHASE 6: `.customDate` is always included regardless of whether a Custom Date bill currently
    /// exists — Custom Date is where a user ADDS a first hypothetical dated bill, so hiding it
    /// whenever it's empty would make it unreachable from the Fixed Bills filter row. Every other
    /// timing remains strictly presence-driven.
    var availableFixedBillTimingFilters: [PlanTiming] {
        let presentTimings = Set(engine.baselineItems.filter { $0.ledger == .expense }.map(\.timing))
        return PlanTiming.allCases.filter { $0 == .customDate || presentTimings.contains($0) }
    }

    /// Real (never hypothetical) active Fixed Bill items across EVERY `PlanTiming`, optionally
    /// narrowed to one timing — unlike Phase 2/3's category-scoped queries, this deliberately does
    /// NOT go through `ScenarioCategory` (which only names Mid-Month/End-Month), so
    /// Beginning/Weekly/Custom-Date bills are reachable too.
    func fixedBillItems(timingFilter: PlanTiming?) -> [ScenarioLineItem] {
        engine.baselineItems.filter { $0.ledger == .expense && (timingFilter == nil || $0.timing == timingFilter) }
    }

    func removableFixedBills(timingFilter: PlanTiming?) -> [ScenarioLineItem] {
        removable(fixedBillItems(timingFilter: timingFilter))
    }

    func changeableFixedBills(timingFilter: PlanTiming?) -> [ScenarioLineItem] {
        fixedBillItems(timingFilter: timingFilter)
    }

    /// FIXED-BILLS TOTAL CORRECTION PHASE — the total for the Fixed Bills selector's CURRENTLY
    /// selected timing filter — computed from the exact same `fixedBillItems(timingFilter:)`
    /// collection the Add/Remove/Change pickers show, by summing each item's raw `amount`
    /// directly (the same "Current Amount" value `changeItemForm`/`highContrastAmountRow` display
    /// for a selected item — see `MonthlyPlanView.displayAmount(for:)`'s own header for why
    /// routing through `MonthlyPlanCalculator.estimatedMonthlyFixedExpenses`'s frequency
    /// conversion/one-time-date exclusion instead would diverge from what's shown).
    func fixedBillsTotal(timingFilter: PlanTiming?) -> Decimal {
        // `ScenarioLineItem.amount` is already the exact value `changeItemForm`'s "Current
        // Amount" row displays for each candidate — the same raw-amount convention
        // `FixedBillsTimingFilter.displayAmount(for:)` establishes for `RecurringExpense`.
        fixedBillItems(timingFilter: timingFilter).reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func removable(_ candidates: [ScenarioLineItem]) -> [ScenarioLineItem] {
        let removedIDs = Set(engine.activeActions.compactMap { ($0 as? RemoveScenarioItemAction)?.id })
        return candidates.filter { !removedIDs.contains($0.id) }
    }

    // MARK: - Builder: apply a modification

    /// Adds a brand-new hypothetical income item, existing only inside `engine` — never inserted
    /// into SwiftData, never written back to any real `IncomeSource`. `name` must be non-empty
    /// after trimming and `amount` must be greater than zero.
    @discardableResult
    func addHypotheticalIncome(name: String, amount: Decimal) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHypotheticalName(trimmedName), Self.isValidHypotheticalAmount(amount) else { return false }
        engine.apply(AddScenarioItemAction(ledger: .income, timing: .beginningMonth, itemName: trimmedName, amount: amount))
        return true
    }

    /// Adds a brand-new hypothetical Fixed Bill tagged with `timing` (any `PlanTiming` value the
    /// user picked — not limited to Mid/End Month), existing only inside `engine` — never inserted
    /// into SwiftData, never written back to any real `RecurringExpense`. `name` must be non-empty
    /// after trimming and `amount` must be greater than zero. `referenceDate` is optional
    /// (`.customDate` timing is the one case where a specific date is genuinely meaningful — see
    /// `ScenarioDateRangeCalculator`, which reads it for Custom Date Range occurrence counting).
    @discardableResult
    func addHypotheticalFixedBill(name: String, amount: Decimal, timing: PlanTiming, referenceDate: Date? = nil) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHypotheticalName(trimmedName), Self.isValidHypotheticalAmount(amount) else { return false }
        engine.apply(AddScenarioItemAction(ledger: .expense, timing: timing, itemName: trimmedName, amount: amount, referenceDate: referenceDate))
        return true
    }

    /// Excludes the real item `itemID` from the Scenario result only — the real
    /// `IncomeSource`/`RecurringExpense` is never touched.
    func removeItem(_ itemID: UUID) {
        engine.apply(RemoveScenarioItemAction(id: itemID))
    }

    /// PHASE 6 — Part 1 (per-card "edit"): re-applies an already-active hypothetical Income Add
    /// under the SAME `id`, so `ScenarioEngine.apply(_:)`'s existing id-based replace rule updates
    /// it in place rather than appending a duplicate item. `id` must be an id already produced by
    /// `addHypotheticalIncome` (i.e. taken from that modification's own `ActiveModification.id`).
    @discardableResult
    func editHypotheticalIncome(id: UUID, name: String, amount: Decimal) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHypotheticalName(trimmedName), Self.isValidHypotheticalAmount(amount) else { return false }
        engine.apply(AddScenarioItemAction(ledger: .income, timing: .beginningMonth, itemName: trimmedName, amount: amount, id: id))
        return true
    }

    /// PHASE 6 — Part 1: the Fixed Bill counterpart to `editHypotheticalIncome(id:name:amount:)`,
    /// same id-reuse mechanism.
    @discardableResult
    func editHypotheticalFixedBill(id: UUID, name: String, amount: Decimal, timing: PlanTiming, referenceDate: Date? = nil) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHypotheticalName(trimmedName), Self.isValidHypotheticalAmount(amount) else { return false }
        engine.apply(AddScenarioItemAction(ledger: .expense, timing: timing, itemName: trimmedName, amount: amount, referenceDate: referenceDate, id: id))
        return true
    }

    /// Overrides the real item `itemID`'s amount for the Scenario result only. `amount` must be
    /// zero or greater (existing amount-field convention — see `CurrencyAmountField`'s
    /// `allowsZero`).
    @discardableResult
    func changeItemAmount(_ itemID: UUID, newAmount: Decimal) -> Bool {
        guard newAmount >= 0 else { return false }
        engine.apply(ChangeScenarioItemAmountAction(id: itemID, newAmount: newAmount))
        return true
    }

    /// Overrides the ONE Monthly Savings Goal for the Scenario result only — the real
    /// `MonthlyPlanSettings.monthlySavingsGoal` is never touched (see `scenarioPlanSettings`'s own
    /// header). `newGoal` must be zero or greater, matching the existing amount-field convention.
    /// Only Change is supported for this category — there is nothing to Add or Remove (there is
    /// only one goal).
    @discardableResult
    func changeMonthlySavingsGoal(_ newGoal: Decimal) -> Bool {
        guard newGoal >= 0 else { return false }
        engine.apply(ChangeMonthlySavingsGoalAction(newGoal: newGoal))
        return true
    }

    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 9) — overrides the ONE Planned Weekly
    /// Spending for the Scenario result only. `newAmount` must be zero or greater, matching the
    /// existing amount-field convention. Only Change is supported (there is only one value).
    @discardableResult
    func changePlannedWeeklySpending(_ newAmount: Decimal) -> Bool {
        guard newAmount >= 0 else { return false }
        engine.apply(ChangePlannedWeeklySpendingAction(newAmount: newAmount))
        return true
    }

    /// Removes exactly one active modification from the Builder's Active Changes list —
    /// `ScenarioEngine.removeAction(id:)` deterministically rebuilds `items` from baseline plus
    /// whatever remains; nothing here reverses the removed modification's specific effect.
    func removeModification(_ modificationID: UUID) {
        engine.removeAction(id: modificationID)
    }

    /// Restores every temporary change back to the real baseline snapshot captured at `init` —
    /// discards every active modification. Never re-reads SwiftData, never touches the real
    /// Monthly Plan (there is nothing to touch: the real plan was never mutated in the first
    /// place).
    func reset() {
        engine.reset()
    }

    // MARK: - Validation

    static func isValidHypotheticalName(_ trimmedName: String) -> Bool {
        !trimmedName.isEmpty
    }

    static func isValidHypotheticalAmount(_ amount: Decimal?) -> Bool {
        guard let amount else { return false }
        return amount > 0
    }

    // MARK: - Active Changes review

    /// One row per active modification, in application order — derived fresh from
    /// `engine.activeActions`/`engine.baselineItems` every access; never a second, independently
    /// mutated store, so it can never drift from what `engine.items` actually reflects. A future
    /// action type not recognized below still renders (generically, via `action.name`) rather than
    /// being dropped — extending this mapping when a future phase adds a richer action type never
    /// requires touching `ScenarioEngine`'s own calculation path.
    var activeModifications: [ActiveModification] {
        engine.activeActions.map { action in
            if let add = action as? AddScenarioItemAction {
                return ActiveModification(id: add.id, context: context(for: add.ledger, timing: add.timing), kind: add.name, itemName: add.itemName, originalAmount: nil, newAmount: add.amount)
            }
            if let remove = action as? RemoveScenarioItemAction {
                let source = engine.baselineItems.first { $0.id == remove.id }
                return ActiveModification(id: remove.id, context: context(for: source), kind: remove.name, itemName: source?.name ?? "", originalAmount: source?.amount, newAmount: nil)
            }
            if let change = action as? ChangeScenarioItemAmountAction {
                let source = engine.baselineItems.first { $0.id == change.id }
                return ActiveModification(id: change.id, context: context(for: source), kind: change.name, itemName: source?.name ?? "", originalAmount: source?.amount, newAmount: change.newAmount)
            }
            if let changeGoal = action as? ChangeMonthlySavingsGoalAction {
                return ActiveModification(id: changeGoal.id, context: .monthlySavingsGoal, kind: changeGoal.name, itemName: "Monthly Savings Goal", originalAmount: currentMonthlySavingsGoal, newAmount: changeGoal.newGoal)
            }
            if let changeWeekly = action as? ChangePlannedWeeklySpendingAction {
                return ActiveModification(id: changeWeekly.id, context: .plannedWeeklySpending, kind: changeWeekly.name, itemName: "Planned Weekly Spending", originalAmount: currentPlannedWeeklySpending, newAmount: changeWeekly.newAmount)
            }
            return ActiveModification(id: action.id, context: .income, kind: action.name, itemName: action.name, originalAmount: nil, newAmount: nil)
        }
    }

    private func context(for source: ScenarioLineItem?) -> ModificationContext {
        guard let source else { return .income }
        return context(for: source.ledger, timing: source.timing)
    }

    private func context(for ledger: ScenarioLedger, timing: PlanTiming) -> ModificationContext {
        ledger == .income ? .income : .fixedBill(timing: timing)
    }
}
