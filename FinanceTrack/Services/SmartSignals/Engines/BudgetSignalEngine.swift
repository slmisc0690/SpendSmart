import Foundation

/// Weekly and monthly budget-status observations — "have I exceeded, nearly reached, passed the
/// halfway point of, or comfortably stayed under my configured spending limit." Every spending
/// total, progress fraction, remaining amount, and over-budget amount comes from
/// `BudgetCalculator`; this engine only decides which observation those numbers describe and
/// composes fixed, deterministic copy around them. It never sums transactions, filters them by
/// eligibility, or recomputes anything `BudgetCalculator` already owns.
///
/// SpendSmart supports two independent, optional budgets, both read from `BudgetSettings`:
/// - **Weekly**: `weeklySpendingLimit` (always present; "no budget" is represented as `<= 0`,
///   matching `DashboardView`'s own `hasWeeklyBudget` check).
/// - **Monthly**: `monthlyGoal` (`Decimal?`; "no budget" is `nil` or `<= 0`).
///
/// Because these are independent, this engine may return one signal for each — never more than
/// one PRIMARY status signal per period, per the precedence in `signal(for:context:)`.
struct BudgetSignalEngine: SmartSignalEngine {

    // MARK: - Tunables

    /// Below this, spending is a routine "halfway" update rather than a "nearly reached" one.
    private static let nearlyReachedThreshold = 0.85
    private static let halfwayThreshold = 0.50

    /// How much of the budget period must already have elapsed before a "comfortably on track"
    /// positive signal is meaningful — firing this on day one of a new week/month would be
    /// trivially true and uninformative (almost nobody has spent much of anything yet).
    private static let minimumElapsedFractionForOnTrackSignal = 0.15
    /// Above this, there's enough of the period behind us to call the "on track" read high
    /// confidence rather than medium.
    private static let highConfidenceElapsedFraction = 0.40

    func generateSignals(context: SmartSignalContext) -> [SmartSignal] {
        [
            signal(for: .weekly, context: context),
            signal(for: .monthly, context: context),
        ].compactMap { $0 }
    }

    // MARK: - Period resolution

    private enum BudgetPeriod: String {
        case weekly
        case monthly
    }

    private struct ResolvedPeriod {
        let interval: DateInterval
        let limit: Decimal
    }

    /// `nil` when this period's budget is absent, zero, or otherwise not configured — the engine
    /// must produce no signal in every one of those cases, never guess at intent.
    private func resolvePeriod(_ period: BudgetPeriod, context: SmartSignalContext) -> ResolvedPeriod? {
        guard let settings = context.budgetSettings else { return nil }
        switch period {
        case .weekly:
            guard settings.weeklySpendingLimit > 0 else { return nil }
            let interval = DateRangeHelper.weekRangeContaining(context.now, weekStartsOnSunday: settings.weekStartsOnSunday)
            return ResolvedPeriod(interval: interval, limit: settings.weeklySpendingLimit)
        case .monthly:
            guard let monthlyGoal = settings.monthlyGoal, monthlyGoal > 0 else { return nil }
            let interval = DateRangeHelper.monthRangeContaining(context.now)
            return ResolvedPeriod(interval: interval, limit: monthlyGoal)
        }
    }

    // MARK: - Per-period evaluation

    private func signal(for period: BudgetPeriod, context: SmartSignalContext) -> SmartSignal? {
        guard let resolved = resolvePeriod(period, context: context) else { return nil }

        let includePending = context.budgetSettings?.includePendingTransactions ?? true
        let spent: Decimal
        switch period {
        case .weekly: spent = BudgetCalculator.weeklySpent(context.transactions, in: resolved.interval, includePending: includePending)
        case .monthly: spent = BudgetCalculator.monthlySpent(context.transactions, in: resolved.interval, includePending: includePending)
        }

        let warningThreshold = context.budgetSettings?.warningThreshold ?? 0.70
        let status = BudgetCalculator.status(spent: spent, limit: resolved.limit, warningThreshold: warningThreshold)
        let progress = BudgetCalculator.progress(spent: spent, limit: resolved.limit)
        let remaining = BudgetCalculator.remaining(limit: resolved.limit, spent: spent)
        let overage = BudgetCalculator.overBudgetAmount(spent: spent, limit: resolved.limit)

        // Precedence: exceeded > nearly-reached > halfway > comfortably-on-track. Each branch
        // returns at most one signal, so a single period can never produce more than one primary
        // status signal.
        if status == .over {
            return exceededSignal(period: period, resolved: resolved, spent: spent, overage: overage, progress: progress, context: context)
        }
        if progress >= Self.nearlyReachedThreshold {
            return nearlyReachedSignal(period: period, resolved: resolved, spent: spent, remaining: remaining, progress: progress, context: context)
        }
        if progress >= Self.halfwayThreshold {
            return halfwaySignal(period: period, resolved: resolved, spent: spent, remaining: remaining, progress: progress, context: context)
        }
        return onTrackSignal(period: period, resolved: resolved, spent: spent, remaining: remaining, progress: progress, context: context)
    }

    // MARK: - Signal construction

    private func exceededSignal(
        period: BudgetPeriod,
        resolved: ResolvedPeriod,
        spent: Decimal,
        overage: Decimal,
        progress: Double,
        context: SmartSignalContext
    ) -> SmartSignal {
        let noun = periodBudgetNoun(period)
        return SmartSignal(
            id: "budget.\(period.rawValue).exceeded",
            deduplicationID: "budget.\(period.rawValue).exceeded",
            category: .budget,
            severity: .important,
            confidence: .high,
            priority: 400,
            title: "\(periodAdjective(period)) \(noun.capitalizedNoun) Exceeded",
            explanation: "You've spent \(formatCurrency(spent)) against your \(formatCurrency(resolved.limit)) \(noun.lowercaseNoun) — \(formatCurrency(overage)) over.",
            metrics: [
                SmartSignalMetric(id: "budget.spent", label: "Spent", value: .currency(spent)),
                SmartSignalMetric(id: "budget.overage", label: "Over Budget", value: .currency(overage)),
                SmartSignalMetric(id: "budget.progress", label: "Progress", value: .percentage(progress)),
            ],
            action: nil,
            relevantDate: resolved.interval.start,
            evaluatedAt: context.now
        )
    }

