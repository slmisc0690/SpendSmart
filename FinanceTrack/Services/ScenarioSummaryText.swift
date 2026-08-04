import Foundation

/// Pure, UIKit/SwiftUI-independent text generation for the Scenario Builder's "explain why the
/// numbers changed" surfaces (Scenario Summary card, negative-result explanations, weekly-status
/// wording). Kept separate from `MonthlyPlanScenarioView` so every rule here is directly unit
/// testable without rendering — the same "prefer a testable helper over source scans" pattern
/// established for `ScenarioSummaryBuilder`/`ScenarioLineItem`.
enum ScenarioSummaryText {
    /// One line describing a single active modification, e.g. "Added Freelance Project
    /// (+$400.00)", "Removed VA Income (-$2,600.00)", "Electric (Mid-Month) $180.00 → $250.00".
    /// Purely a presentation transform over `MonthlyPlanScenarioViewModel.ActiveModification` — no
    /// new calculation. Fixed Bills carry their real timing label parenthetically ("Fixed Bills
    /// entries should show their real names and timing labels"); Income/Monthly Savings Goal don't
    /// repeat their own group label here since it would be redundant with the item name.
    static func modificationLine(for modification: MonthlyPlanScenarioViewModel.ActiveModification) -> String {
        let name: String
        if case .fixedBill(let timing) = modification.context {
            name = "\(modification.itemName) (\(timing.label))"
        } else {
            name = modification.itemName
        }
        switch (modification.originalAmount, modification.newAmount) {
        case let (nil, .some(newAmount)):
            return "Added \(name) (+\(CurrencyFormat.string(from: newAmount)))"
        case let (.some(originalAmount), nil):
            return "Removed \(name) (-\(CurrencyFormat.string(from: originalAmount)))"
        case let (.some(originalAmount), .some(newAmount)):
            return "\(name) \(CurrencyFormat.string(from: originalAmount)) \u{2192} \(CurrencyFormat.string(from: newAmount))"
        case (nil, nil):
            return name
        }
    }

    /// One line per Results metric that actually changed between `current` and `scenario` — never
    /// a line for a metric that didn't move ("Avoid unnecessary verbosity"). Never touches
    /// `monthlySavingsGoal` directly (that's a Scenario Summary bullet on its own via
    /// `modificationLine`, not a "changed by" result line).
    static func resultChangeLines(current: MonthlyPlanCalculator.Summary, scenario: MonthlyPlanCalculator.Summary) -> [String] {
        var lines: [String] = []
        let flexibleDelta = scenario.flexibleSpendingAvailable - current.flexibleSpendingAvailable
        if flexibleDelta != 0 {
            lines.append("Flexible Spending changed by \(signedCurrency(flexibleDelta))")
        }
        let savingsDelta = scenario.projectedMonthlySavings - current.projectedMonthlySavings
        if savingsDelta != 0 {
            lines.append("Projected Savings changed by \(signedCurrency(savingsDelta))")
        }
        let weeklyDelta = scenario.recommendedWeeklySpendingLimit - current.recommendedWeeklySpendingLimit
        if weeklyDelta != 0 {
            lines.append("Weekly Spending changed by \(signedCurrency(weeklyDelta))")
        }
        return lines
    }

    // MARK: - PHASE 7 — Part 4: Results row info explanations

    /// Plain-English explanation for a "[Timing] Bills Total" Results row — what it means, how
    /// it's calculated, and which bills contributed. Never mentions income, since this total is
    /// bills-only by design (see `MonthlyPlanScenarioView.resultsSection`'s own comment on why an
    /// income-only change correctly never moves this number).
    static func billsTotalExplanation(for timing: PlanTiming, items: [ScenarioLineItem]) -> String {
        let names = items.filter { $0.ledger == .expense && $0.isIncluded && $0.timing == timing }.map(\.name)
        // CASH-FLOW CORRECTIVE PHASE: required exact wording for this row's info button.
        let intro = "This compares bill group totals only. Income changes do not affect this value. This adds up every bill you've marked as due \(timing.label.lowercased()) — it is NOT the cumulative Bills Due Through cutoff value shown in the Cash Flow cards above, which adds every bill occurrence across the whole period instead of just this one timing group."
        if names.isEmpty {
            return "\(intro) Right now, no bills are marked for this time, so this total is $0.00."
        }
        return "\(intro) Right now that's: \(names.joined(separator: ", "))."
    }

