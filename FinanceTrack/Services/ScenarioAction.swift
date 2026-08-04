import Foundation

/// The extension point every future Scenario Builder capability plugs into — Add, Remove, Change,
/// and anything beyond (move an item, duplicate an item, convert recurring to one-time, percentage
/// adjustments, delayed income, missed payments, temporary one-month expenses, ...). Each capability
/// is its own type conforming to this protocol; `ScenarioEngine.apply(_:)` dispatches to it
/// polymorphically via `apply(to:)`. Adding a new action later means adding a new conforming type —
/// never adding a `case` to a switch statement in the engine or in any existing action.
///
/// Phase 2 adds the first concrete conforming types (`AddScenarioItemAction`,
/// `RemoveScenarioItemAction`, `ChangeScenarioItemAmountAction` — see `ScenarioModificationActions.swift`)
/// plus the `id` requirement below, needed so `ScenarioEngine` can look up, replace-on-conflict, and
/// individually remove an active action from its ordered list without knowing each action's
/// concrete type.
protocol ScenarioAction {
    /// Identifies both this action for removal from `ScenarioEngine.activeActions`, AND (by
    /// convention, not enforcement) the real source item it targets: `RemoveScenarioItemAction`/
    /// `ChangeScenarioItemAmountAction` reuse the target `ScenarioLineItem.id` directly, so a new
    /// action sharing an id with an existing one is treated as replacing it (see
    /// `ScenarioEngine.apply(_:)`) — this is what makes "Change replaces the same item's earlier
    /// Change" and "Remove replaces an earlier Change for the same item" both fall out of one
    /// generic rule, with no type-specific switch anywhere. `AddScenarioItemAction` generates a
    /// fresh id for the new item it creates, so it can never collide with an existing action.
    var id: UUID { get }

    /// A short, stable, human-readable label — not persisted, not used for identity; shown in the
    /// Scenario Builder's Active Changes review row.
    var name: String { get }

    /// Applies this action to `items`, returning the resulting array. Pure and side-effect-free:
    /// must never touch SwiftData, Supabase, or any other persistent store — `items` is always a
    /// plain, transient `[ScenarioLineItem]` array, exactly like every other piece of Scenario
    /// Mode state.
    func apply(to items: [ScenarioLineItem]) -> [ScenarioLineItem]
}
