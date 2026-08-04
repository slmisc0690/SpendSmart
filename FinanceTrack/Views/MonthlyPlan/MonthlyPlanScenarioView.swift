import SwiftUI
import UIKit

/// MONTHLY PLAN SCENARIO BUILDER — a temporary, non-persistent "what if" sandbox for the Primary's
/// own Monthly Plan. Presented as a sheet from `MonthlyPlanView` (never replacing it, same entry
/// point as before this phase). Every number shown here comes from `MonthlyPlanScenarioViewModel`,
/// which routes every read and write through `ScenarioEngine` (the one authoritative Scenario
/// calculation path — see that view model's own header) and reuses the existing
/// `MonthlyPlanCalculator` unchanged — this view does no math of its own beyond simple subtraction
/// for the "Difference" column (and `ScenarioDateRangeCalculator`'s own, separately-documented,
/// genuinely-new occurrence math for Custom Date Range).
///
/// GOAL-DRIVEN FLOW (Phase 4, restyled Phase 7): the Builder opens with "What if..." —
/// `ScenarioGoal` (Income / Fixed Bills / Savings Goal / Custom Date Range) — rather than leading
/// with Mid-Month/End-Month timing groups. Fixed Bills now spans every `PlanTiming` value, not
/// only Mid/End Month.
///
/// PHASE 7 — WORKSPACE, NOT A WIZARD: `whatIfSection` (the "What if..." cards) and
/// `myScenarioSection` ("My Scenario," the one canonical list of active modifications) are BOTH
/// reachable without ever resetting anything — `whatIfSection` shows whenever there are no active
/// modifications yet OR the user tapped "+ Add Another Change"; `myScenarioSection` shows whenever
/// there is at least one active modification. Results stay visible the whole time. This replaces
/// the prior phases' three separate displays of the same active-modification list (the earlier
/// Scenario Modifications list, the bullet-only Scenario Summary, and the bottom Active Changes
/// list) with just one.
///
/// NON-DESTRUCTIVE: there is no Apply/Save/Replace action anywhere on this screen. Dismissing it
/// (Close, swipe-down, or backgrounding the app) simply discards `viewModel` — the real Monthly
/// Plan was never touched in the first place, so there is nothing to "revert."
struct MonthlyPlanScenarioView: View {
    @State private var viewModel: MonthlyPlanScenarioViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode

    @State private var selectedGoal: ScenarioGoal?
    /// Phase 5: the 4 goal choices are no longer always visible — they only appear once the user
    /// taps "+ Add Modification," so the primary view is the accumulated list of modifications
    /// already built, not a single always-present chooser (see `scenarioModificationsSection`'s
    /// own header for why this satisfies "true Scenario Builder" — multiple modifications were
    /// already supported by `ScenarioEngine` internally; only this UI flow prevented building more
    /// than one before this phase).
    @State private var isChoosingModificationType = false

    private enum BuilderActionKind: String, CaseIterable, Identifiable, Equatable {
        case add = "Add"
        case remove = "Remove"
        case change = "Change"
        var id: String { rawValue }
    }

    @State private var selectedActionKind: BuilderActionKind = .add
    @State private var fixedBillTimingFilter: PlanTiming?

    /// Income Modification (Part 3): a real income is selected FIRST, then the user picks between
    /// "Remove Entire Income" and "Change Income Amount" for that SAME item — the reverse order of
    /// the shared `BuilderActionKind` flow (pick an action, then an item) Fixed Bills still uses.
    private enum IncomeActionKind: String, CaseIterable, Identifiable, Equatable {
        case add = "Add"
        case modify = "Modify Existing"
        var id: String { rawValue }
    }
    @State private var incomeActionKind: IncomeActionKind = .add
    @State private var incomeModifySelectedItemID: UUID?

    @State private var addName: String = ""
    @State private var addAmount: Decimal?
    @State private var addTiming: PlanTiming = .beginningMonth

    @State private var removeSelectedItemID: UUID?

    @State private var changeSelectedItemID: UUID?
    @State private var changeAmount: Decimal?

