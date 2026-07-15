import Foundation

/// Weekly and monthly spending-trend observations — "is current spending materially higher than
/// the equivalent elapsed portion of the previous comparable period." Every spending total comes
/// from `BudgetCalculator`; this engine only resolves the comparable date windows and decides
/// whether the resulting totals cross a deliberately conservative threshold. It never sums or
/// filters transactions itself, and never reads or reasons about `BudgetSettings` limits — that
/// is `BudgetSignalEngine`'s responsibility, not this one's.
///
/// Both rules compare a partial current period against the SAME ELAPSED DURATION of the previous
/// comparable period (never the full previous period) — see `comparableIntervals`. This keeps an
/// early-in-the-period comparison fair: three days into this week is compared against the first
/// three days of last week, not all seven.
struct SpendingSignalEngine: SpendSenseEngine {

    // MARK: - Tunables

    private static let weeklyMinimumElapsedSeconds: TimeInterval = 48 * 3600
    private static let weeklyHighConfidenceElapsedSeconds: TimeInterval = 96 * 3600
    /// Exact Decimal 0.35 — built from integer division rather than a floating-point literal so
    /// boundary comparisons (`>=`) are never affected by binary floating-point imprecision.
    private static let weeklyPercentageThreshold = Decimal(35) / Decimal(100)
    private static let weeklyAbsoluteThreshold: Decimal = 50

    private static let monthlyMinimumElapsedSeconds: TimeInterval = 120 * 3600
    private static let monthlyHighConfidenceElapsedSeconds: TimeInterval = 240 * 3600
    private static let monthlyPercentageThreshold = Decimal(30) / Decimal(100)
    private static let monthlyAbsoluteThreshold: Decimal = 100

    func generateSignals(context: SpendSenseContext) -> [SpendSenseSignal] {
        let calendar = Calendar.current
        let weekStartsOnSunday = context.budgetSettings?.weekStartsOnSunday ?? true
        let includePending = context.budgetSettings?.includePendingTransactions ?? true

        var signals: [SpendSenseSignal] = []
        if let weekly = generateWeeklySignal(context: context, calendar: calendar, weekStartsOnSunday: weekStartsOnSunday, includePending: includePending) {
            signals.append(weekly)
        }
        if let monthly = generateMonthlySignal(context: context, calendar: calendar, includePending: includePending) {
            signals.append(monthly)
        }
        return signals
    }

    // MARK: - Weekly rule

    private func generateWeeklySignal(
        context: SpendSenseContext,
        calendar: Calendar,
        weekStartsOnSunday: Bool,
        includePending: Bool
    ) -> SpendSenseSignal? {
        let currentWeek = DateRangeHelper.weekRangeContaining(context.now, weekStartsOnSunday: weekStartsOnSunday, calendar: calendar)

        let elapsed = context.now.timeIntervalSince(currentWeek.start)
        guard elapsed >= Self.weeklyMinimumElapsedSeconds else { return nil }

        guard let previousWeekReference = calendar.date(byAdding: .day, value: -7, to: context.now) else { return nil }
        let previousWeek = DateRangeHelper.weekRangeContaining(previousWeekReference, weekStartsOnSunday: weekStartsOnSunday, calendar: calendar)

        guard let intervals = comparableIntervals(currentPeriod: currentWeek, previousPeriod: previousWeek, now: context.now) else { return nil }

        let currentSpend = BudgetCalculator.weeklySpent(context.transactions, in: intervals.current, includePending: includePending)
        let previousSpend = BudgetCalculator.weeklySpent(context.transactions, in: intervals.previous, includePending: includePending)

        guard previousSpend > 0, currentSpend > previousSpend else { return nil }

        let absoluteIncrease = currentSpend - previousSpend
        let percentageIncrease = absoluteIncrease / previousSpend
        guard percentageIncrease >= Self.weeklyPercentageThreshold, absoluteIncrease >= Self.weeklyAbsoluteThreshold else { return nil }

        let confidence: SpendSenseConfidence = elapsed >= Self.weeklyHighConfidenceElapsedSeconds ? .high : .medium
        let percentageIncreaseAsDouble = NSDecimalNumber(decimal: percentageIncrease).doubleValue

        return SpendSenseSignal(
            id: "spending.week.higher-than-previous",
            deduplicationID: "spending.week.higher-than-previous",
            category: .spending,
            severity: .headsUp,
            confidence: confidence,
            priority: 250,
            title: "Spending Up This Week",
            explanation: "You've spent \(formatCurrency(currentSpend)) so far this week, compared to \(formatCurrency(previousSpend)) during the same portion of last week — an increase of \(formatPercentage(percentageIncreaseAsDouble)).",
            metrics: [
                SpendSenseMetric(id: "spending.week.current", label: "This Week", value: .currency(currentSpend)),
                SpendSenseMetric(id: "spending.week.previous", label: "Previous Week", value: .currency(previousSpend)),
                SpendSenseMetric(id: "spending.week.increase", label: "Increase", value: .percentage(percentageIncreaseAsDouble)),
            ],
            action: nil,
            relevantDate: currentWeek.start,
            evaluatedAt: context.now
        )
    }

