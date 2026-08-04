import Foundation

/// The Scenario Builder's in-memory "what-if" state holder — the ONE place `ScenarioAction`s are
/// applied. Holds two independent snapshots, both plain, transient `[ScenarioLineItem]` arrays:
/// `baselineItems` (captured once at construction from the user's real Monthly Plan via
/// `ScenarioLineItemFactory.baseline`, never mutated afterward) and `items` (the live, editable
/// scenario state `apply(_:)` mutates).
///
/// Structurally non-persistent: this class holds no `ModelContext`, no backend network client, and
/// no reference to any persistent store of any kind — there is nothing here through which a
/// mutation could reach the real Monthly Plan, SwiftData, or any cloud backend. `reset()` simply
/// restores `items` to `baselineItems`; nothing is ever re-read from or written back to a store.
///
/// AUTHORITATIVE, DETERMINISTIC RECONSTRUCTION — `items` is never mutated by directly reversing an
/// action; it is always fully rebuilt as `baseline + ordered active actions`, so removing one
/// active action can never accumulate drift from whatever order edits happened to occur in. This
/// is the ONE calculation path for Scenario Mode (`MonthlyPlanScenarioViewModel` holds no
/// competing state of its own — see that type's own header).
///
/// PHASE 6 — Part 8 (forward-compatibility note, no new code): this shape already supports Save/
/// Duplicate/Rename/Compare later without a rewrite, because a scenario's entire identity is just
/// `baselineItems` (a value snapshot) + `activeActions` (an ordered value list) — nothing here
/// references a specific view, a specific `ModelContext`, or global app state. Concretely: "Save
/// Scenario" would persist `activeActions` (once `ScenarioAction` conformers are made `Codable`)
/// alongside a name/id; "Duplicate"/"Compare" would construct additional independent
/// `ScenarioEngine` instances from the same `baselineItems` (each already fully self-contained);
/// "Rename" is metadata that would live alongside the saved action list, not inside `ScenarioEngine`
/// itself. None of that is implemented in this phase — this note exists only so a future phase
/// doesn't need to restructure this type to add it.
@Observable
final class ScenarioEngine {
    private(set) var items: [ScenarioLineItem]
    let baselineItems: [ScenarioLineItem]
    /// Every currently-active modification, in application order — the only thing besides
    /// `baselineItems` needed to reconstruct `items` (see `recompute()`). Exposed read-only so a
    /// view model can render an Active Changes review list without a separate, parallel log.
    private(set) var activeActions: [ScenarioAction] = []

    init(baselineItems: [ScenarioLineItem]) {
        self.baselineItems = baselineItems
        self.items = baselineItems
    }

    /// The one dispatch point every current and future Scenario action calls through —
    /// polymorphic via `ScenarioAction.apply(to:)`, never a switch statement. Adding a new action
    /// type later never requires changing this method.
    ///
    /// Conflict rule: an incoming action whose `id` matches an already-active action's `id`
    /// REPLACES it (removed, then the new one appended at the end) rather than stacking both —
    /// this single, generic, id-based rule is what makes "re-Change the same item updates the
    /// prior Change" and "Remove replaces an existing Change for the same item" both correct with
    /// no action-type-specific logic here (see `ScenarioAction.id`'s own header).
    func apply(_ action: ScenarioAction) {
        activeActions.removeAll { $0.id == action.id }
        activeActions.append(action)
        recompute()
    }

    /// Removes exactly one active action (by its `id`) and deterministically rebuilds `items` from
    /// `baselineItems` plus whatever remains — never by reversing the removed action's specific
    /// effect, so there is nothing that can drift.
    func removeAction(id: UUID) {
        activeActions.removeAll { $0.id == id }
        recompute()
    }

    func items(in category: ScenarioCategory) -> [ScenarioLineItem] {
        items.filter { $0.category == category }
    }

    /// The hypothetical Monthly Savings Goal, if a `ChangeMonthlySavingsGoalAction` is currently
    /// active — `nil` means "no scenario override; use the real Monthly Savings Goal unchanged."
    /// Derived from `activeActions` exactly like `items` is (via `recompute()`) — never a separate,
    /// independently-stored value, so it can never drift from what `activeActions` actually holds,
    /// and it participates in `reset()`/`removeAction(id:)` for free, with no engine changes needed
    /// beyond this one read-only computed property.
    var savingsGoalOverride: Decimal? {
        activeActions.compactMap { ($0 as? ChangeMonthlySavingsGoalAction)?.newGoal }.last
    }

    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 9) — the hypothetical Planned Weekly
    /// Spending, if a `ChangePlannedWeeklySpendingAction` is currently active. `nil` means "no
    /// scenario override; use the real (or automatic) Planned Weekly Spending unchanged." Mirrors
    /// `savingsGoalOverride` exactly, including participating in `reset()`/`removeAction(id:)` for
    /// free.
    var plannedWeeklySpendingOverride: Decimal? {
        activeActions.compactMap { ($0 as? ChangePlannedWeeklySpendingAction)?.newAmount }.last
    }

    /// Real baseline items available to target with Remove/Change for `category` — never a
    /// hypothetical Add item (those only ever exist in `items`/`activeActions`, never in
    /// `baselineItems`), matching "Remove"/"Change" always acting on a real, existing Monthly Plan
    /// item.
    func eligibleSourceItems(in category: ScenarioCategory) -> [ScenarioLineItem] {
        baselineItems.filter { $0.category == category }
    }

    /// Discards every applied action, restoring `items` to the exact baseline snapshot captured at
    /// construction — a complete, immediate discard of the scenario, with nothing left over to
    /// re-apply or re-read.
    func reset() {
        activeActions.removeAll()
        items = baselineItems
    }

    /// `items = baseline + ordered active actions`, rebuilt from scratch every time — see this
    /// type's own header for why this is deliberate.
    private func recompute() {
        items = activeActions.reduce(baselineItems) { partial, action in action.apply(to: partial) }
    }
}
