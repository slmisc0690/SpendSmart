import Foundation

/// INCOME SCHEDULING PHASE: plain-language deposit-schedule text for Monthly Plan income rows —
/// e.g. "every 2 weeks · Next: Aug 7", "monthly · Deposit: Last day", "twice monthly · Deposits:
/// 1st and 15th". Deliberately NEVER shows the old `PlanTiming` Mid-Month/End-of-Month label for
/// recurring income (this phase's own explicit requirement — that label was never date math, see
/// `PlanTiming`'s own header). Pure, UIKit/SwiftUI-independent text generation, matching this
/// codebase's established "prefer a testable helper over source scans" pattern
/// (`ScenarioSummaryText`).
enum IncomeScheduleText {
    static func frequencyDescription(_ frequency: PlanFrequency) -> String {
        switch frequency {
        case .weekly: return "every week"
        case .biweekly: return "every 2 weeks"
        case .twiceMonthly: return "twice monthly"
        case .monthly: return "monthly"
        case .quarterly: return "quarterly"
        case .yearly: return "yearly"
        case .oneTime: return "one-time"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// e.g. "Next: Aug 7", "Deposit: Last day", "Deposits: 1st and 15th" — `nil` when nothing is
    /// configured yet for this frequency (e.g. an incomplete Twice-Monthly schedule, or a
    /// Weekly/Biweekly/Yearly record with no `nextPayDate`), so `scheduleSummary(for:)` can show
    /// an honest "Schedule incomplete" state instead of a blank or fabricated one.
    static func scheduleDetail(for source: IncomeSource) -> String? {
        switch source.frequency {
        case .weekly, .biweekly, .quarterly:
            guard let date = source.nextPayDate else { return nil }
            return "Next: \(dayFormatter.string(from: date))"
        case .monthly:
            guard let day = source.monthlyDepositDay else { return nil }
            return "Deposit: \(day.displayLabel)"
        case .twiceMonthly:
            guard let first = source.twiceMonthlyFirstDeposit, let second = source.twiceMonthlySecondDeposit else { return nil }
            return "Deposits: \(first.displayLabel) and \(second.displayLabel)"
        case .yearly, .oneTime:
            guard let date = source.nextPayDate else { return nil }
            return "Date: \(dayFormatter.string(from: date))"
        }
    }

    /// The full one-line schedule summary for a Monthly Plan income row — never a Mid-Month/
    /// End-of-Month timing label for recurring income (see this type's own header).
    static func scheduleSummary(for source: IncomeSource) -> String {
        let frequencyText = frequencyDescription(source.frequency)
        guard let detail = scheduleDetail(for: source) else {
            return "\(frequencyText) \u{00B7} Schedule incomplete"
        }
        return "\(frequencyText) \u{00B7} \(detail)"
    }
}