    /// Plain-English explanation for an "Extra Spending After [cutoff] Bills" Results row — what
    /// it means, how it's calculated, and which income/bills contributed. `.endMonth` describes
    /// the WHOLE month (matching `MonthlyPlanScenarioViewModel.scenarioExtraSpendingAfter(_:)`'s
    /// own routing of `.endMonth` straight to `flexibleSpendingAvailable`, the true whole-month
    /// figure); every other cutoff describes only the eligible (at-or-before-cutoff) subset via
    /// `ScenarioSummaryBuilder.itemsEligibleThroughCutoff`.
    static func extraSpendingExplanation(for cutoff: PlanTiming, items: [ScenarioLineItem]) -> String {
        let eligible = cutoff == .endMonth
            ? items.filter(\.isIncluded)
            : ScenarioSummaryBuilder.itemsEligibleThroughCutoff(items: items, cutoff: cutoff)
        let incomeNames = eligible.filter { $0.ledger == .income }.map(\.name)
        let billNames = eligible.filter { $0.ledger == .expense }.map(\.name)

        var text: String
        if cutoff == .endMonth {
            text = "This shows how much money you'd have left over from your whole month's income, after covering every bill and setting aside your Monthly Savings Goal."
        } else {
            text = "This shows how much money you'd have left over from your income covering only the bills due by \(cutoff.label.lowercased()), after setting aside your Monthly Savings Goal. Bills that don't have a fixed spot in the month — like weekly bills or ones on a specific custom date — aren't included here."
        }

        if incomeNames.isEmpty && billNames.isEmpty {
            text += " Right now there's nothing counted toward this yet."
        } else {
            if !incomeNames.isEmpty {
                text += " Income counted: \(incomeNames.joined(separator: ", "))."
            }
            if !billNames.isEmpty {
                text += " Bills counted: \(billNames.joined(separator: ", "))."
            }
        }
        return text
    }

    // MARK: - SCHEDULE UX PHASE — Part 9/10/11: Average Monthly Flexible Spending / Projected Monthly Savings