    @State private var savingsGoalAmount: Decimal?

    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 9) — the Planned Weekly Spending editor's
    /// "New Amount" field, mirroring `savingsGoalAmount`'s own pattern exactly.
    @State private var weeklySpendingAmount: Decimal?

    @State private var dateRangeStart: Date = .now
    @State private var dateRangeEnd: Date = .now

    @State private var isPresentingEditor = false

    /// PHASE 6 — Part 1: when set, the currently-open Add form (Income or Fixed Bills) is editing
    /// an already-active hypothetical Add action under this id rather than creating a new one — see
    /// `startEditingModification(_:)`. `nil` whenever "+ Add Another Change" starts a fresh entry.
    @State private var editingActionID: UUID?

    /// PHASE 7 — Part 4: which Results row's plain-English explanation is currently showing, if
    /// any.
    @State private var infoTopic: ScenarioResultInfoTopic?

    /// WEEKLY UX IMPROVEMENT — purely temporary presentation state, never persisted/synced: whether
    /// the dated weekly cards under "Scenario Planned Weekly Spending" are expanded. Defaults to
    /// `false` every time this view is created (Close/reopen always gets a fresh `MonthlyPlanScenarioView`
    /// — see this file's own header), and is explicitly reset to `false` by the "Reset Scenario"
    /// toolbar button below. Only ever shown/relevant while `viewModel.hasActiveScenario`.
    @State private var showWeekByWeekBreakdown = false

    init(
        incomeSources: [IncomeSource],
        recurringExpenses: [RecurringExpense],
        planSettings: MonthlyPlanSettings?,
        weeklyBudgetLimit: Decimal,
        transactions: [FinanceTransaction],
        month: DateInterval,
        weekInterval: DateInterval,
        weekStartsOnSunday: Bool,
        includePending: Bool,
        warningThreshold: Double
    ) {
        _viewModel = State(initialValue: MonthlyPlanScenarioViewModel(
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: planSettings,
            weeklyBudgetLimit: weeklyBudgetLimit,
            transactions: transactions,
            month: month,
            weekInterval: weekInterval,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header
                    // PHASE 7 — Part 5: a workspace, not a wizard. Both sections stay reachable
                    // without resetting anything — see this file's own header for the exact rule
                    // governing when each shows.
                    if viewModel.activeModifications.isEmpty || isChoosingModificationType {
                        whatIfSection
                    }
                    myScenarioSection
                    if selectedGoal == .customDateRange {
                        dateRangeSection
                    } else {
                        resultsSection
                        weeklyComparisonSection
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset Scenario") {
                        viewModel.reset()
                        showWeekByWeekBreakdown = false
                    }
                        .foregroundStyle(Theme.accent)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $isPresentingEditor) {
                editorSheet
            }
            .sheet(item: $infoTopic) { topic in
                ScenarioResultInfoView(topic: topic, explanation: explanation(for: topic))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scenario Builder")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            Text("Build a what-if scenario from your real Monthly Plan and see the effect.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Image(systemName: "flask.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Temporary simulation — nothing here is saved to your real Monthly Plan.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - "What if..." (Phase 7 — Parts 1 & 2)

    /// The Builder's permanent entry point — replaces the earlier "Build Your Scenario"/"Scenario
    /// Modifications" chooser with a single, inviting "What if..." heading over 4 tappable,
    /// Apple Settings-style grouped cards (no button styling — no fill per card, no border, just
    /// rows separated by dividers inside one `CardBackground`, exactly like a Settings list).
    /// `ScenarioEngine` already supported unlimited simultaneous modifications before Phase 6
    /// (`activeActions` is an unbounded, ordered array); this section only changes how the entry
    /// point looks and when it's shown (see this file's own header), never what it does.
    private var whatIfSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "What if...")

            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(ScenarioGoal.allCases.enumerated()), id: \.element.id) { index, goal in
                        goalCard(goal)
                        if index < ScenarioGoal.allCases.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// Tapping a goal card here immediately opens its editor (Custom Date Range has no sheet — its
    /// UI is inline, so selecting it only needs to close the chooser) — users may repeat this as
    /// many times as desired since `myScenarioSection`'s list never resets between additions.
    @ViewBuilder
    private func goalCard(_ goal: ScenarioGoal) -> some View {
        Button {
            selectedGoal = goal
            selectedActionKind = .add
            incomeActionKind = .add
            removeSelectedItemID = nil
            changeSelectedItemID = nil
            incomeModifySelectedItemID = nil
            changeAmount = nil
            editingActionID = nil
            addName = ""
            addAmount = nil
            addTiming = .beginningMonth
            if goal == .monthlySavingsGoal {
                savingsGoalAmount = viewModel.currentMonthlySavingsGoal
            }
            if goal == .plannedWeeklySpending {
                weeklySpendingAmount = viewModel.currentPlannedWeeklySpending
            }
            isChoosingModificationType = false
            if goal != .customDateRange {
                isPresentingEditor = true
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Text(goal.emoji)
                    .font(.system(size: 22))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title)
                        .font(Theme.bodyFont.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(goal.cardSubtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// PHASE 6 — Part 1: "edit" on a modification card reopens the SAME editor pre-filled with that
    /// modification's current values, so saving updates the existing `ScenarioAction` in place
    /// (via `ScenarioEngine.apply(_:)`'s id-based replace rule) rather than adding a duplicate.
    /// - A hypothetical Add (Income or Fixed Bill) reopens its Add form with `editingActionID` set,
    ///   so the eventual save calls `editHypotheticalIncome`/`editHypotheticalFixedBill` (same id)
    ///   instead of `addHypotheticalIncome`/`addHypotheticalFixedBill` (fresh id).
    /// - A real item's Remove or Change reopens the same item-first Remove/Change flow already used
    ///   to create it, pre-selected on that item — including letting a Remove be edited into a
    ///   Change (entering a new amount replaces the Remove for that item, the same generic
    ///   id-collision rule `ScenarioEngine` already uses everywhere else).
    private func startEditingModification(_ modification: MonthlyPlanScenarioViewModel.ActiveModification) {
        switch modification.context {
        case .income:
            selectedGoal = .income
            if modification.kind == "Add" {
                incomeActionKind = .add
                addName = modification.itemName
                addAmount = modification.newAmount
                editingActionID = modification.id
            } else {
                incomeActionKind = .modify
                incomeModifySelectedItemID = modification.id
                changeAmount = modification.newAmount ?? modification.originalAmount
                editingActionID = nil
            }
        case .fixedBill(let timing):
            selectedGoal = .fixedBills
            fixedBillTimingFilter = timing
            if modification.kind == "Add" {
                selectedActionKind = .add
                addName = modification.itemName
                addAmount = modification.newAmount
                addTiming = timing
                editingActionID = modification.id
            } else {
                selectedActionKind = .change
                changeSelectedItemID = modification.id
                changeAmount = modification.newAmount ?? modification.originalAmount
                editingActionID = nil
            }
        case .monthlySavingsGoal:
            selectedGoal = .monthlySavingsGoal
            savingsGoalAmount = modification.newAmount
            editingActionID = nil
        case .plannedWeeklySpending:
            selectedGoal = .plannedWeeklySpending
            weeklySpendingAmount = modification.newAmount
            editingActionID = nil
        }
        isChoosingModificationType = false
        isPresentingEditor = true
    }

    // MARK: - Editor sheet (Part 9: full dismissal behavior)

    private var editorHasUnsavedChanges: Bool {
        switch selectedGoal {
        case .income:
            switch incomeActionKind {
            case .add: return !addName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || addAmount != nil
            case .modify: return changeAmount != nil
            }
        case .fixedBills:
            switch selectedActionKind {
            case .add: return !addName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || addAmount != nil
            case .remove: return false
            case .change: return changeAmount != nil
            }
        case .monthlySavingsGoal:
            return savingsGoalAmount != viewModel.currentMonthlySavingsGoal
        case .plannedWeeklySpending:
            return weeklySpendingAmount != viewModel.currentPlannedWeeklySpending
        case .customDateRange, .none:
            return false
        }
    }

    @ViewBuilder
    private var editorSheet: some View {
        switch selectedGoal {
        case .income:
            ScenarioEditorSheet(title: "Income", hasUnsavedChanges: editorHasUnsavedChanges) {
                incomeEditorContent
            }
        case .fixedBills:
            ScenarioEditorSheet(title: "Fixed Bills", hasUnsavedChanges: editorHasUnsavedChanges) {
                fixedBillsEditorContent
            }
        case .monthlySavingsGoal:
            ScenarioEditorSheet(title: "Monthly Savings Goal", hasUnsavedChanges: editorHasUnsavedChanges) {
                savingsGoalEditorContent
            }
        case .plannedWeeklySpending:
            ScenarioEditorSheet(title: "Planned Weekly Spending", hasUnsavedChanges: editorHasUnsavedChanges) {
                plannedWeeklySpendingEditorContent
            }
        case .customDateRange, .none:
            EmptyView()
        }
    }

    // MARK: - Income editor (Part 3: item-first Income Modification flow)

    private var incomeEditorContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            incomeActionChipRow
            switch incomeActionKind {
            case .add:
                addItemForm(placeholder: "e.g. Freelance Project") {
                    let success: Bool
                    if let editingID = editingActionID {
                        success = viewModel.editHypotheticalIncome(id: editingID, name: addName, amount: addAmount ?? 0)
                    } else {
                        success = viewModel.addHypotheticalIncome(name: addName, amount: addAmount ?? 0)
                    }
                    guard success else { return }
                    addName = ""
                    addAmount = nil
                    editingActionID = nil
                    isPresentingEditor = false
                }
            case .modify:
                incomeModifyForm
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private var incomeActionChipRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Action")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(IncomeActionKind.allCases) { option in
                    FilterChip(title: option.rawValue, isSelected: incomeActionKind == option) {
                        incomeActionKind = option
                        incomeModifySelectedItemID = nil
                        changeAmount = nil
                    }
                }
            }
        }
    }

    /// Part 3: select a real income FIRST, then choose between "Remove Entire Income" and "Change
    /// Income Amount" for that SAME item — both act on `selectedItem`, never a separately-chosen
    /// one, so there is no ambiguity about which income a tap applies to.
    @ViewBuilder
    private var incomeModifyForm: some View {
        let candidates = viewModel.changeableIncomeItems()
        if candidates.isEmpty {
            EmptyStateCard(systemIconName: "pencil.circle", message: "No income sources available to modify.")
        } else {
            let selectedID = incomeModifySelectedItemID ?? candidates[0].id
            let selectedItem = candidates.first { $0.id == selectedID } ?? candidates[0]

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                LabeledPickerRow(title: "Income", selection: Binding(
                    get: { selectedID },
                    set: { incomeModifySelectedItemID = $0; changeAmount = nil }
                )) {
                    ForEach(candidates) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                highContrastAmountRow(title: "Current Amount", amount: .constant(selectedItem.amount), isEditable: false)
                highContrastAmountRow(title: "New Amount", amount: $changeAmount, isEditable: true)
                builderActionButton(title: "Change Income Amount", isEnabled: (changeAmount ?? -1) >= 0) {
                    guard viewModel.changeItemAmount(selectedID, newAmount: changeAmount ?? 0) else { return }
                    incomeModifySelectedItemID = nil
                    changeAmount = nil
                    isPresentingEditor = false
                }

                Divider().overlay(Theme.cardStroke)

                // MONTHLY PLAN + SCENARIO CORRECTIONS PHASE — Part 12: the destructive Remove
                // Entire Income control must appear BELOW New Amount, never between Current Amount
                // and New Amount (physical-device testing found the prior ordering visually
                // implied removal was part of the normal Change flow).
                builderActionButton(title: "Remove Entire Income", isEnabled: true, isDestructive: true) {
                    viewModel.removeItem(selectedID)
                    incomeModifySelectedItemID = nil
                    isPresentingEditor = false
                }
            }
        }
    }

    // MARK: - Fixed Bills editor

    private var fixedBillsEditorContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            timingFilterRow
            fixedBillsSelectorTotalRow
            actionChipRow(options: [.add, .remove, .change])
            switch selectedActionKind {
            case .add:
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    LabeledPickerRow(title: "Timing", selection: $addTiming) {
                        ForEach(PlanTiming.allCases) { timing in
                            Text(timing.label).tag(timing)
                        }
                    }
                    addItemForm(placeholder: "e.g. New Subscription") {
                        let success: Bool
                        if let editingID = editingActionID {
                            success = viewModel.editHypotheticalFixedBill(id: editingID, name: addName, amount: addAmount ?? 0, timing: addTiming)
                        } else {
                            success = viewModel.addHypotheticalFixedBill(name: addName, amount: addAmount ?? 0, timing: addTiming)
                        }
                        guard success else { return }
                        addName = ""
                        addAmount = nil
                        editingActionID = nil
                        isPresentingEditor = false
                    }
                }
            case .remove:
                removeItemForm(candidates: viewModel.removableFixedBills(timingFilter: fixedBillTimingFilter), emptyMessage: "No Fixed Bills available to remove.") { targetID in
                    viewModel.removeItem(targetID)
                    isPresentingEditor = false
                }
            case .change:
                changeItemForm(candidates: viewModel.changeableFixedBills(timingFilter: fixedBillTimingFilter), emptyMessage: "No Fixed Bills available to change.") { itemID, amount in
                    guard viewModel.changeItemAmount(itemID, newAmount: amount) else { return }
                    changeSelectedItemID = nil
                    changeAmount = nil
                    isPresentingEditor = false
                }
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private var timingFilterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timing")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    FilterChip(title: "All", isSelected: fixedBillTimingFilter == nil) {
                        fixedBillTimingFilter = nil
                        removeSelectedItemID = nil
                        changeSelectedItemID = nil
                    }
                    ForEach(viewModel.availableFixedBillTimingFilters) { timing in
                        FilterChip(title: timing.label, isSelected: fixedBillTimingFilter == timing) {
                            fixedBillTimingFilter = timing
                            removeSelectedItemID = nil
                            changeSelectedItemID = nil
                        }
                    }
                }
            }
        }
    }

    /// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE — Part 1: the Fixed Bills selector's own total,
    /// clearly labeled and always matching the currently selected `fixedBillTimingFilter`.
    private var fixedBillsSelectorTotalRow: some View {
        HStack {
            Text("\(fixedBillTimingFilter?.label ?? "All") Fixed Bills")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            PrivacyAmountView(amount: viewModel.fixedBillsTotal(timingFilter: fixedBillTimingFilter), isPrivacyModeEnabled: privacyMode.isEnabled, font: Theme.bodyFont.weight(.semibold), color: Theme.textPrimary)
        }
    }

    // MARK: - Monthly Savings Goal editor (Part 8: visibility fix)

    private var savingsGoalEditorContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            highContrastAmountRow(title: "Current Amount", amount: .constant(viewModel.currentMonthlySavingsGoal), isEditable: false)
            highContrastAmountRow(title: "New Amount", amount: $savingsGoalAmount, isEditable: true, placeholder: "Enter Amount")

            builderActionButton(title: "Change in Scenario", isEnabled: (savingsGoalAmount ?? -1) >= 0) {
                guard viewModel.changeMonthlySavingsGoal(savingsGoalAmount ?? 0) else { return }
                isPresentingEditor = false
            }
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Planned Weekly Spending editor (Part 9)

    private var plannedWeeklySpendingEditorContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            highContrastAmountRow(title: "Current Amount", amount: .constant(viewModel.currentPlannedWeeklySpending), isEditable: false)
            highContrastAmountRow(title: "New Amount", amount: $weeklySpendingAmount, isEditable: true, placeholder: "Enter Amount")

            builderActionButton(title: "Change in Scenario", isEnabled: (weeklySpendingAmount ?? -1) >= 0) {
                guard viewModel.changePlannedWeeklySpending(weeklySpendingAmount ?? 0) else { return }
                isPresentingEditor = false
            }
        }
        .padding(Theme.Spacing.lg)
    }

    /// A horizontal amount row — label on the LEFT, value/field aligned to the FAR RIGHT, never
    /// underneath the label (Part 8's explicit requirement). Built directly on
    /// `CurrencyTextFieldRepresentable` (the same underlying cents-first text-entry engine
    /// `CurrencyAmountField` itself uses — no duplicated input logic) rather than
    /// `CurrencyAmountField`'s `.inline` style, whose fixed `Theme.textSecondary` text color is
    /// exactly what physical-device testing found too faint for an actively-edited field; this row
    /// explicitly uses `Theme.textPrimary` at high contrast instead. `CurrencyAmountField` itself
    /// is left completely unmodified — every one of its many other call sites across the app is
    /// unaffected.
    @ViewBuilder
    private func highContrastAmountRow(title: String, amount: Binding<Decimal?>, isEditable: Bool, placeholder: String = "$0.00") -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.bodyFont.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Spacing.md)
            if isEditable {
                CurrencyTextFieldRepresentable(
                    amount: amount,
                    allowsNegative: false,
                    allowsZero: true,
                    minimum: nil,
                    maximum: nil,
                    isDisabled: false,
                    placeholder: placeholder,
                    accessibilityLabel: title,
                    font: UIFont.preferredFont(forTextStyle: .title3),
                    textAlignment: .right,
                    textColor: UIColor(Theme.textPrimary),
                    placeholderColor: UIColor(Theme.textSecondary),
                    autoFocusOnAppear: false
                )
                .frame(height: 32)
                .fixedSize(horizontal: true, vertical: true)
            } else {
                PrivacyAmountView(amount: amount.wrappedValue ?? 0, isPrivacyModeEnabled: privacyMode.isEnabled, font: Theme.bodyFont.weight(.semibold), color: Theme.textPrimary)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }

    // MARK: - Shared Add/Remove/Change form pieces

    @ViewBuilder
    private func actionChipRow(options: [BuilderActionKind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Action")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(options) { option in
                    FilterChip(title: option.rawValue, isSelected: selectedActionKind == option) {
                        selectedActionKind = option
                        removeSelectedItemID = nil
                        changeSelectedItemID = nil
                    }
                }
            }
        }
    }

    private var isAddFormValid: Bool {
        MonthlyPlanScenarioViewModel.isValidHypotheticalName(addName.trimmingCharacters(in: .whitespacesAndNewlines))
            && MonthlyPlanScenarioViewModel.isValidHypotheticalAmount(addAmount)
    }

    @ViewBuilder
    private func addItemForm(placeholder: String, onAdd: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                TextField(placeholder, text: $addName)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(Theme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.cardSurface)
                    )
                    .accessibilityLabel("Hypothetical item name")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Amount")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                CurrencyAmountField(amount: $addAmount, style: .inline, accessibilityLabel: "Hypothetical amount")
            }
            builderActionButton(title: editingActionID != nil ? "Save Changes" : "Add to Scenario", isEnabled: isAddFormValid, action: onAdd)
        }
    }

    @ViewBuilder
    private func removeItemForm(candidates: [ScenarioLineItem], emptyMessage: String, onRemove: @escaping (UUID) -> Void) -> some View {
        if candidates.isEmpty {
            EmptyStateCard(systemIconName: "minus.circle", message: emptyMessage)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                LabeledPickerRow(title: "Item", selection: Binding(
                    get: { removeSelectedItemID ?? candidates[0].id },
                    set: { removeSelectedItemID = $0 }
                )) {
                    ForEach(candidates) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                builderActionButton(title: "Remove from Scenario", isEnabled: true) {
                    onRemove(removeSelectedItemID ?? candidates[0].id)
                    removeSelectedItemID = nil
                }
            }
        }
    }

    @ViewBuilder
    private func changeItemForm(candidates: [ScenarioLineItem], emptyMessage: String, onChange: @escaping (UUID, Decimal) -> Void) -> some View {
        if candidates.isEmpty {
            EmptyStateCard(systemIconName: "pencil.circle", message: emptyMessage)
        } else {
            let selectedID = changeSelectedItemID ?? candidates[0].id
            let selectedItem = candidates.first { $0.id == selectedID } ?? candidates[0]

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                LabeledPickerRow(title: "Item", selection: Binding(
                    get: { selectedID },
                    set: { changeSelectedItemID = $0 }
                )) {
                    ForEach(candidates) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                highContrastAmountRow(title: "Current Amount", amount: .constant(selectedItem.amount), isEditable: false)
                highContrastAmountRow(title: "New Amount", amount: $changeAmount, isEditable: true)
                builderActionButton(title: "Change in Scenario", isEnabled: (changeAmount ?? -1) >= 0) {
                    onChange(selectedID, changeAmount ?? 0)
                }
            }
        }
    }

    /// `isDestructive` (Part 3's "Remove Entire Income") tints the enabled fill with
    /// `Theme.statusOver` instead of `Theme.accent` — the same red the rest of this screen already
    /// uses for a destructive action (see `ActiveModificationRow`'s own trash button) — never a new
    /// color.
    @ViewBuilder
    private func builderActionButton(title: String, isEnabled: Bool, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.bodyFont.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textTertiary.opacity(0.8))
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(isEnabled ? (isDestructive ? Theme.statusOver : Theme.accent) : Theme.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(isEnabled ? Color.clear : Theme.cardStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Current / Scenario / Difference results

    /// Part 7 — which Bill Group rows to render, in `PlanTiming.allCases` order, filtered to only
    /// timings with at least one eligible bill (Current or Scenario) — no empty `$0.00` rows.
    private var billGroupTimingsToDisplay: [PlanTiming] {
        PlanTiming.allCases.filter { viewModel.billGroupIsVisible($0) }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Results")

            if !viewModel.hasActiveScenario {
                noActiveScenarioMessage
            }

            // CASH-FLOW CORRECTIVE PHASE: replaces the old "Extra Spending After Mid-Month/
            // End-of-Month Bills" rows (ScenarioSummaryBuilder.extraSpendingThroughCutoff, still
            // present and still used by currentExtraSpendingAfter/scenarioExtraSpendingAfter, but
            // no longer shown here) with genuine cumulative cash-flow breakdowns — see
            // ScenarioCashFlowCalculator's own header for the full root-cause explanation and why
            // this is the corrected replacement, not a MonthlyPlanCalculator change.
            midMonthCashFlowSection
            endMonthCashFlowSection
            monthlySavingsGoalSection

            // SCENARIO MONTHLY PLANNING CORRECTION: Results distinguishes three kinds of number so
            // they're never expected to reconcile with each other: actual timing-based cash flow
            // (the two Period cards above, and the Monthly Savings Goal card above), bill-group
            // totals (below — each timing bucket only, never all bills, using the same raw-amount
            // authority as the real Fixed Bills screen), and Monthly Planning (also below — built
            // directly from the two exact period results, never a monthly-equivalent estimate). See
            // this section's own sub-headers.
            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    Text("Bill Groups")
                        .font(Theme.captionFont.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Part 7: only a timing bucket with at least one eligible bill (Current or
                    // Scenario) is shown at all — no empty $0.00 rows. Part 6: each row's amount is
                    // the corrected raw-amount Bill Group total, the same authority the real Fixed
                    // Bills screen uses — never `ScenarioTimingTotal.expenses`/
                    // `estimatedMonthlyFixedExpenses`, which reintroduced the $1,949-vs-$1,989 gap.
                    ForEach(billGroupTimingsToDisplay, id: \.self) { timing in
                        if timing != billGroupTimingsToDisplay.first {
                            Divider().overlay(Theme.cardStroke)
                        }
                        comparisonRow(
                            title: "\(timing.label) Bill Group",
                            current: viewModel.currentBillGroupTotal(timing),
                            scenario: viewModel.scenarioBillGroupTotal(timing),
                            higherIsBetter: false,
                            onInfo: { infoTopic = .billGroup(timing) }
                        )
                    }
                    Divider().overlay(Theme.cardStroke)
                    Text("Monthly Planning")
                        .font(Theme.captionFont.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    comparisonRow(
                        title: "Monthly Available After Bills",
                        current: viewModel.currentMonthlyAvailableAfterBills,
                        scenario: viewModel.scenarioMonthlyAvailableAfterBills,
                        onInfo: { infoTopic = .monthlyAvailableAfterBills }
                    )
                    Divider().overlay(Theme.cardStroke)
                    comparisonRow(
                        title: "Monthly Savings Goal",
                        current: viewModel.currentMonthlySavingsGoal,
                        scenario: viewModel.scenarioMonthlySavingsGoal,
                        onInfo: { infoTopic = .monthlySavingsGoal }
                    )
                    Divider().overlay(Theme.cardStroke)
                    comparisonRow(
                        title: "Planned Monthly Spending Available",
                        current: viewModel.currentAvailableAfterPlannedSavings,
                        scenario: viewModel.scenarioAvailableAfterPlannedSavings,
                        onInfo: { infoTopic = .plannedMonthlySpendingAvailable }
                    )
                    Divider().overlay(Theme.cardStroke)
                    comparisonRow(
                        title: "Planned Weekly Spending",
                        current: viewModel.currentPlannedWeeklySpending,
                        scenario: viewModel.scenarioWeeklyRecommendationDisplay,
                        onInfo: { infoTopic = .plannedWeeklySpending }
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if !viewModel.cashFlowExcludedItems.isEmpty {
                cashFlowExcludedItemsDisclosure
            }

            if let explanation = ScenarioSummaryText.negativeFlexibleSpendingExplanation(
                scenarioFlexibleSpendingAvailable: viewModel.scenarioSummary.flexibleSpendingAvailable,
                activeModifications: viewModel.activeModifications
            ) {
                explanationCard(explanation)
            }
        }
    }

    // MARK: - Period cash-flow cards (MONTHLY OUTLOOK + SCENARIO PERIOD-CASH-FLOW CORRECTION —
    // Part 9: period-only labels, replacing the prior cumulative "Bills Due Through..." wording
    // that implied (incorrectly, for End-of-Month) a running total through the cutoff.

    private var midMonthCashFlowSection: some View {
        cashFlowCard(
            title: "Mid-Month Period",
            billsDueRowTitle: "Bills This Period",
            current: viewModel.currentMidMonthCashFlow(),
            scenario: viewModel.scenarioMidMonthCashFlow(),
            remainingRowTitle: "Remaining This Period",
            onInfo: { infoTopic = .midMonthCashFlow }
        )
    }

    private var endMonthCashFlowSection: some View {
        cashFlowCard(
            title: "End-of-Month Period",
            billsDueRowTitle: "Bills This Period",
            current: viewModel.currentEndMonthCashFlow(),
            scenario: viewModel.scenarioEndMonthCashFlow(),
            remainingRowTitle: "Remaining This Period",
            onInfo: { infoTopic = .endMonthCashFlow }
        )
    }

    /// One cash-flow breakdown card: Income This Period / Bills This Period / Remaining This
    /// Period — all shown at their live SCENARIO value (the full Current-vs-Scenario contributor
    /// detail lives in the info sheet, `onInfo`) — followed by the Remaining figure as a standard
    /// Current/Scenario/Difference `comparisonRow`, matching every other Results row on this
    /// screen.
    ///
    /// SCENARIO MONTHLY PLANNING CORRECTION — Part 1/2: the Monthly Savings Goal row is REMOVED
    /// from this card entirely (both `Breakdown.savingsAllocated` values are always `nil` now —
    /// see `ScenarioCashFlowCalculator`'s own header). The goal is a monthly planning concept, not
    /// something that belongs to only the End-of-Month Period — see `monthlySavingsGoalSection`,
    /// which reconciles it once, at the monthly level.
    @ViewBuilder
    private func cashFlowCard(
        title: String,
        billsDueRowTitle: String,
        current: ScenarioCashFlowCalculator.Breakdown,
        scenario: ScenarioCashFlowCalculator.Breakdown,
        remainingRowTitle: String,
        onInfo: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 4) {
                Text(title)
                    .font(Theme.bodyFont.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What does \(title) mean?")
            }
            .padding(.horizontal, Theme.Spacing.lg)

            CardBackground {
                VStack(spacing: Theme.Spacing.sm) {
                    // PHANTOM SCENARIO FIX — these two lines show the live Scenario period figures
                    // directly (not through `comparisonRow`), so they need the same
                    // `hasActiveScenario` gate applied explicitly here.
                    cashFlowLineRow(label: "Income This Period", amount: viewModel.hasActiveScenario ? scenario.totalIncome : 0, isNegative: false)
                    cashFlowLineRow(label: billsDueRowTitle, amount: viewModel.hasActiveScenario ? scenario.totalBills : 0, isNegative: true)
                    Divider().overlay(Theme.cardStroke)
                    comparisonRow(title: remainingRowTitle, current: current.remaining, scenario: scenario.remaining)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Monthly Savings Goal card (SCENARIO MONTHLY PLANNING CORRECTION — Part 3)

    /// Shown immediately below the End-of-Month Period card — a dedicated, explicit reconciliation
    /// of the Monthly Savings Goal at the MONTHLY level (never inside a single period card): the
    /// goal itself (Current/Scenario/Difference), then Monthly Available After Bills and Available
    /// After Planned Savings (Part 4/5's two authoritative formulas), so the arithmetic is never
    /// hidden inside an unrelated row.
    private var monthlySavingsGoalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 4) {
                Text("Monthly Savings Goal")
                    .font(Theme.bodyFont.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Button(action: { infoTopic = .monthlySavingsGoal }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What does Monthly Savings Goal mean?")
            }
            .padding(.horizontal, Theme.Spacing.lg)

            CardBackground {
                VStack(spacing: Theme.Spacing.sm) {
                    comparisonRow(title: "Goal", current: viewModel.currentMonthlySavingsGoal, scenario: viewModel.scenarioMonthlySavingsGoal)
                    Divider().overlay(Theme.cardStroke)
                    comparisonRow(
                        title: "Monthly Available After Bills",
                        current: viewModel.currentMonthlyAvailableAfterBills,
                        scenario: viewModel.scenarioMonthlyAvailableAfterBills,
                        onInfo: { infoTopic = .monthlyAvailableAfterBills }
                    )
                    Divider().overlay(Theme.cardStroke)
                    comparisonRow(
                        title: "Available After Planned Savings",
                        current: viewModel.currentAvailableAfterPlannedSavings,
                        scenario: viewModel.scenarioAvailableAfterPlannedSavings
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func cashFlowLineRow(label: String, amount: Decimal, isNegative: Bool) -> some View {
        HStack {
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            PrivacyAmountView(amount: isNegative ? -amount : amount, isPrivacyModeEnabled: privacyMode.isEnabled, font: Theme.bodyFont, color: Theme.textPrimary)
        }
    }

    /// Discloses active items that could NOT be counted in the cash-flow rows above — no stored
    /// date, or `.twiceMonthly` (no second stored date anywhere in this schema) — so a smaller
    /// total is always explainable rather than silently wrong. Same disclosure pattern Custom Date
    /// Range already established (`unsupportedItemsDisclosure`).
    private var cashFlowExcludedItemsDisclosure: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.statusWarning)
            Text("Not included in Mid-Month/End-of-Month Cash Flow — no known date: \(viewModel.cashFlowExcludedItems.map(\.name).joined(separator: ", "))")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.statusWarning.opacity(0.12))
        )
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    /// PHANTOM SCENARIO FIX — the required empty-state message, shown at the top of the Results
    /// section whenever `!viewModel.hasActiveScenario`. Deliberately styled distinctly from
    /// `explanationCard` (which uses a warning tint for "something's off" messages) — this is a
    /// neutral, expected state, not a problem.
    private var noActiveScenarioMessage: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "flask")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Scenario changes have been added.")
                    .font(Theme.captionFont.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Choose a \u{201C}What if…\u{201D} option to build a Scenario.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.accent.opacity(0.10))
        )
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func explanationCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.statusWarning)
            Text(text)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.statusWarning.opacity(0.12))
        )
        .padding(.horizontal, Theme.Spacing.lg)
    }

    /// `higherIsBetter` controls only the Difference column's color: `true` (the default, used by
    /// Flexible Spending Available/Projected Savings/Extra Spending After...) means a positive
    /// difference is favorable (green); `false` (used by Mid-Month/End-of-Month Total, which
    /// display the actual expense total for that timing bucket — `ScenarioTimingTotal.expenses`,
    /// never `net`/`abs(net)`) means a positive difference — a bigger bill total — is unfavorable
    /// (red). The Difference NUMBER and its "+"/"-" reading are unaffected either way: positive
    /// always literally means "the Scenario value is higher than Current," matching the two
    /// Current/Scenario columns' own sign convention exactly, so the direction of an increase or
    /// decrease is never lost.
    /// PHASE 7 — Part 4: `onInfo`, when non-nil, adds a small ⓘ button next to the title that
    /// opens a plain-English explanation sheet (see `ScenarioResultInfoTopic`/
    /// `explanation(for:)`) — only for rows that aren't immediately obvious from their name alone
    /// (the 4 rows explicitly named in this phase's brief); `nil` elsewhere, unchanged.
    @ViewBuilder
    /// PHANTOM SCENARIO FIX — the ONE shared gate every Results comparison row passes through:
    /// whenever `viewModel.hasActiveScenario` is `false`, the displayed Scenario and Difference are
    /// forced to `$0.00` regardless of what `scenario`/`current` actually compute to, representing
    /// "no comparison is currently active," never a real zero-valued alternative plan (see
    /// `MonthlyPlanScenarioViewModel.hasActiveScenario`'s own header). `current` is always shown
    /// unmodified. The Difference is never derived as `$0 − current` — it is forced to `$0.00`
    /// directly, exactly like the Scenario value itself.
    private func comparisonRow(title: String, current: Decimal, scenario: Decimal, higherIsBetter: Bool = true, onInfo: (() -> Void)? = nil) -> some View {
        let displayedScenario = viewModel.hasActiveScenario ? scenario : 0
        let difference = viewModel.hasActiveScenario ? (scenario - current) : 0
        let isFavorable = (difference > 0) == higherIsBetter
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                if let onInfo {
                    Button(action: onInfo) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What does \(title) mean?")
                }
            }
            HStack(spacing: Theme.Spacing.lg) {
                labeledAmount(title: "Current", amount: current)
                labeledAmount(title: "Scenario", amount: displayedScenario)
                labeledAmount(
                    title: "Difference",
                    amount: difference,
                    color: difference == 0 ? Theme.textSecondary : (isFavorable ? Theme.statusGood : Theme.statusOver),
                    prefix: difference > 0 ? "+" : ""
                )
            }
        }
    }

    @ViewBuilder
    private func labeledAmount(title: String, amount: Decimal, color: Color = Theme.textPrimary, prefix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
            PrivacyAmountView(amount: amount, isPrivacyModeEnabled: privacyMode.isEnabled, font: Theme.bodyFont, color: color, prefix: prefix)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Week-by-week (calculator-driven, no formula duplication)

    /// WEEKLY UX IMPROVEMENT — root cause of the prior confusing display: this section always
    /// rendered `viewModel.scenarioWeekByWeekComparisons`, which (even after the phantom-Scenario
    /// fix) still produced one row per week regardless of `hasActiveScenario`, and each row's own
    /// `ScenarioSummaryText.isDiscretionarySpendingUnavailable` check could independently show "No
    /// Weekly Spending Available" — a message about a genuinely-exhausted Scenario budget — even
    /// though no Scenario existed at all. The fix is presentation-only: no active Scenario now shows
    /// ONLY the real Current amount plus an explanatory message (never a Scenario/Difference, never
    /// weekly cards, never that message); an active Scenario shows the same Current/Scenario/
    /// Difference comparison as before, followed by an opt-in "Show Week-by-Week Breakdown" toggle
    /// (default off, never persisted) gating the exact same weekly cards this section already
    /// rendered — their own calculations (`scenarioWeekByWeekComparisons`,
    /// `isDiscretionarySpendingUnavailable`) are completely unchanged.
    private var weeklyComparisonSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 4) {
                Text("Scenario Planned Weekly Spending")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Button(action: { infoTopic = .scenarioWeeklyRecommendation }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What does Scenario Planned Weekly Spending mean?")
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if viewModel.hasActiveScenario {
                CardBackground {
                    comparisonRow(title: "Planned Weekly Spending", current: viewModel.currentPlannedWeeklySpending, scenario: viewModel.scenarioWeeklyRecommendationDisplay)
                }
                .padding(.horizontal, Theme.Spacing.lg)

                Toggle(isOn: $showWeekByWeekBreakdown) {
                    Text("Show Week-by-Week Breakdown")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .padding(.horizontal, Theme.Spacing.lg)

                if showWeekByWeekBreakdown {
                    if viewModel.scenarioMonthlyShortfall > 0 {
                        explanationCard("This Scenario has no weekly discretionary spending available. Shortfall: \(CurrencyFormat.string(from: viewModel.scenarioMonthlyShortfall)) — the amount by which this Scenario exceeds the available weekly plan.")
                    }

                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(viewModel.scenarioWeekByWeekComparisons) { comparison in
                            if ScenarioSummaryText.isDiscretionarySpendingUnavailable(comparison) {
                                noWeeklySpendingCard(for: comparison)
                            } else {
                                WeeklyPlanComparisonRow(comparison: comparison, isPrivacyModeEnabled: privacyMode.isEnabled)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            } else {
                CardBackground {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Current Planned Weekly Spending")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                        labeledAmount(title: "Current", amount: viewModel.currentPlannedWeeklySpending)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)

                noActiveScenarioWeeklyMessage
            }
        }
    }

    /// WEEKLY UX IMPROVEMENT — the required no-active-Scenario message for this section,
    /// deliberately distinct wording from `noActiveScenarioMessage` (the Results section's own
    /// empty-state), matching the task's exact specified copy for each location.
    private var noActiveScenarioWeeklyMessage: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "flask")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Scenario changes have been added.")
                    .font(Theme.captionFont.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Create a \u{201C}What If…\u{201D} Scenario to compare a new weekly spending plan.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.accent.opacity(0.10))
        )
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private func noWeeklySpendingCard(for comparison: MonthlyPlanCalculator.WeeklyPlanComparison) -> some View {
        CardBackground {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(DateRangeHelper.weekDisplayText(for: comparison.weekInterval))
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                Text(ScenarioSummaryText.discretionarySpendingUnavailableTitle)
                    .font(Theme.captionFont.weight(.semibold))
                    .foregroundStyle(Theme.statusWarning)
                Text(ScenarioSummaryText.discretionarySpendingUnavailableMessage)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Custom Date Range

    private var dateRangeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Custom Date Range")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    DatePicker("Start Date", selection: $dateRangeStart, displayedComponents: .date)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.textPrimary)
                    DatePicker("End Date", selection: $dateRangeEnd, displayedComponents: .date)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.textPrimary)

                    if !ScenarioDateRangeCalculator.isValidRange(start: dateRangeStart, end: dateRangeEnd) {
                        Text("Start Date must be on or before End Date.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.statusOver)
                    } else {
                        dateRangeResults
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            Text("Monthly Savings Goal is not included in custom date-range results.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Spacing.lg)

            if !unsupportedDateRangeItems.isEmpty {
                unsupportedItemsDisclosure
            }
        }
    }

    /// Active items whose frequency `ScenarioDateRangeCalculator` cannot count accurately (only
    /// `.twiceMonthly` today — see that type's own header) — shown so the user knows exactly what
    /// was excluded rather than seeing a silently-incomplete total.
    private var unsupportedDateRangeItems: [ScenarioLineItem] {
        ScenarioDateRangeCalculator.unsupportedItems(in: viewModel.engine.items)
    }

    private var unsupportedItemsDisclosure: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.statusWarning)
            Text("Not included — twice-monthly items have no stored second payment date: \(unsupportedDateRangeItems.map(\.name).joined(separator: ", "))")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.statusWarning.opacity(0.12))
        )
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var dateRangeResults: some View {
        let current = viewModel.currentDateRangeTotals(start: dateRangeStart, end: dateRangeEnd)
        let scenario = viewModel.scenarioDateRangeTotals(start: dateRangeStart, end: dateRangeEnd)

        VStack(spacing: Theme.Spacing.md) {
            Divider().overlay(Theme.cardStroke)
            comparisonRow(title: "Income in Range", current: current.income, scenario: scenario.income)
            Divider().overlay(Theme.cardStroke)
            comparisonRow(title: "Fixed Bills in Range", current: current.expenses, scenario: scenario.expenses, higherIsBetter: false)
            Divider().overlay(Theme.cardStroke)
            comparisonRow(title: "Extra Spending Before Savings", current: current.extraSpending, scenario: scenario.extraSpending)
        }
    }

    // MARK: - "My Scenario" (Phase 7 — Part 3)

    /// The ONE canonical list of active modifications — replaces the prior phases' three separate
    /// displays of the same list (the earlier Scenario Modifications list, the bullet-only
    /// Scenario Summary, and the bottom Active Changes list) with a single working list the user
    /// builds up over the course of a session: each row shows what changed (with edit/delete),
    /// followed by a plain-English rundown of which Results actually moved as a result. Shown
    /// whenever there's at least one
    /// active modification; "+ Add Another Change" reveals `whatIfSection` again WITHOUT resetting
    /// anything already built here (Part 3's explicit requirement).
    @ViewBuilder
    private var myScenarioSection: some View {
        if !viewModel.activeModifications.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                DashboardSectionHeader(title: "My Scenario")
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(viewModel.activeModifications.enumerated()), id: \.element.id) { index, modification in
                            ActiveModificationRow(
                                modification: modification,
                                isPrivacyModeEnabled: privacyMode.isEnabled,
                                onEdit: { startEditingModification(modification) }
                            ) {
                                viewModel.removeModification(modification.id)
                            }
                            if index < viewModel.activeModifications.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                        let resultLines = ScenarioSummaryText.resultChangeLines(current: viewModel.currentSummary, scenario: viewModel.scenarioSummary)
                        if !resultLines.isEmpty {
                            Divider().overlay(Theme.cardStroke)
                            ForEach(resultLines, id: \.self) { line in
                                Text(line)
                                    .font(Theme.captionFont.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)

                addAnotherChangeButton
            }
        }
    }

    private var addAnotherChangeButton: some View {
        Button {
            isChoosingModificationType = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("Add Another Change")
                    .font(Theme.bodyFont.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Another Change")
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Results row info explanations (Phase 7 — Part 4)

    private func explanation(for topic: ScenarioResultInfoTopic) -> String {
        switch topic {
        case .billGroup(let timing):
            return ScenarioSummaryText.billsTotalExplanation(for: timing, items: viewModel.engine.items)
        case .midMonthCashFlow:
            return ScenarioSummaryText.cashFlowExplanation(periodLabel: "Mid-Month", breakdown: viewModel.scenarioMidMonthCashFlow(), activeModifications: viewModel.activeModifications)
        case .endMonthCashFlow:
            return ScenarioSummaryText.cashFlowExplanation(periodLabel: "End-of-Month", breakdown: viewModel.scenarioEndMonthCashFlow(), activeModifications: viewModel.activeModifications)
        case .monthlySavingsGoal:
            return "The amount you're aiming to set aside this month. You can set this to $0.00 if you don't want a savings target right now. This is applied once, at the monthly level — never subtracted inside the Mid-Month or End-of-Month Period cards."
        case .monthlyAvailableAfterBills:
            return ScenarioSummaryText.monthlyAvailableAfterBillsExplanation()
        case .plannedMonthlySpendingAvailable:
            return ScenarioSummaryText.plannedMonthlySpendingAvailableExplanation()
        case .plannedWeeklySpending:
            return ScenarioSummaryText.scenarioWeeklyRecommendationExplanation(isExplicitOverride: viewModel.scenarioWeeklyRecommendationIsExplicitOverride)
        case .scenarioWeeklyRecommendation:
            return ScenarioSummaryText.scenarioWeeklyRecommendationExplanation(isExplicitOverride: viewModel.scenarioWeeklyRecommendationIsExplicitOverride)
        }
    }
}

/// One row in "My Scenario" — a leading checkmark (Part 3's "✓ VA Disability" motif — this change
/// is active), group label (Income / Monthly Savings Goal / the bill's real timing label) · action
/// · item name · original → new amount, with trailing edit/delete buttons. Read-only presentation
/// of `MonthlyPlanScenarioViewModel.ActiveModification`; never mutates scenario state itself beyond
/// the edit/remove actions it forwards to the view model.
private struct ActiveModificationRow: View {
    let modification: MonthlyPlanScenarioViewModel.ActiveModification
    var isPrivacyModeEnabled: Bool = false
    /// PHASE 6 — Part 1/7: every modification card carries both an edit and a delete action, laid
    /// out as a compact pair of icon buttons (Apple Settings-style row) rather than a single
    /// destructive action.
    var onEdit: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.statusGood)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(modification.groupLabel) \u{00B7} \(modification.kind)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Text(modification.itemName)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                amountSummary
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: Theme.Spacing.sm)

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit modification: \(modification.kind) \(modification.itemName)")

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.statusOver)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove modification: \(modification.kind) \(modification.itemName)")
            }
        }
    }

    @ViewBuilder
    private var amountSummary: some View {
        switch (modification.originalAmount, modification.newAmount) {
        case let (nil, .some(newAmount)):
            PrivacyAmountView(amount: newAmount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.captionFont, color: Theme.statusGood, prefix: "+")
        case let (.some(originalAmount), nil):
            PrivacyAmountView(amount: -originalAmount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.captionFont, color: Theme.statusOver)
        case let (.some(originalAmount), .some(newAmount)):
            HStack(spacing: 4) {
                PrivacyAmountView(amount: originalAmount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.captionFont, color: Theme.textTertiary)
                Text("\u{2192}")
                PrivacyAmountView(amount: newAmount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.captionFont, color: Theme.textPrimary)
            }
        case (nil, nil):
            EmptyView()
        }
    }
}

