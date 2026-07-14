import SwiftUI
import SwiftData

/// Add or edit an `IncomeSource`. Passing `incomeSource` switches this into edit mode, mirroring
/// `AddAccountView`'s add/edit pattern.
struct AddEditIncomeSourceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let editingSource: IncomeSource?

    @State private var name: String
    @State private var amount: Decimal?
    @State private var frequency: PlanFrequency
    @State private var timing: PlanTiming
    @State private var dayOfMonthText: String
    @State private var hasNextPayDate: Bool
    @State private var nextPayDate: Date
    @State private var note: String
    @State private var hasAttemptedSave = false

    @State private var createdSource: IncomeSource?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var autosaveStatus: AutosaveStatus = .idle
    @State private var isPresentingDiscardConfirmation = false

    init(incomeSource: IncomeSource? = nil) {
        self.editingSource = incomeSource
        _name = State(initialValue: incomeSource?.name ?? "")
        _amount = State(initialValue: incomeSource?.amount)
        _frequency = State(initialValue: incomeSource?.frequency ?? .monthly)
        _timing = State(initialValue: incomeSource?.timing ?? .beginningMonth)
        _dayOfMonthText = State(initialValue: incomeSource?.dayOfMonth.map { String($0) } ?? "")
        _hasNextPayDate = State(initialValue: incomeSource?.nextPayDate != nil)
        _nextPayDate = State(initialValue: incomeSource?.nextPayDate ?? .now)
        _note = State(initialValue: incomeSource?.note ?? "")
    }

    private var isEditing: Bool { editingSource != nil }
    /// The record autosave should write to: the one being edited, or the one autosave has
    /// already created for this brand-new draft (if any).
    private var activeRecord: IncomeSource? { editingSource ?? createdSource }

    private var hasMeaningfulInput: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty || amount != nil
    }

    /// True once there's unsaved, invalid, meaningful input on a draft that was never valid long
    /// enough to autosave — the only case where leaving the screen would silently lose input.
    private var shouldConfirmDiscard: Bool { activeRecord == nil && hasMeaningfulInput }

    private var validationMessages: [String] {
        AutosaveCommitter.incomeSourceValidationMessages(name: name, amount: amount, frequency: frequency, hasNextPayDate: hasNextPayDate)
    }

    private var isValid: Bool { validationMessages.isEmpty }

    private struct FormSnapshot: Equatable {
        var name: String
        var amount: Decimal?
        var frequency: PlanFrequency
        var timing: PlanTiming
        var dayOfMonthText: String
        var hasNextPayDate: Bool
        var nextPayDate: Date
        var note: String
    }

    private var formSnapshot: FormSnapshot {
        FormSnapshot(name: name, amount: amount, frequency: frequency, timing: timing, dayOfMonthText: dayOfMonthText, hasNextPayDate: hasNextPayDate, nextPayDate: nextPayDate, note: note)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    amountSection
                        .padding(.horizontal, Theme.Spacing.lg)
                    detailsSection
                        .padding(.horizontal, Theme.Spacing.lg)
                    if hasAttemptedSave, !validationMessages.isEmpty {
                        validationCard
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnBackgroundTap()
            .navigationTitle(isEditing ? "Edit Income" : "Add Income")
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
                    PremiumActionButton(title: isEditing ? "Done" : "Add Income", systemIconName: "checkmark") {
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

    private var amountSection: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                Text("Amount")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                CurrencyAmountField(
                    amount: $amount,
                    style: .hero,
                    isInvalid: hasAttemptedSave && (amount ?? 0) <= 0,
                    accessibilityLabel: "Income amount"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var detailsSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Details")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                labeledField(title: "Name") {
                    TextField("e.g. Paycheck", text: $name)
                        .textFieldStyle(.plain)
                }

                LabeledPickerRow(title: "Frequency", selection: $frequency) {
                    ForEach(PlanFrequency.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                LabeledPickerRow(title: "Timing", selection: $timing) {
                    ForEach(PlanTiming.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                labeledField(title: "Day of Month (optional)") {
                    TextField("1\u{2013}31", text: $dayOfMonthText)
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                }

                Toggle(frequency == .oneTime ? "Date" : "Next Pay Date", isOn: $hasNextPayDate.animation())
                    .tint(Theme.accent)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)

                if hasNextPayDate {
                    DatePicker("Date", selection: $nextPayDate, displayedComponents: .date)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.textPrimary)
                }

                labeledField(title: "Note (optional)") {
                    TextField("e.g. Bi-weekly direct deposit", text: $note)
                        .textFieldStyle(.plain)
                }
            }
        }
    }

    private var validationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(validationMessages, id: \.self) { message in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.statusOver)
                    Text(message)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.statusOver)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.statusOver.opacity(0.12))
        )
    }

    @ViewBuilder
    private func labeledField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            content()
                .padding(Theme.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    /// Explicit "Add Income" / "Done" tap: flushes any pending autosave immediately and only
    /// dismisses if the result is valid, so required fields are still enforced on this path.
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

    /// Writes the current fields to `activeRecord` (creating it once, the first time the draft
    /// becomes valid) if valid. Never creates a blank record and never creates more than one
    /// record for the same draft.
    @discardableResult
    private func commitAutosaveNow() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil

        guard isValid, let amount else {
            if hasMeaningfulInput {
                hasAttemptedSave = true
                autosaveStatus = .invalidDraft
            }
            return false
        }

        let resolvedDayOfMonth = Int(dayOfMonthText)
        let resolvedNextPayDate = hasNextPayDate ? nextPayDate : nil

        let record = AutosaveCommitter.commitIncomeSource(
            existing: activeRecord,
            name: name,
            amount: amount,
            frequency: frequency,
            timing: timing,
            dayOfMonth: resolvedDayOfMonth,
            nextPayDate: resolvedNextPayDate,
            note: note,
            modelContext: modelContext
        )
        if editingSource == nil { createdSource = record }
        autosaveStatus = .saved
        return true
    }
}

#Preview("Add") {
    AddEditIncomeSourceView()
}

#Preview("Edit") {
    AddEditIncomeSourceView(incomeSource: IncomeSource(name: "Paycheck", amount: 2100, frequency: .biweekly, timing: .customDate))
}
