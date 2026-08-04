import Foundation

/// Which side of the Monthly Plan calculator a `ScenarioLineItem` feeds — always known, never
/// inferred from `timing` (unlike `ScenarioCategory` below, which can be `nil`). Kept separate from
/// `ScenarioCategory` so an item whose timing doesn't map to a named Builder category yet (see
/// `ScenarioCategory.forExpense(timing:)`) still contributes correctly to
/// `ScenarioSummaryBuilder`'s income/expense split.
enum ScenarioLedger: String, Codable, Equatable, Sendable {
    case income
    case expense
}

/// The Scenario Builder's own top-level grouping — the three categories future phases' Add/Remove/
/// Change actions will target ("Design the architecture so future phases can support: Categories —
/// Income, Mid Month, End Month"). Deliberately NOT the same concept as `PlanTiming`: `PlanTiming`
/// describes WHEN in the month a real Monthly Plan item lands and applies uniformly to income and
/// expenses alike, while `ScenarioCategory` is the Builder's own fixed, closed set of editable
/// buckets — every income item is category `.income` regardless of its own `timing`, and an expense
/// item's category is derived from its `timing` (see `forExpense(timing:)`) since only two of
/// `PlanTiming`'s five cases are named Builder categories today.
enum ScenarioCategory: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    case income
    case midMonth
    case endMonth
    /// The one Monthly Savings Goal — unlike the other three categories, this is never backed by a
    /// `ScenarioLineItem` (no `IncomeSource`/`RecurringExpense` has a "savings goal"; it's a single
    /// scalar on `MonthlyPlanSettings`). Supports only the Change action — see
    /// `ChangeMonthlySavingsGoalAction`'s own header for how it participates in Scenario state and
    /// calculations without a fork of `MonthlyPlanCalculator`.
    case monthlySavingsGoal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .income: return "Income"
        case .midMonth: return "Mid Month"
        case .endMonth: return "End Month"
        case .monthlySavingsGoal: return "Monthly Savings Goal"
        }
    }

    /// Maps an expense item's real `PlanTiming` to one of the two expense-side Builder categories,
    /// or `nil` if `timing` doesn't correspond to a named category yet (`.beginningMonth`,
    /// `.weekly`, `.customDate`). Adding a category for one of those later is a pure, additive
    /// change to this one function — every existing call site already treats `nil` as a valid,
    /// handled case (see `ScenarioLineItem.category`), so nothing else needs to change.
    static func forExpense(timing: PlanTiming) -> ScenarioCategory? {
        switch timing {
        case .midMonth: return .midMonth
        case .endMonth: return .endMonth
        case .beginningMonth, .weekly, .customDate: return nil
        }
    }

    /// Which ledger a brand-new hypothetical item created directly from this category belongs on
    /// — `.income` always creates income, `.midMonth`/`.endMonth` always create an expense. Used
    /// only by `AddScenarioItemAction`, which has no existing real item to read a ledger from.
    /// `.monthlySavingsGoal` never reaches this property in practice — the Builder never offers
    /// Add for that category (it supports only Change) — `.expense` is a harmless, unreachable
    /// placeholder rather than a `fatalError`, since a future UI bug offering Add there should
    /// degrade gracefully, not crash.
    var ledger: ScenarioLedger {
        switch self {
        case .income: return .income
        case .midMonth, .endMonth, .monthlySavingsGoal: return .expense
        }
    }

    /// The `PlanTiming` a brand-new hypothetical item created directly from this category is
    /// stamped with. For `.midMonth`/`.endMonth` this exactly matches the category. For `.income`,
    /// timing has no bearing on category (see this type's own header) or on any calculation
    /// (`MonthlyPlanCalculator` never reads `PlanTiming` — see `PlanTiming`'s own header) — the
    /// value is a reasonable, stable label only, never load-bearing. `.monthlySavingsGoal` never
    /// reaches this property in practice — see `ledger`'s own header for why.
    var timing: PlanTiming {
        switch self {
        case .income: return .beginningMonth
        case .midMonth: return .midMonth
        case .endMonth: return .endMonth
        case .monthlySavingsGoal: return .beginningMonth
        }
    }
}
