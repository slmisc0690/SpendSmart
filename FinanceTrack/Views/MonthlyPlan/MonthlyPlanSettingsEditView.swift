import SwiftUI
import SwiftData

/// Sheet for editing the Monthly Plan's savings goal, optional buffer, and the two automation
/// toggles. Mirrors `MonthlyGoalEditView`'s pattern — blank buffer is valid (means "no buffer").
struct MonthlyPlanSettingsEditView: View {
    let settings: MonthlyPlanSettings?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var savingsGoal: Decimal?
    @State private var buffer: Decimal?
    @State private var useRecommendedWeeklyBudget: Bool
    @State private var autoUpdateWeeklyBudgetFromPlan: Bool
    @State private var hasAttemptedSave = false

    @State private var createdSettings: MonthlyPlanSettings?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var autosaveStatus: AutosaveStatus = .idle
    @State private var isPresentingDiscardConfirmation = false

    init(settings: MonthlyPlanSettings?) {
        self.settings = settings
        _savingsGoal = State(initialValue: settings?.monthlySavingsGoal)
        _buffer = State(initialValue: settings?.bufferAmount)
        _useRecommendedWeeklyBudget = State(initialValue: settings?.useRecommendedWeeklyBudget ?? false)
        _autoUpdateWeeklyBudgetFromPlan = State(initialValue: settings?.autoUpdateWeeklyBudgetFromPlan ?? false)
    }

    private var isValid: Bool {
        guard let savingsGoal, savingsGoal >= 0 else { return false }
        guard buffer.map({ $0 >= 0 }) ?? true else { return false }
        return true
    }

    private var activeRecord: MonthlyPlanSettings? { settings ?? createdSettings }
    private var hasMeaningfulInput: Bool { savingsGoal != nil || buffer != nil }
    private var shouldConfirmDiscard: Bool { activeRecord == nil && hasMeaningfulInput }

    private struct FormSnapshot: Equatable {
        var savingsGoal: Decimal?
        var buffer: Decimal?
        var useRecommendedWeeklyBudget: Bool
        var autoUpdateWeeklyBudgetFromPlan: Bool
    }

    private var formSnapshot: FormSnapshot {
        FormSnapshot(savingsGoal: savingsGoal, buffer: buffer, useRecommendedWeeklyBudget: useRecommendedWeeklyBudget, autoUpdateWeeklyBudgetFromPlan: autoUpdateWeeklyBudgetFromPlan)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Monthly Savings Goal")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: $savingsGoal,
                                style: .hero,
                                isInvalid: hasAttemptedSave && (savingsGoal ?? -1) < 0,
                                accessibilityLabel: "Monthly savings goal"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Buffer Amount (optional)")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: $buffer,
                                style: .hero,
                                isInvalid: hasAttemptedSave && (buffer ?? 0) < 0,
                                accessibilityLabel: "Buffer amount"
                            )
                            Text("Extra cushion set aside before your weekly limit is calculated")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    CardBackground {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            TransactionToggleRow(
                                title: "Use Recommended Weekly Budget",
                                subtitle: "Show the recommended limit as the primary number in Monthly Plan",
                                isOn: $useRecommendedWeeklyBudget
                            )
                            Divider().overlay(Theme.cardStroke)
                            TransactionToggleRow(
                                title: "Auto-Update Weekly Budget",
                                subtitle: "Automatically set your weekly limit from this plan whenever it changes",
                                isOn: $autoUpdateWeeklyBudgetFromPlan
                            )
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    if hasAttemptedSave, !isValid {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.statusOver)
                            Text("Savings goal and buffer must be 0 or greater.")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.statusOver)
                        }
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.statusOver.opacity(0.12)))
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnBackgroundTap()
            .navigationTitle("Savings Goal")
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
            .onChange(of: formSnapshot) { _, _ in scheduleAutosave() }
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

        guard isValid, let savingsGoal else {
            if hasMeaningfulInput {
                hasAttemptedSave = true
                autosaveStatus = .invalidDraft
            }
            return false
        }

        if let existing = activeRecord {
            existing.monthlySavingsGoal = savingsGoal
            existing.bufferAmount = buffer
            existing.useRecommendedWeeklyBudget = useRecommendedWeeklyBudget
            existing.autoUpdateWeeklyBudgetFromPlan = autoUpdateWeeklyBudgetFromPlan
            existing.updatedAt = .now
        } else {
            let created = MonthlyPlanSettings(
                monthlySavingsGoal: savingsGoal,
                bufferAmount: buffer,
                useRecommendedWeeklyBudget: useRecommendedWeeklyBudget,
                autoUpdateWeeklyBudgetFromPlan: autoUpdateWeeklyBudgetFromPlan
            )
            modelContext.insert(created)
            createdSettings = created
        }
        autosaveStatus = .saved
        return true
    }
}

#Preview {
    MonthlyPlanSettingsEditView(settings: MonthlyPlanSettings(monthlySavingsGoal: 500, bufferAmount: 100))
}