    // MARK: - Monthly rule

    private func generateMonthlySignal(
        context: SpendSenseContext,
        calendar: Calendar,
        includePending: Bool
    ) -> SpendSenseSignal? {
        let currentMonth = DateRangeHelper.monthRangeContaining(context.now, calendar: calendar)

        let elapsed = context.now.timeIntervalSince(currentMonth.start)
        guard elapsed >= Self.monthlyMinimumElapsedSeconds else { return nil }

        let previousMonth = DateRangeHelper.lastMonthRange(relativeTo: context.now, calendar: calendar)

        guard let intervals = comparableIntervals(currentPeriod: currentMonth, previousPeriod: previousMonth, now: context.now) else { return nil }

        let currentSpend = BudgetCalculator.monthlySpent(context.transactions, in: intervals.current, includePending: includePending)
        let previousSpend = BudgetCalculator.monthlySpent(context.transactions, in: intervals.previous, includePending: includePending)

        guard previousSpend > 0, currentSpend > previousSpend else { return nil }

        let absoluteIncrease = currentSpend - previousSpend
        let percentageIncrease = absoluteIncrease / previousSpend
        guard percentageIncrease >= Self.monthlyPercentageThreshold, absoluteIncrease >= Self.monthlyAbsoluteThreshold else { return nil }

        let confidence: SpendSenseConfidence = elapsed >= Self.monthlyHighConfidenceElapsedSeconds ? .high : .medium
        let percentageIncreaseAsDouble = NSDecimalNumber(decimal: percentageIncrease).doubleValue

        return SpendSenseSignal(
            id: "spending.month.higher-than-previous",
            deduplicationID: "spending.month.higher-than-previous",
            category: .spending,
            severity: .headsUp,
            confidence: confidence,
            priority: 220,
            title: "Spending Up This Month",
            explanation: "You've spent \(formatCurrency(currentSpend)) so far this month, compared to \(formatCurrency(previousSpend)) during the same portion of last month — an increase of \(formatPercentage(percentageIncreaseAsDouble)).",
            metrics: [
                SpendSenseMetric(id: "spending.month.current", label: "This Month", value: .currency(currentSpend)),
                SpendSenseMetric(id: "spending.month.previous", label: "Previous Month", value: .currency(previousSpend)),
                SpendSenseMetric(id: "spending.month.increase", label: "Increase", value: .percentage(percentageIncreaseAsDouble)),
            ],
            action: nil,
            relevantDate: currentMonth.start,
            evaluatedAt: context.now
        )
    }

    // MARK: - Comparable-window construction

    /// Builds a fair, elapsed-duration-matched pair of intervals: the current interval runs from
    /// `currentPeriod.start` through `now` (capped at `currentPeriod.end`), and the previous
    /// interval runs from `previousPeriod.start` for that SAME duration (capped, defensively, at
    /// `previousPeriod.end`). Returns `nil` if either interval would be invalid (end before
    /// start) — this is a defensive guard against malformed input, not an expected runtime path.
    private func comparableIntervals(
        currentPeriod: DateInterval,
        previousPeriod: DateInterval,
        now: Date
    ) -> (current: DateInterval, previous: DateInterval)? {
        let currentEnd = min(now, currentPeriod.end)
        guard currentEnd >= currentPeriod.start else { return nil }
        let current = DateInterval(start: currentPeriod.start, end: currentEnd)

        let uncappedPreviousEnd = previousPeriod.start.addingTimeInterval(current.duration)
        let previousEnd = min(uncappedPreviousEnd, previousPeriod.end)
        guard previousEnd >= previousPeriod.start else { return nil }
        let previous = DateInterval(start: previousPeriod.start, end: previousEnd)

        return (current, previous)
    }

    // MARK: - Formatting

    /// Mirrors `BudgetSignalEngine`'s private currency formatting exactly (same locale, same
    /// style) — kept as a separate, equivalent helper here rather than calling into
    /// `BudgetSignalEngine`, which exposes no shared formatting API.
    private func formatCurrency(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
    }

    /// Mirrors `BudgetSignalEngine`'s private percentage formatting exactly (same rounding, same
    /// `%` suffix), taking the same `Double` fraction shape `SpendSenseMetric.Value.percentage`
    /// already requires.
    private func formatPercentage(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
