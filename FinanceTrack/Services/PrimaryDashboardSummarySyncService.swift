import Foundation

/// USER B DASHBOARD PARITY — the client-side push half of authoritative Dashboard aggregate
/// sharing (migration 0019). Computes the SAME five Dashboard totals the Primary's own device
/// already shows, using the EXACT SAME canonical `MonthlyPlanCalculator`/`BudgetCalculator`
/// formulas `DashboardView` itself uses (never duplicated here) — over the Primary's FULL local
/// transaction set, the exact same collection `DashboardView.monthlyPlanSummary` itself sums over.
///
/// LOCKED PRODUCT DECISION — this aggregate is shared as a whole under the existing `monthlyPlan`
/// sharing permission (the same authorization gate `DashboardView.secondaryOutlookAuthorized`
/// already uses); it is NOT additionally filtered by which individual Connected/Manual Accounts are
/// shared. An earlier revision filtered the transaction set down to only explicitly-shared
/// accounts, which silently excluded any transaction with no `Account` relationship at all (e.g. a
/// general Dashboard "Add Expense" entry never assigned to a Manual Account) — since such a
/// transaction structurally has no account identity to check against, it was ALWAYS excluded
/// regardless of sharing state, producing a Secondary aggregate that didn't match the Primary's own
/// Dashboard even when full parity was intended. Reusing the single `monthlyPlan` gate (which
/// already controls whether a Secondary receives ANY of these five numbers) as the sole
/// authorization boundary for the aggregate — rather than a second, per-account filter meant for
/// raw transaction sharing — guarantees `User B aggregate == User A Dashboard` whenever sharing is
/// authorized, with no second formula and no second filter to drift out of sync.
///
/// LOCAL-AUTHORITATIVE / FAIL-SAFE — same posture as `SavingsSummarySyncService`: a best-effort
/// background push. A failed upload never mutates local state and never surfaces a blocking error;
/// the next successful trigger re-sends the current correct totals. No polling, no timer, no
/// deferred-dispatch scheduling of any kind — every call site is an existing user action or
/// app-lifecycle event (see `DashboardView`'s own call sites, mirroring `syncSavingsSummaryIfNeeded`).
///
/// PRIVACY — never uploads: individual transactions, merchant/account names, or the local
/// per-transaction review/exclusion state (`isExcludedFromReports`/`countsTowardWeeklyBudget`/
/// `countsTowardMonthlySpending`) — only the five already-computed aggregate totals (plus the
/// optional `monthlySpendingBudget` consistency figure) ever leave this device.
///
/// USER B WEEKLY PARITY — `weeklySpendingLimit` is SUPPLIED by the caller (`authoritativeWeeklyLimit`),
/// never independently recomputed here. `DashboardView`'s own visible Weekly Limit is computed
/// live via the shared `MonthlyPlanCalculator.effectivePlannedWeeklySpending` authority
/// (`plannedWeeklySpendingForOutlook`) — URGENT REGRESSION FIX: never `BudgetSettings.
/// weeklySpendingLimit` directly anymore, since that stored field is only a snapshot refreshed by
/// Monthly Plan/Settings' own reconciliation triggers and could show a stale (or default-zero)
/// number here otherwise. Passing the same value DashboardView already shows guarantees
/// `User B Weekly Limit == User A displayed Weekly Limit`, with no second formula.
///
/// USER B MONTHLY OUTLOOK / CURRENT WEEK-BY-WEEK PARITY — `monthlyOutlookBudgeted` is SUPPLIED by
/// the caller (`BudgetSettings.monthlyGoal`, the same figure `DashboardView`'s own Monthly Outlook
/// card displays as "Budgeted") — never `flexibleSpendingAvailable`/`monthly_spending_budget`, a
/// distinct figure. The Monthly Outlook Actual/Projected Savings/Status figures reuse this
/// service's own already-computed `summary` (`actualSpentThisMonth`/`projectedMonthlySavings`/
/// `projectedStatus`) — the exact same formula `DashboardView.monthlyPlanSummary` uses, since both
/// are `MonthlyPlanCalculator.summary` over the same inputs. `currentWeekIndex` is SUPPLIED by the
/// caller using the SAME effective/current-week selection logic `DashboardView`'s own
/// `weekByWeekSection` uses (`weeklyComparisons.firstIndex(where: { $0.weekInterval.contains(.now) })`)
/// — never defaulted to 0 here. When `currentWeekIndex` is `nil` or out of range, no current-plan-week
/// fields are uploaded (they upload as `NULL`), never a guessed/first-week fallback.
enum PrimaryDashboardSummarySyncService {
    /// Computes and uploads the authoritative shared Dashboard aggregate from the Primary's FULL
    /// local transaction set — reuses `MonthlyPlanCalculator.summary`/`monthlySpendRemaining`/
    /// `moneyAfterBills`/`monthlySpendingBudget` and `BudgetCalculator.remaining` unmodified,
    /// exactly the same call sequence `DashboardView`'s own `monthlyPlanSummary`/
    /// `monthlySpendRemaining` computed properties use for the Primary's own local totals.
    /// `authoritativeWeeklyLimit` must be the SAME value `DashboardView`'s own `weeklyLimit`
    /// (`plannedWeeklySpendingForOutlook`) currently displays — never recomputed here.
    /// MONTHLY OUTLOOK + SCENARIO PERIOD-CASH-FLOW CORRECTION — `monthlyOutlookBudgeted` must now
    /// be Planned Monthly Spending (Planned Weekly Spending × 4 — see `DashboardView`'s own
    /// `plannedMonthlySpendingForOutlook`), never `BudgetSettings.monthlyGoal` (which mirrors the
    /// Savings Goal, not planned spending). `currentWeekIndex` must be
    /// the SAME effective/current index into `weeklyComparisons` `DashboardView`'s own
    /// `weekByWeekSection` selects — `nil` when there is no valid current comparison.
    static func sync(
        transactions: [FinanceTransaction],
        incomeSources: [IncomeSource],
        recurringExpenses: [RecurringExpense],
        planSettings: MonthlyPlanSettings?,
        authoritativeWeeklyLimit: Decimal,
        monthlyOutlookBudgeted: Decimal?,
        currentWeekIndex: Int?,
        weekInterval: DateInterval,
        monthInterval: DateInterval,
        weekStartsOnSunday: Bool,
        includePending: Bool,
        warningThreshold: Double,
        autoTrackedAccountIds: Set<String> = [],
        excludedTransactionIDs: Set<UUID> = [],
        backend: HouseholdSharingService = SupabaseHouseholdSharingService()
    ) async {
        let summary = MonthlyPlanCalculator.summary(
            month: monthInterval,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: planSettings,
            weeklyBudgetLimit: 0,
            transactions: transactions,
            weekInterval: weekInterval,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold,
            autoTrackedAccountIds: autoTrackedAccountIds,
            excludedTransactionIDs: excludedTransactionIDs
        )

        // FIXED BILLS UNIFICATION PARITY — replicates `DashboardView`'s own
        // `correctedFlexibleSpendingAvailableForOutlook` exactly: the corrected Fixed Bills total
        // (`FixedBillsTimingFilter.displayedTotal`, not the legacy frequency-converted
        // `estimatedMonthlyFixedExpenses`) PLUS Bill Payment Variance (planned vs. actually paid
        // per bill this month). Before this fix, this service used the OLD `moneyAfterBills`/
        // `monthlySpendingBudget` pipeline, which predates the Fixed Bills Unification work and
        // never applied either correction — so a Secondary's Monthly Remaining silently diverged
        // from the Primary's own displayed figure by exactly the bill-payment-variance amount
        // whenever a bill was paid for more or less than planned.
        let correctedFixedBillsTotal = FixedBillsTimingFilter.displayedTotal(for: recurringExpenses.filter { $0.isActive })
        let correctedPlannedFlexibleSpendingAvailable = summary.estimatedMonthlyIncome - correctedFixedBillsTotal - summary.monthlySavingsGoal - summary.bufferAmount
        let billVariance = MonthlyPlanCalculator.billPaymentVariance(
            recurringExpenses: recurringExpenses,
            transactions: transactions,
            in: monthInterval
        )
        let correctedFlexibleSpendingAvailable = correctedPlannedFlexibleSpendingAvailable + billVariance
        let monthlySpendingBudget = max(0, correctedFlexibleSpendingAvailable)
        let monthlySpendRemaining = MonthlyPlanCalculator.monthlySpendRemaining(
            monthlySpendingBudget: monthlySpendingBudget,
            actualMonthlySpending: summary.actualSpentThisMonth
        )
        let weeklyRemaining = BudgetCalculator.remaining(limit: authoritativeWeeklyLimit, spent: summary.actualSpentThisWeek)

        // MONTHLY OUTLOOK + SCENARIO PERIOD-CASH-FLOW CORRECTION — the planning-workflow
        // Projected Savings (Part 3/4), the SAME `MonthlyPlanCalculator` planning functions
        // `DashboardView`'s own `projectedMonthlySavingsForOutlook` uses, applied to this
        // function's own `summary`/`planSettings` — one shared calculation path, never a second
        // formula. `summary.projectedMonthlySavings` (the legacy actual-spending formula) is left
        // completely unused here now. FIXED BILLS UNIFICATION PARITY carries through here too:
        // `effectivePlannedWeeklySpending` is fed the corrected `correctedFlexibleSpendingAvailable`
        // (Fixed Bills total + bill-payment-variance), not the legacy `summary.flexibleSpendingAvailable`.
        let plannedWeeklySpending = MonthlyPlanCalculator.effectivePlannedWeeklySpending(
            override: planSettings?.plannedWeeklySpendingOverride,
            flexibleSpendingAvailable: correctedFlexibleSpendingAvailable
        )
        let plannedMonthlySpendingFromPlan = MonthlyPlanCalculator.plannedMonthlySpending(plannedWeeklySpending: plannedWeeklySpending)
        let additionalPlannedSavings = MonthlyPlanCalculator.additionalPlannedSavings(
            flexibleSpendingAvailable: correctedFlexibleSpendingAvailable,
            plannedMonthlySpending: plannedMonthlySpendingFromPlan
        )
        let projectedMonthlySavingsFromPlan = MonthlyPlanCalculator.projectedSavingsFromPlannedSpending(
            monthlySavingsGoal: summary.monthlySavingsGoal,
            additionalPlannedSavings: additionalPlannedSavings
        )
        let statusFromPlan = MonthlyPlanCalculator.monthlyPlanStatus(projectedSavings: projectedMonthlySavingsFromPlan, savingsGoal: summary.monthlySavingsGoal)

        var currentPlanWeek: UpsertDashboardSummaryRequest.CurrentPlanWeek?
        if let currentWeekIndex, summary.weeklyComparisons.indices.contains(currentWeekIndex) {
            let comparison = summary.weeklyComparisons[currentWeekIndex]
            currentPlanWeek = UpsertDashboardSummaryRequest.CurrentPlanWeek(
                index: currentWeekIndex,
                number: currentWeekIndex + 1,
                startDate: comparison.weekInterval.start,
                endDate: comparison.weekInterval.end,
                recommended: comparison.recommendedLimit,
                actual: comparison.actualSpent,
                remaining: comparison.remaining,
                status: comparison.status,
                calendar: .current
            )
        }

        // USER B FULL WEEK-BY-WEEK PARITY — ALL 4 of this month's weeks (`summary.weeklyComparisons`
        // itself always has exactly 4 entries for the month, a future week simply reading as $0
        // actual with its full recommended/remaining), freshly recomputed and pushed every call —
        // never an incrementally-cached/appended value. A past week's totals naturally settle to
        // their final numbers the moment that week is over; nothing here needs to remember or merge
        // a prior push's array.
        let weeklyComparisonsForUpload = summary.weeklyComparisons.enumerated().map { index, comparison in
            UpsertDashboardSummaryRequest.CurrentPlanWeek(
                index: index,
                number: index + 1,
                startDate: comparison.weekInterval.start,
                endDate: comparison.weekInterval.end,
                recommended: comparison.recommendedLimit,
                actual: comparison.actualSpent,
                remaining: comparison.remaining,
                status: comparison.status,
                calendar: .current
            )
        }

        _ = try? await backend.upsertDashboardSummary(
            UpsertDashboardSummaryRequest(
                actualSpentThisMonth: summary.actualSpentThisMonth,
                monthlySpendRemaining: monthlySpendRemaining,
                weeklySpendingLimit: authoritativeWeeklyLimit,
                actualSpentThisWeek: summary.actualSpentThisWeek,
                weeklyRemaining: weeklyRemaining,
                monthlySpendingBudget: monthlySpendingBudget,
                monthlyOutlookBudgeted: monthlyOutlookBudgeted,
                monthlyOutlookActual: summary.actualSpentThisMonth,
                monthlyOutlookProjectedSavings: projectedMonthlySavingsFromPlan,
                monthlyOutlookStatus: statusFromPlan,
                currentPlanWeek: currentPlanWeek,
                additionalPlannedSavings: additionalPlannedSavings,
                weeklyComparisons: weeklyComparisonsForUpload
            )
        )
    }
}