    private func nearlyReachedSignal(
        period: BudgetPeriod,
        resolved: ResolvedPeriod,
        spent: Decimal,
        remaining: Decimal,
        progress: Double,
        context: SmartSignalContext
    ) -> SmartSignal {
        let noun = periodBudgetNoun(period)
        return SmartSignal(
            id: "budget.\(period.rawValue).nearly-reached",
            deduplicationID: "budget.\(period.rawValue).nearly-reached",
            category: .budget,
            severity: .headsUp,
            confidence: .high,
            priority: 300,
            title: "\(periodAdjective(period)) \(noun.capitalizedNoun) Nearly Reached",
            explanation: "You've used \(formatPercentage(progress)) of your \(periodAdjective(period).lowercased()) \(noun.lowercaseNoun), with \(formatCurrency(remaining)) remaining.",
            metrics: [
                SmartSignalMetric(id: "budget.progress", label: "Progress", value: .percentage(progress)),
                SmartSignalMetric(id: "budget.remaining", label: "Remaining", value: .currency(remaining)),
                SmartSignalMetric(id: "budget.spent", label: "Spent", value: .currency(spent)),
            ],
            action: nil,
            relevantDate: resolved.interval.start,
            evaluatedAt: context.now
        )
    }

    private func halfwaySignal(
        period: BudgetPeriod,
        resolved: ResolvedPeriod,
        spent: Decimal,
        remaining: Decimal,
        progress: Double,
        context: SmartSignalContext
    ) -> SmartSignal {
        let noun = periodBudgetNoun(period)
        return SmartSignal(
            id: "budget.\(period.rawValue).halfway",
            deduplicationID: "budget.\(period.rawValue).halfway",
            category: .budget,
            severity: .information,
            confidence: .high,
            priority: 200,
            title: "\(periodAdjective(period)) Spending Update",
            explanation: "You've used \(formatPercentage(progress)) of your \(periodAdjective(period).lowercased()) \(noun.lowercaseNoun), with \(formatCurrency(remaining)) remaining.",
            metrics: [
                SmartSignalMetric(id: "budget.progress", label: "Progress", value: .percentage(progress)),
                SmartSignalMetric(id: "budget.remaining", label: "Remaining", value: .currency(remaining)),
                SmartSignalMetric(id: "budget.spent", label: "Spent", value: .currency(spent)),
            ],
            action: nil,
            relevantDate: resolved.interval.start,
            evaluatedAt: context.now
        )
    }

    /// `nil` when the period hasn't been meaningfully underway long enough for a "comfortably on
    /// track" statement to be useful (see `minimumElapsedFractionForOnTrackSignal`) — this is the
    /// only status branch that can legitimately produce no signal at all for a configured budget.
    private func onTrackSignal(
        period: BudgetPeriod,
        resolved: ResolvedPeriod,
        spent: Decimal,
        remaining: Decimal,
        progress: Double,
        context: SmartSignalContext
    ) -> SmartSignal? {
        let elapsed = elapsedFraction(of: resolved.interval, now: context.now)
        guard elapsed >= Self.minimumElapsedFractionForOnTrackSignal else { return nil }

        let noun = periodBudgetNoun(period)
        let confidence: SmartSignalConfidence = elapsed >= Self.highConfidenceElapsedFraction ? .high : .medium
        return SmartSignal(
            id: "budget.\(period.rawValue).on-track",
            deduplicationID: "budget.\(period.rawValue).on-track",
            category: .positive,
            severity: .positive,
            confidence: confidence,
            priority: 100,
            title: "\(periodAdjective(period)) Spending On Track",
            explanation: "You're currently using less than half of your \(periodAdjective(period).lowercased()) \(noun.lowercaseNoun), with \(formatCurrency(remaining)) remaining.",
            metrics: [
                SmartSignalMetric(id: "budget.progress", label: "Progress", value: .percentage(progress)),
                SmartSignalMetric(id: "budget.remaining", label: "Remaining", value: .currency(remaining)),
                SmartSignalMetric(id: "budget.spent", label: "Spent", value: .currency(spent)),
            ],
            action: nil,
            relevantDate: resolved.interval.start,
            evaluatedAt: context.now
        )
    }

    // MARK: - Helpers

    /// Fraction (0...1) of `interval` that has elapsed as of `now` — plain `DateInterval`
    /// arithmetic, not a budget calculation, so it stays here rather than in `BudgetCalculator`.
    private func elapsedFraction(of interval: DateInterval, now: Date) -> Double {
        guard interval.duration > 0 else { return 1 }
        let elapsed = now.timeIntervalSince(interval.start)
        return min(max(elapsed / interval.duration, 0), 1)
    }

    private func periodAdjective(_ period: BudgetPeriod) -> String {
        switch period {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    private struct PeriodNoun {
        let capitalizedNoun: String
        let lowercaseNoun: String
    }

    private func periodBudgetNoun(_ period: BudgetPeriod) -> PeriodNoun {
        switch period {
        case .weekly: return PeriodNoun(capitalizedNoun: "Spending Limit", lowercaseNoun: "spending limit")
        case .monthly: return PeriodNoun(capitalizedNoun: "Budget", lowercaseNoun: "monthly budget")
        }
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
    }

    private func formatPercentage(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