/// PHASE 7 — Part 4: which Results row's plain-English explanation is currently showing —
/// `Identifiable` so `.sheet(item:)` can present it. Presentation-only selection state, no
/// calculation of its own; see `MonthlyPlanScenarioView.explanation(for:)`.
private enum ScenarioResultInfoTopic: Identifiable, Equatable {
    /// SCENARIO MONTHLY PLANNING CORRECTION — Part 7: one case, parameterized by `PlanTiming`,
    /// covers every dynamically-shown Bill Group row (Beginning/Mid-Month/End-of-Month/Weekly/
    /// Custom Date) instead of one hardcoded case per timing.
    case billGroup(PlanTiming)
    /// CASH-FLOW CORRECTIVE PHASE: replaces the removed `.extraSpendingAfterMidMonth`/
    /// `.extraSpendingAfterEndMonth` topics (their rows were replaced by the Mid-Month/
    /// End-of-Month Cash Flow breakdowns above — see `resultsSection`'s own comment).
    case midMonthCashFlow
    case endMonthCashFlow
    case monthlySavingsGoal
    /// SCENARIO MONTHLY PLANNING CORRECTION — Part 4/5/9: replaces the removed "Average Monthly
    /// Flexible Spending" (a monthly-equivalent estimate, not built from the exact period results)
    /// and "Planned Monthly Spending" (the user's manually selected weekly × 4, a different concept
    /// from the monthly amount actually available).
    case monthlyAvailableAfterBills
    case plannedMonthlySpendingAvailable
    case plannedWeeklySpending
    /// WEEK-BY-WEEK RECALCULATION PHASE — the Scenario Week-by-Week card's weekly recommendation.
    case scenarioWeeklyRecommendation