    /// Plain-English explanation for "Average Monthly Flexible Spending" — confirms it is a
    /// MONTHLY-AVERAGE planning figure (investigation finding: `estimatedMonthlyIncome`/
    /// `estimatedMonthlyFixedExpenses` convert every item's frequency to a monthly-equivalent
    /// amount — e.g. a paycheck every 2 weeks × 26 ÷ 12 — never actual per-occurrence dates), so it
    /// is never expected to match the actual-date Mid-Month/End-of-Month Cash Flow figures unless
    /// the inputs genuinely happen to coincide.
    static func averageMonthlyFlexibleSpendingExplanation() -> String {
        "This is a monthly-average planning figure, not the actual cash you'll have on a specific date. It uses each income and bill's monthly-equivalent amount — for example, a paycheck every 2 weeks is averaged out to a monthly amount rather than counted on its real deposit dates. It already includes your Monthly Savings Goal. For the actual money you'll have by a specific date, use Mid-Month Cash Flow or End-of-Month Cash Flow instead — those may show a different number, and that's expected."
    }

    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 6/10) — the CORRECTED planning-workflow
    /// formula: Monthly Savings Goal + Additional Planned Savings, where Additional Planned
    /// Savings is whatever's left of Average Monthly Flexible Spending after Planned Weekly
    /// Spending × 4. Replaces the prior actual-spending-based explanation here — this Results row
    /// (and the Monthly Plan Planning section) now shows the plan-based figure, not an
    /// actual-spending forecast. `MonthlyPlanCalculator.projectedMonthlySavings(income:
    /// fixedExpenses:actualSpentThisMonth:)` itself is unchanged and still drives the Hero Card/
    /// Dashboard elsewhere — this explanation only covers the NEW planning value shown here.
    static func projectedMonthlySavingsExplanation() -> String {
        "Monthly Savings Goal plus Additional Planned Savings. Additional Planned Savings is the part of your Average Monthly Flexible Spending you haven't planned to spend (Planned Weekly Spending × 4). If your planned spending is higher than your flexible spending available, Additional Planned Savings — and this projection — can go negative; that's shown honestly, never hidden."
    }

    /// Part 10's exact required wording for "Planned Weekly Spending."
    static func plannedWeeklySpendingExplanation() -> String {
        "How much you plan to spend each week. Automatic mode divides Average Monthly Flexible Spending by 4; you can set your own amount instead, including $0.00."
    }

    /// Part 10's exact required wording for "Planned Monthly Spending."
    static func plannedMonthlySpendingExplanation() -> String {
        "Planned Weekly Spending × 4."
    }

    /// Part 10's exact required wording for "Additional Planned Savings."
    static func additionalPlannedSavingsExplanation() -> String {
        "The part of Average Monthly Flexible Spending not planned for spending. Can be negative if your planned spending is higher than what's available."
    }

    // MARK: - SCENARIO MONTHLY PLANNING CORRECTION — Monthly Planning info explanations
    //
    // These replace the removed "Average Monthly Flexible Spending"/"Planned Monthly Spending"
    // explanations FOR THIS SCENARIO SCREEN ONLY (that pair remains unchanged and still drives the
    // real Monthly Plan screen — see `averageMonthlyFlexibleSpendingExplanation`/
    // `plannedMonthlySpendingExplanation` above, untouched). Built exclusively from the two exact
    // period results, never a monthly-equivalent estimate.

    static func monthlyAvailableAfterBillsExplanation() -> String {
        "Mid-Month Remaining plus End-of-Month Remaining — the exact amount left over from your two periods' income after their bills, before any savings goal is set aside. Built directly from the Mid-Month and End-of-Month Period cards above, never a monthly-equivalent estimate."
    }

    static func plannedMonthlySpendingAvailableExplanation() -> String {
        "Monthly Available After Bills minus your Monthly Savings Goal — the total monthly amount actually available to spend after bills and planned savings. This is different from a manually chosen weekly amount × 4, which only reflects what you've decided to spend, not what's actually available."
    }

    /// Explains the Week-by-Week/Planned Weekly Spending card's Scenario weekly recommendation.
    /// SCENARIO MONTHLY PLANNING CORRECTION — the prior Custom-vs-Automatic distinction no longer
    /// exists here: Scenario Planned Weekly Spending is always Scenario Available After Planned
    /// Savings ÷ 4, unless an explicit Scenario override is active, in which case that always wins
    /// outright — exactly two mutually exclusive states.
    static func scenarioWeeklyRecommendationExplanation(isExplicitOverride: Bool) -> String {
        if isExplicitOverride {
            return "This amount was set directly in the Scenario."
        }
        return "Scenario Available After Planned Savings divided by 4 — the total monthly amount actually available under this Scenario, split evenly across four planning weeks."
    }

    // MARK: - CASH-FLOW CORRECTIVE PHASE: Mid-Month/End-of-Month Cash Flow info explanations

    /// Full contributor breakdown for a "[Mid-Month/End-of-Month] Cash Flow" Results row —
    /// exactly which income and bills were counted, their amounts, the totals, and the remaining
    /// figure — in plain language, matching this phase's own worked example format. `periodLabel`
    /// is e.g. "Mid-Month" or "End-of-Month". `activeModifications`, when supplied, appends a
    /// plain-language note for every active change (added/removed/changed) so a removed or
    /// adjusted item is always explained rather than silently absent from the contributor list.
    private static let contributorDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// EXACT-DATES PHASE: "Name — Aug 7 — $2,000" — one line per actual occurrence date, exactly
    /// this task's required contributor-line format (Part 15). Never groups multiple occurrences
    /// of the same item into one summed line — a paycheck landing twice before a cutoff must show
    /// as two separate dated lines.
    private static func contributorLine(_ contributor: ScenarioCashFlowCalculator.Contributor) -> String {
        "\(contributor.name) \u{2014} \(contributorDayFormatter.string(from: contributor.date)) \u{2014} \(CurrencyFormat.string(from: contributor.amount))"
    }

    static func cashFlowExplanation(
        periodLabel: String,
        breakdown: ScenarioCashFlowCalculator.Breakdown,
        activeModifications: [MonthlyPlanScenarioViewModel.ActiveModification] = []
    ) -> String {
        // MONTHLY OUTLOOK + SCENARIO PERIOD-CASH-FLOW CORRECTION (Part 10) — exact required
        // wording: "Total Income This Period" / "Bills This Period", not a periodLabel-prefixed
        // "[Mid-Month] Income Received" — the period name already appears in the card's own title.
        var lines: [String] = []
        lines.append("Income This Period")
        if breakdown.incomeContributors.isEmpty {
            lines.append("No income counted yet.")
        } else {
            lines.append(contentsOf: breakdown.incomeContributors.map(contributorLine))
        }
        lines.append("Total Income This Period: \(CurrencyFormat.string(from: breakdown.totalIncome))")
        lines.append("")
        lines.append("Bills This Period")
        if breakdown.billContributors.isEmpty {
            lines.append("No bills counted yet.")
        } else {
            lines.append(contentsOf: breakdown.billContributors.map(contributorLine))
        }
        lines.append("Total Bills This Period: \(CurrencyFormat.string(from: breakdown.totalBills))")
        if let savings = breakdown.savingsAllocated {
            lines.append("")
            lines.append("Monthly Savings Goal: \(CurrencyFormat.string(from: savings))")
        }
        lines.append("")
        lines.append("Remaining: \(CurrencyFormat.string(from: breakdown.remaining))")

        let notes = activeModifications.map { "\($0.itemName): \(cashFlowModificationNote(for: $0, periodLabel: periodLabel))" }
        if !notes.isEmpty {
            lines.append("")
            lines.append("Changes in this Scenario:")
            lines.append(contentsOf: notes)
        }

        return lines.joined(separator: "\n")
    }

    private static func cashFlowModificationNote(for modification: MonthlyPlanScenarioViewModel.ActiveModification, periodLabel: String) -> String {
        switch (modification.originalAmount, modification.newAmount) {
        case (.some, nil):
            return "Removed — not included in \(periodLabel) Scenario income/bills."
        case let (.some(original), .some(newAmount)):
            return "Changed from \(CurrencyFormat.string(from: original)) to \(CurrencyFormat.string(from: newAmount))."
        case let (nil, .some(newAmount)):
            return "Added at \(CurrencyFormat.string(from: newAmount))."
        case (nil, nil):
            return "Changed."
        }
    }

    private static func signedCurrency(_ amount: Decimal) -> String {
        amount >= 0 ? "+\(CurrencyFormat.string(from: amount))" : "-\(CurrencyFormat.string(from: -amount))"
    }

    /// A concise explanation for why the Scenario's Flexible Spending Available is negative —
    /// `nil` when it isn't negative (nothing to explain). Only mentions a cause genuinely present
    /// in `activeModifications` ("Only show explanations relevant to the current Scenario") rather
    /// than a generic message for every negative result.
    static func negativeFlexibleSpendingExplanation(
        scenarioFlexibleSpendingAvailable: Decimal,
        activeModifications: [MonthlyPlanScenarioViewModel.ActiveModification]
    ) -> String? {
        guard scenarioFlexibleSpendingAvailable < 0 else { return nil }

        let reducedIncome = activeModifications.contains { modification in
            guard modification.context == .income else { return false }
            if modification.newAmount == nil { return true }
            if let original = modification.originalAmount, let new = modification.newAmount { return new < original }
            return false
        }
        if reducedIncome {
            return "Removing the selected income causes planned monthly expenses to exceed available income."
        }

        let increasedSavingsGoal = activeModifications.contains { modification in
            guard modification.context == .monthlySavingsGoal else { return false }
            return (modification.newAmount ?? 0) > (modification.originalAmount ?? 0)
        }
        if increasedSavingsGoal {
            return "Your Monthly Savings Goal is reducing available discretionary spending."
        }

        return "Planned expenses exceed available income in this scenario."
    }

    /// Whether `comparison`'s week should show a special "no spending available" message instead
    /// of the normal Over Budget status. True only when there is genuinely nothing to spend against
    /// (the recommended weekly limit is zero or less) AND the user hasn't actually spent anything
    /// that week. If the user HAS spent something against a zero/negative limit, that remains
    /// genuine overspending, so this deliberately returns `false` and the normal
    /// `BudgetCalculator.status`-driven Over Budget display is preserved unchanged.
    static func isDiscretionarySpendingUnavailable(_ comparison: MonthlyPlanCalculator.WeeklyPlanComparison) -> Bool {
        comparison.recommendedLimit <= 0 && comparison.actualSpent <= 0
    }

    static let discretionarySpendingUnavailableTitle = "No Weekly Spending Available"
    static let discretionarySpendingUnavailableMessage = "Income no longer covers planned expenses."
}
