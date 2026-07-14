import SwiftUI
import SwiftData

/// Sheet for setting or clearing `BudgetSettings.monthlyGoal`. Unlike the weekly limit, a
/// monthly goal is optional — leaving the field blank saves `nil` (no goal) rather than being a
/// validation error.
struct MonthlyGoalEditView: View {
    let settings: BudgetSettings?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var goal: Decimal?
    @State private var hasAttemptedSave = false

    @State private var createdSettings: BudgetSettings?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var autosaveStatus: AutosaveStatus = .idle
    @State private var isPresentingDiscardConfirmation = false

    init(settings: BudgetSettings?) {
        self.settings = settings
        _goal = State(initialValue: settings?.monthlyGoal)
    }

    /// `nil` means "no goal" — a blank field is always valid. `CurrencyAmountField` can never
    /// itself produce a negative value (allowsNegative defaults to false), so this `>= 0` check
    /// is now purely defensive rather than load-bearing — kept to preserve the exact original
    /// validation contract.
    private var isValid: Bool { goal.map { $0 >= 0 } ?? true }

    private var activeRecord: BudgetSettings? { settings ?? createdSettings }
    /// A blank goal is valid on its own, so there's no "meaningful but invalid" input state left
    /// once negative typing is structurally impossible — kept `false` so a brand-new settings
    /// record's blank goal field never looks "unsaved."
    private var hasMeaningfulInput: Bool { false }
    private var shouldConfirmDiscard: Bool { activeRecord == nil && hasMeaningfulInput }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Monthly Goal")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: $goal,
                                style: .hero,
                                isInvalid: hasAttemptedSave && !isValid,
                                accessibilityLabel: "Monthly goal"
                            )
                            Text("Leave blank for no monthly goal")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    if hasAttemptedSave, !isValid {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.statusOver)
                            Text("Monthly goal must be 0 or greater.")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.statusOver)
                        }
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.statusOver.opacity(0.12))
                        )
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnBackgroundTap()
            .navigationTitle("Monthly Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if shouldConfirmDiscard {
                            isPresentingDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    AutosaveStatusView(status: autosaveStatus)
                    PremiumActionButton(title: "Done", systemIconName: "checkmark") {
                        save()
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xs)
                .background(.ultraThinMaterial)
            }
            .interactiveDismissDisabled(shouldConfirmDiscard)
            .confirmationDialog(
                "Discard unfinished entry?",
                isPresented: $isPresentingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .onChange(of: goal) { _, _ in scheduleAutosave() }
            .onDisappear { commitAutosaveNow() }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        hasAttemptedSave = true
        if commitAutosaveNow() {
            dismiss()
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard isValid else {
            autosaveStatus = hasMeaningfulInput ? .invalidDraft : .idle
            if hasMeaningfulInput { hasAttemptedSave = true }
            return
        }
        autosaveStatus = .saving
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run { commitAutosaveNow() }
        }
    }

    @discardableResult
    private func commitAutosaveNow() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil

        guard isValid else {
            if hasMeaningfulInput {
                hasAttemptedSave = true
                autosaveStatus = .invalidDraft
            }
            return false
        }

        if let existing = activeRecord {
            existing.monthlyGoal = goal
            existing.updatedAt = .now
        } else {
            let created = BudgetSettings(monthlyGoal: goal)
            modelContext.insert(created)
            createdSettings = created
        }
        autosaveStatus = .saved
        return true
    }
}

#Preview {
    MonthlyGoalEditView(settings: BudgetSettings(monthlyGoal: 1400))
}