    var id: String {
        switch self {
        case .billGroup(let timing): return "billGroup.\(timing.rawValue)"
        case .midMonthCashFlow: return "midMonthCashFlow"
        case .endMonthCashFlow: return "endMonthCashFlow"
        case .monthlySavingsGoal: return "monthlySavingsGoal"
        case .monthlyAvailableAfterBills: return "monthlyAvailableAfterBills"
        case .plannedMonthlySpendingAvailable: return "plannedMonthlySpendingAvailable"
        case .plannedWeeklySpending: return "plannedWeeklySpending"
        case .scenarioWeeklyRecommendation: return "scenarioWeeklyRecommendation"
        }
    }

    var title: String {
        switch self {
        case .billGroup(let timing): return "\(timing.label) Bill Group"
        case .midMonthCashFlow: return "Mid-Month Period"
        case .endMonthCashFlow: return "End-of-Month Period"
        case .monthlySavingsGoal: return "Monthly Savings Goal"
        case .monthlyAvailableAfterBills: return "Monthly Available After Bills"
        case .plannedMonthlySpendingAvailable: return "Planned Monthly Spending Available"
        case .plannedWeeklySpending: return "Planned Weekly Spending"
        case .scenarioWeeklyRecommendation: return "Scenario Planned Weekly Spending"
        }
    }
}

