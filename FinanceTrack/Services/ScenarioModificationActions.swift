import Foundation

/// Adds a brand-new hypothetical item to a Scenario. The item exists only inside
/// `ScenarioEngine.items` — never written back to any real `IncomeSource`/`RecurringExpense`,
/// never inserted into SwiftData. Its own `id` doubles as this action's identity; a fresh id is
/// generated per instance, so an Add action can never collide with (replace) another action.
///
/// Takes `ledger`/`timing` directly (Phase 4), rather than deriving them from a `ScenarioCategory`
/// (Phase 2/3) — Fixed Bills now supports every `PlanTiming` value, not only the two
/// `ScenarioCategory` names a category after (`.midMonth`/`.endMonth`; see `ScenarioCategory`'s own
/// header), so a hypothetical bill must be able to carry ANY timing the user picks, including
/// `.beginningMonth`/`.weekly`/`.customDate`, which have no corresponding `ScenarioCategory` case.
struct AddScenarioItemAction: ScenarioAction {
    let id: UUID
    let ledger: ScenarioLedger
    let timing: PlanTiming
    let itemName: String
    let amount: Decimal
    let referenceDate: Date?
    let frequency: PlanFrequency

    /// `frequency` defaults to `.monthly` — matching `IncomeSource`/`RecurringExpense`'s own
    /// `init` defaults — EXCEPT when `timing == .customDate`, where it defaults to `.oneTime`.
    /// This matches the established convention every real-data fixture in this app already uses
    /// (`.customDate` timing paired with `.oneTime` frequency): a custom date names one specific
    /// occurrence, not a recurring monthly one. Without this, a hypothetical Custom Date item
    /// would silently recur every month in Custom Date Range analysis, contradicting what
    /// "Custom Date" means everywhere else in this app.
    init(ledger: ScenarioLedger, timing: PlanTiming, itemName: String, amount: Decimal, referenceDate: Date? = nil, frequency: PlanFrequency? = nil, id: UUID = UUID()) {
        self.id = id
        self.ledger = ledger
        self.timing = timing
        self.itemName = itemName
        self.amount = amount
        self.referenceDate = referenceDate
        self.frequency = frequency ?? (timing == .customDate ? .oneTime : .monthly)
    }

    var name: String { "Add" }

    func apply(to items: [ScenarioLineItem]) -> [ScenarioLineItem] {
        items + [ScenarioLineItem(
            id: id,
            name: itemName,
            amount: amount,
            frequency: frequency,
            timing: timing,
            referenceDate: referenceDate,
            isIncluded: true,
            isHypothetical: true,
            ledger: ledger
        )]
    }
}

/// Excludes an existing real Scenario line item (identified by `id`, the source item's own real
/// `IncomeSource`/`RecurringExpense` id) from the Scenario result only — the real record is never
/// touched. Sharing `id` with the target item is what lets `ScenarioEngine.apply(_:)` replace an
/// earlier `ChangeScenarioItemAmountAction` for the same item with this Remove (see
/// `ScenarioAction.id`'s own header) rather than leaving both active and ambiguous.
struct RemoveScenarioItemAction: ScenarioAction {
    let id: UUID

    var name: String { "Remove" }

    func apply(to items: [ScenarioLineItem]) -> [ScenarioLineItem] {
        items.map { item in
            guard item.id == id else { return item }
            var copy = item
            copy.isIncluded = false
            return copy
        }
    }
}

/// Overrides an existing real Scenario line item's amount (identified by `id`, the source item's
/// real id) for the Scenario result only — the real record is never touched. Re-applying this
/// action for the same item (a new amount chosen again) replaces the prior Change; applying it
/// after an existing Remove for the same item replaces that Remove, bringing the item back with
/// the new amount — both are the same generic id-based replacement rule described on
/// `ScenarioAction.id`, not special-cased here.
struct ChangeScenarioItemAmountAction: ScenarioAction {
    let id: UUID
    let newAmount: Decimal

    var name: String { "Change" }

    func apply(to items: [ScenarioLineItem]) -> [ScenarioLineItem] {
        items.map { item in
            guard item.id == id else { return item }
            var copy = item
            copy.amount = newAmount
            return copy
        }
    }
}

/// Overrides the ONE Monthly Savings Goal for the Scenario result only — the real
/// `MonthlyPlanSettings.monthlySavingsGoal` is never touched. Unlike the other three actions,
/// there is no `ScenarioLineItem` to target (a savings goal isn't an income/expense line item), so
/// `apply(to:)` is a pure passthrough — `[ScenarioLineItem]` is not how this override reaches the
/// calculator; `ScenarioEngine.savingsGoalOverride` (a small computed property reading
/// `activeActions` directly, exactly like `items` reads `activeActions` via `recompute()`) is.
/// `id` is a fixed constant, not derived from any item, since there is only ever one savings goal
/// to target — re-applying this action (a new goal chosen again) replaces the prior one via
/// `ScenarioEngine.apply(_:)`'s existing id-collision-replace rule, the same mechanism
/// `ChangeScenarioItemAmountAction` uses for a real line item.
struct ChangeMonthlySavingsGoalAction: ScenarioAction {
    static let fixedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id: UUID { Self.fixedID }
    let newGoal: Decimal

    var name: String { "Change" }

    func apply(to items: [ScenarioLineItem]) -> [ScenarioLineItem] { items }
}

/// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 9) — overrides the ONE Planned Weekly Spending
/// value for the Scenario result only. Real `MonthlyPlanSettings.plannedWeeklySpendingOverride` is
/// never touched. Mirrors `ChangeMonthlySavingsGoalAction` exactly: a pure passthrough (no
/// `ScenarioLineItem` to target), a fixed, distinct id so re-applying replaces the prior override
/// via `ScenarioEngine.apply(_:)`'s existing id-collision-replace rule, and "Change" is the only
/// supported action (there is only one Planned Weekly Spending value to target, nothing to Add or
/// Remove).
struct ChangePlannedWeeklySpendingAction: ScenarioAction {
    static let fixedID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    var id: UUID { Self.fixedID }
    let newAmount: Decimal

    var name: String { "Change" }

    func apply(to items: [ScenarioLineItem]) -> [ScenarioLineItem] { items }
}
