import SwiftUI

/// Premium hero card summarizing the Monthly Plan: income, fixed bills, savings goal, flexible
/// spending, current weekly budget, projected savings, and a projected-savings status line. All
/// numbers are passed in already computed by `MonthlyPlanCalculator` — this view does no math
/// itself.
struct MonthlyPlanHeroCard: View {
    let summary: MonthlyPlanCalculator.Summary
    /// FIXED BILLS $40 DISCREPANCY FIX — the Fixed Bills total and its downstream Flexible
    /// Spending Available figure, computed by the caller via `FixedBillsTimingFilter.displayedTotal`
    /// (the same raw-sum authority as the Fixed Bills list screen and the Scenario Bill Groups),
    /// never `summary.estimatedMonthlyFixedExpenses`/`summary.flexibleSpendingAvailable` — those
    /// apply a frequency-based monthly-equivalent conversion this card's total must not reintroduce.
    let correctedFixedBillsTotal: Decimal
    let correctedFlexibleSpendingAvailable: Decimal
    /// URGENT MONTHLY PLAN CALCULATION CORRECTION (Part 3/5) — the planning-workflow values,
    /// computed by the caller via `MonthlyPlanCalculator`'s planning functions (the same ones
    /// `MonthlyPlanScenarioViewModel` uses) and passed in fully computed, exactly like every other
    /// number this card shows — this view still does no math of its own. Replaces the prior
    /// `summary.currentManualWeeklyBudget`/`summary.projectedMonthlySavings` (the actual-spending
    /// formula) on THIS card only; `summary.projectedMonthlySavings` itself is UNCHANGED and still
    /// drives Dashboard/sync/query-engine consumers elsewhere — see
    /// `MonthlyPlanCalculator.projectedSavingsFromActualSpending`'s own header.
    let plannedWeeklySpending: Decimal
    let isPlannedWeeklySpendingCustom: Bool
    /// WEEKLY SPENDING UNIFICATION (Parts 9-11) — Flexible Spending Available minus Planned
    /// Weekly Spending × 4 (`MonthlyPlanCalculator.additionalPlannedSavings`, computed by the
    /// caller exactly like every other number this card shows). Distinct from, and shown
    /// alongside, `projectedMonthlySavingsFromPlan` — never combined into one unlabeled number.
    let projectedAvailableAfterSpend: Decimal
    let projectedMonthlySavingsFromPlan: Decimal
    var isPrivacyModeEnabled: Bool = false

    /// Derived from the SAME planning-based projection this card displays — never
    /// `summary.projectedStatus` (which reflects the actual-spending formula and could disagree
    /// with what's shown here).
    private var projectedStatus: SpendingStatus {
        MonthlyPlanCalculator.monthlyPlanStatus(projectedSavings: projectedMonthlySavingsFromPlan, savingsGoal: summary.monthlySavingsGoal)
    }

    private var statusMessage: String {
        switch projectedStatus {
        case .good: return "On track to save"
        case .warning: return "Savings goal at risk"
        case .over: return "Overspending"
        }
    }

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Monthly Plan")
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Projected for this month")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    StatusBadge(status: projectedStatus)
                }

                VStack(spacing: Theme.Spacing.sm) {
                    amountRow(title: "Monthly Income", amount: summary.estimatedMonthlyIncome, color: Theme.statusGood)
                    amountRow(title: "Fixed Bills", amount: correctedFixedBillsTotal, color: Theme.statusOver, prefix: "-")
                    amountRow(title: "Savings Goal", amount: summary.monthlySavingsGoal, color: Theme.textSecondary, prefix: "-")
                    if summary.bufferAmount > 0 {
                        amountRow(title: "Buffer", amount: summary.bufferAmount, color: Theme.textSecondary, prefix: "-")
                    }
                    Divider().overlay(Theme.cardStroke)
                    amountRow(title: "Flexible Spending Available", amount: correctedFlexibleSpendingAvailable, color: Theme.textPrimary, emphasized: true)
                }

                // HERO CARD LAYOUT CORRECTION — two-column top row (Planned Weekly Spending /
                // Projected Available After Spend) with Projected Monthly Savings as its own row
                // directly beneath the left column, never all three crammed into one three-column
                // HStack (the prior layout, which forced "Projected Available After Spend" to
                // truncate/scale down). `amountColumn` itself no longer clips or shrinks its
                // title — see that function's own header.
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                        amountColumn(
                            title: "Planned Weekly Spending",
                            amount: plannedWeeklySpending,
                            subtitle: isPlannedWeeklySpendingCustom ? "Custom" : "Automatic"
                        )
                        amountColumn(title: "Projected Available After Spend", amount: projectedAvailableAfterSpend)
                    }
                    amountColumn(title: "Projected Monthly Savings", amount: projectedMonthlySavingsFromPlan)
                }

                Text(statusMessage)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.statusColor(for: summary.projectedStatus))
            }
        }
    }

    @ViewBuilder
    private func amountRow(title: String, amount: Decimal, color: Color, prefix: String = "", emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(emphasized ? Theme.bodyFont : Theme.captionFont)
                .foregroundStyle(emphasized ? Theme.textPrimary : Theme.textTertiary)
            Spacer()
            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: emphasized ? Theme.headlineFont : Theme.bodyFont,
                color: color,
                prefix: prefix
            )
        }
    }

    /// HERO CARD LAYOUT CORRECTION — the title is no longer clipped to one line or force-shrunk
    /// to fit (both were the prior layout's workaround for cramming three columns into one row);
    /// it now wraps naturally across as many lines as its full text needs, exactly like the
    /// required "Projected Available After Spend" label, while keeping the same font
    /// size/weight/color this app already used here.
    @ViewBuilder
    private func amountColumn(title: String, amount: Decimal, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.bodyFont,
                color: Theme.textPrimary
            )
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    MonthlyPlanHeroCard(
        summary: .init(
            estimatedMonthlyIncome: 4600,
            estimatedMonthlyFixedExpenses: 2305,
            monthlySavingsGoal: 500,
            bufferAmount: 100,
            flexibleSpendingAvailable: 1695,
            spendingWeeksInMonth: 5,
            recommendedWeeklySpendingLimit: 339,
            currentManualWeeklyBudget: 350,
            actualSpentThisMonth: 610,
            actualSpentThisWeek: 120,
            projectedMonthlySavings: 685,
            projectedStatus: .good,
            weeklyComparisons: []
        ),
        correctedFixedBillsTotal: 2305,
        correctedFlexibleSpendingAvailable: 1695,
        plannedWeeklySpending: 423.75,
        isPlannedWeeklySpendingCustom: false,
        projectedAvailableAfterSpend: 0,
        projectedMonthlySavingsFromPlan: 500
    )
    .padding()
    .background(Theme.backgroundGradient)
}