/// PHASE 7 — Part 4: a small sheet explaining one Results row in plain English — what it means,
/// how it's calculated, and which income/bills contributed (`explanation`, generated by
/// `ScenarioSummaryText`, never a new calculation of its own).
private struct ScenarioResultInfoView: View {
    let topic: ScenarioResultInfoTopic
    let explanation: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(explanation)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(topic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

// MARK: - Part 9: full dismissal behavior (Close / swipe-down / tap-outside, all with an
// unsaved-changes confirmation)

/// Wraps Scenario Builder editor content in a `NavigationStack` sheet that correctly detects EVERY
/// dismissal attempt — Close button, swipe-down, AND a tap on the sheet's dimmed scrim — and, when
/// there are unsaved edits, shows a "Discard Changes / Continue Editing" confirmation instead of
/// silently discarding.
///
/// INVESTIGATED FIRST: SwiftUI's `.interactiveDismissDisabled(_:)` (used in Phase 3) can only fully
/// BLOCK or fully ALLOW the swipe/tap gesture — it has no public callback for "the user just
/// attempted to dismiss." That is why Phase 3's dismissal behavior was incomplete (a blocked
/// gesture with no feedback is not the same as a confirmation). This type instead bridges
/// `UIKit`'s `UIAdaptivePresentationControllerDelegate`
/// (`presentationControllerShouldDismiss`/`presentationControllerDidAttemptToDismiss`) — the
/// smallest, standard iOS mechanism that reliably intercepts BOTH the swipe gesture and a
/// scrim tap, since UIKit routes both through the same delegate hook.
struct ScenarioEditorSheet<Content: View>: View {
    let title: String
    let hasUnsavedChanges: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingDiscardConfirmation = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                content()
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { attemptDismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .background(
            PresentationControllerDismissBridge(isDismissable: !hasUnsavedChanges) {
                isShowingDiscardConfirmation = true
            }
        )
        .confirmationDialog("Discard Changes?", isPresented: $isShowingDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Continue Editing", role: .cancel) {}
        }
        .preferredColorScheme(.dark)
    }

    private func attemptDismiss() {
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }
}

/// Bridges the enclosing `UIHostingController`'s `UIPresentationController` delegate into SwiftUI.
/// A single, invisible `UIViewController` is inserted via `.background(...)`; once it has a real
/// `parent` (the hosting controller SwiftUI created for the `.sheet`), its
/// `presentationController.delegate` is set to `Coordinator`, which implements the two UIKit hooks
/// that together cover every dismissal path: `presentationControllerShouldDismiss` (gates BOTH
/// swipe-down and a scrim tap — returning `false` blocks the dismissal exactly like
/// `interactiveDismissDisabled` would) and `presentationControllerDidAttemptToDismiss` (fires
/// exactly when a blocked attempt happens, calling `onAttemptToDismiss` so the confirmation can be
/// shown) — the reliable "attempted dismiss" signal SwiftUI's own public API doesn't expose.
/// `internal` (not `private`) so its `Coordinator` — the actual decision logic — is directly
/// constructible and testable from `FinanceTrackTests` without needing a real `UIPresentationController`
/// (impractical to instantiate in a unit test); `shouldDismiss()`/`didAttemptToDismiss()` are
/// argument-free wrappers around the two real `UIAdaptivePresentationControllerDelegate` methods
/// purely so a test can call them directly.
struct PresentationControllerDismissBridge: UIViewControllerRepresentable {
    var isDismissable: Bool
    var onAttemptToDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.isDismissable = isDismissable
        context.coordinator.onAttemptToDismiss = onAttemptToDismiss
        DispatchQueue.main.async {
            guard let presentationController = uiViewController.parent?.presentationController else { return }
            presentationController.delegate = context.coordinator
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isDismissable: isDismissable, onAttemptToDismiss: onAttemptToDismiss)
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var isDismissable: Bool
        var onAttemptToDismiss: () -> Void

        init(isDismissable: Bool, onAttemptToDismiss: @escaping () -> Void) {
            self.isDismissable = isDismissable
            self.onAttemptToDismiss = onAttemptToDismiss
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            shouldDismiss()
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            didAttemptToDismiss()
        }

        func shouldDismiss() -> Bool { isDismissable }
        func didAttemptToDismiss() { onAttemptToDismiss() }
    }
}
