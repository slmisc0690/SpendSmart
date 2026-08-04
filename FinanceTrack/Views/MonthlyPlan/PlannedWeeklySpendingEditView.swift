import SwiftUI
import SwiftData

/// MONTHLY PLAN + SCENARIO CORRECTIONS PHASE (Part 5/8) — sheet for setting Planned Weekly
/// Spending on the real Monthly Plan. Mirrors `MonthlyPlanSettingsEditView`'s autosave pattern.
/// Two modes: Automatic (no stored override — `MonthlyPlanSettings.plannedWeeklySpendingOverride`
/// stays `nil`, and Planned Weekly Spending is always `Average Monthly Flexible Spending ÷ 4`,
/// recalculated fresh every time flexible spending changes) or Custom (a deliberately configured
/// amount, including `$0.00`, persisted until the user switches back to Automatic).
struct PlannedWeeklySpendingEditView: View {
    let settings: MonthlyPlanSettings?
    /// `MonthlyPlanCalculator.automaticPlannedWeeklySpending(flexibleSpendingAvailable:)` for the
    /// real Monthly Plan's current Average Monthly Flexible Spending — passed in so this view does
    /// no calculation of its own (Part 13: one authoritative formula path, never duplicated here).
    let automaticAmount: Decimal

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isCustom: Bool
    @State private var customAmount: Decimal?
    @State private var hasAttemptedSave = false

    @State private var createdSettings: MonthlyPlanSettings?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var autosaveStatus: AutosaveStatus = .idle

    init(settings: MonthlyPlanSettings?, automaticAmount: Decimal) {
        self.settings = settings
        self.automaticAmount = automaticAmount
        let override = settings?.plannedWeeklySpendingOverride
        _isCustom = State(initialValue: override != nil)
        _customAmount = State(initialValue: override)
    }

    private var activeRecord: MonthlyPlanSettings? { settings ?? createdSettings }

    /// Valid whenever automatic mode is selected (nothing to validate) or Custom mode has a
    /// non-negative amount entered — an empty Custom field is NOT silently treated as `$0.00` (see
    /// `CurrencyInputState`'s own "hasContent" distinction), it is simply invalid until the user
    /// enters a real amount.
    private var isValid: Bool {
        guard isCustom else { return true }
        guard let customAmount else { return false }
        return customAmount >= 0
    }

    private struct FormSnapshot: Equatable {
        var isCustom: Bool
        var customAmount: Decimal?
    }
    private var formSnapshot: FormSnapshot { FormSnapshot(isCustom: isCustom, customAmount: customAmount) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.md) {
                            Text("Planned Weekly Spending")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)

                            Picker("Mode", selection: $isCustom) {
                                Text("Automatic").tag(false)
                                Text("Custom").tag(true)
                            }
                            .pickerStyle(.segmented)

                            if isCustom {
                                CurrencyAmountField(
                                    amount: $customAmount,
                                    style: .hero,
                                    placeholder: "Enter Amount",
                                    isInvalid: hasAttemptedSave && !isValid,
                                    accessibilityLabel: "Custom planned weekly spending"
                                )
                            } else {
                                VStack(spacing: 4) {
                                    PrivacyAmountView(amount: automaticAmount, isPrivacyModeEnabled: false, font: Theme.amountFont(36), color: Theme.textPrimary)
                                    Text("Average Monthly Flexible Spending ÷ 4")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.sm)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    if hasAttemptedSave, !isValid {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.statusOver)
                            Text("Custom amount must be 0 or greater.")
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
            .navigationTitle("Planned Weekly Spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
            if isCustom { hasAttemptedSave = true }
            autosaveStatus = isCustom ? .invalidDraft : .idle
            return
        }
        autosaveStatus = .saving
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run { commitAutosaveNow() }
        }
    }

    /// `isCustom == false` writes `plannedWeeklySpendingOverride = nil` — explicit automatic mode,
    /// never a stale leftover custom amount silently still in effect. `isCustom == true` writes the
    /// exact entered amount, including a deliberate `$0.00` (never coerced or defaulted).
    @discardableResult
    private func commitAutosaveNow() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil

        guard isValid else {
            if isCustom {
                hasAttemptedSave = true
                autosaveStatus = .invalidDraft
            }
            return false
        }

        let override = isCustom ? customAmount : nil
        if let existing = activeRecord {
            existing.plannedWeeklySpendingOverride = override
            existing.updatedAt = .now
        } else {
            let created = MonthlyPlanSettings(plannedWeeklySpendingOverride: override)
            modelContext.insert(created)
            createdSettings = created
        }
        autosaveStatus = .saved
        return true
    }
}

#Preview {
    PlannedWeeklySpendingEditView(settings: MonthlyPlanSettings(monthlySavingsGoal: 500), automaticAmount: 792.25)
}
