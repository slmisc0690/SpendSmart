import SwiftUI
import SwiftData

/// Shared sheet for editing `BudgetSettings.weeklySpendingLimit`, opened from either the
/// Dashboard's setup card or the Weekly Budget screen's hero card. Both surfaces read from the
/// same `BudgetSettings` record, so saving here updates them immediately.
struct WeeklyLimitEditView: View {
    let settings: BudgetSettings?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var limit: Decimal?
    @State private var hasAttemptedSave = false

    @State private var createdSettings: BudgetSettings?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var autosaveStatus: AutosaveStatus = .idle
    @State private var isPresentingDiscardConfirmation = false

    init(settings: BudgetSettings?) {
        self.settings = settings
        _limit = State(initialValue: settings?.weeklySpendingLimit)
    }

    private var isValid: Bool {
        guard let limit else { return false }
        return limit >= 0
    }

    private var activeRecord: BudgetSettings? { settings ?? createdSettings }
    private var hasMeaningfulInput: Bool { limit != nil }
    private var shouldConfirmDiscard: Bool { activeRecord == nil && hasMeaningfulInput }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Weekly Spending Limit")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: $limit,
                                style: .hero,
                                isInvalid: hasAttemptedSave && !isValid,
                                accessibilityLabel: "Weekly spending limit"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    if hasAttemptedSave, !isValid {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.statusOver)
                            Text("Weekly limit must be 0 or greater.")
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
            .navigationTitle("Weekly Limit")
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
            .onChange(of: limit) { _, _ in scheduleAutosave() }
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

        guard isValid, let limit else {
            if hasMeaningfulInput {
                hasAttemptedSave = true
                autosaveStatus = .invalidDraft
            }
            return false
        }

        if let existing = activeRecord {
            existing.weeklySpendingLimit = limit
            existing.updatedAt = .now
        } else {
            let created = BudgetSettings(weeklySpendingLimit: limit)
            modelContext.insert(created)
            createdSettings = created
        }
        autosaveStatus = .saved
        return true
    }
}

#Preview {
    WeeklyLimitEditView(settings: BudgetSettings(weeklySpendingLimit: 350))
}
