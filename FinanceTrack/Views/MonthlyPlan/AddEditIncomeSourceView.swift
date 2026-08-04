import SwiftUI
import SwiftData

/// Add or edit an `IncomeSource`. Passing `incomeSource` switches this into edit mode, mirroring
/// `AddAccountView`'s add/edit pattern.
///
/// INCOME SCHEDULING PHASE — the Deposit Schedule section (below "Amount Per Deposit") replaces
/// the old generic Timing/Day-of-Month/Next-Pay-Date fields with fields specific to the chosen
/// Frequency, matching `MonthlyDepositDay`/`IncomeSource`'s own new schedule model:
/// - Weekly/Biweekly: one "Next Deposit Date" picker (`nextPayDate`, unchanged field).
/// - Monthly: one "Deposit Day" picker — a numeric day (1–31) or Last Day of Month.
/// - Twice Monthly: two "Deposit Day" pickers (First/Second), each numeric-or-Last-Day, defaulting
///   to 1st/15th ONLY for a brand-new record (never silently applied to an existing one whose
///   second day was never actually known — see `IncomeSource.isTwiceMonthlyScheduleComplete`).
/// - Yearly: one "Deposit Date" picker (month + day, via `nextPayDate`).
/// - One-Time: no longer selectable in the Frequency picker for a NEW income. An income already
///   using `.oneTime` (a pre-this-phase record) keeps its own Date field so it remains editable
///   and calculates exactly as before; its own Frequency value stays visible in the picker for
///   THAT editing session only (never offered when creating new, per this phase's own product
///   requirement) — see `frequencyOptions`.
struct AddEditIncomeSourceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let editingSource: IncomeSource?

    @State private var name: String
    @State private var amount: Decimal?
    @State private var frequency: PlanFrequency

    // Weekly / Biweekly / Yearly / legacy One-Time: a single anchor date.
    @State private var hasNextPayDate: Bool
    @State private var nextPayDate: Date

    // Monthly: one deposit day.
    @State private var monthlyDayText: String
    @State private var monthlyIsLastDay: Bool

    // Twice Monthly: two deposit days.
    @State private var twiceMonthlyFirstDayText: String
    @State private var twiceMonthlyFirstIsLastDay: Bool
    @State private var twiceMonthlySecondDayText: String
    @State private var twiceMonthlySecondIsLastDay: Bool

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
        _hasNextPayDate = State(initialValue: incomeSource?.nextPayDate != nil)
        _nextPayDate = State(initialValue: incomeSource?.nextPayDate ?? .now)
        _monthlyDayText = State(initialValue: incomeSource?.dayOfMonth.map { String($0) } ?? "")
        _monthlyIsLastDay = State(initialValue: incomeSource?.monthlyDepositDayIsLastDay ?? false)
        // Defaults (1st/15th) apply ONLY to a brand-new record — never silently to an existing
        // Twice-Monthly record whose second deposit day was never actually known.
        _twiceMonthlyFirstDayText = State(initialValue: incomeSource?.twiceMonthlyFirstDayNumber.map { String($0) } ?? (incomeSource == nil ? "1" : ""))
        _twiceMonthlyFirstIsLastDay = State(initialValue: incomeSource?.twiceMonthlyFirstDayIsLastDay ?? false)
        _twiceMonthlySecondDayText = State(initialValue: incomeSource?.twiceMonthlySecondDayNumber.map { String($0) } ?? (incomeSource == nil ? "15" : ""))
        _twiceMonthlySecondIsLastDay = State(initialValue: incomeSource?.twiceMonthlySecondDayIsLastDay ?? false)
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

    /// One-Time is never offered for a NEW income. An income already using `.oneTime` keeps it in
    /// its own picker options for this editing session only, so its current value still displays
    /// correctly and isn't silently dropped out from under it.
    private var frequencyOptions: [PlanFrequency] {
        PlanFrequency.allCases.filter { $0 != .oneTime || editingSource?.frequency == .oneTime }
    }

    private var monthlyDepositDay: MonthlyDepositDay? {
        MonthlyDepositDay.from(dayNumber: Int(monthlyDayText), isLastDay: monthlyIsLastDay)
    }

    private var twiceMonthlyFirstDeposit: MonthlyDepositDay? {
        MonthlyDepositDay.from(dayNumber: Int(twiceMonthlyFirstDayText), isLastDay: twiceMonthlyFirstIsLastDay)
    }

    private var twiceMonthlySecondDeposit: MonthlyDepositDay? {
        MonthlyDepositDay.from(dayNumber: Int(twiceMonthlySecondDayText), isLastDay: twiceMonthlySecondIsLastDay)
    }

    private var validationMessages: [String] {
        AutosaveCommitter.incomeSourceValidationMessages(
            name: name,
            amount: amount,
            frequency: frequency,
            hasNextPayDate: hasNextPayDate,
            monthlyDepositDay: monthlyDepositDay,
            twiceMonthlyFirstDeposit: twiceMonthlyFirstDeposit,
            twiceMonthlySecondDeposit: twiceMonthlySecondDeposit
        )
    }

    private var isValid: Bool { validationMessages.isEmpty }

    private struct FormSnapshot: Equatable {
        var name: String
        var amount: Decimal?
        var frequency: PlanFrequency
        var hasNextPayDate: Bool
        var nextPayDate: Date
        var monthlyDayText: String
        var monthlyIsLastDay: Bool
        var twiceMonthlyFirstDayText: String
        var twiceMonthlyFirstIsLastDay: Bool
        var twiceMonthlySecondDayText: String
        var twiceMonthlySecondIsLastDay: Bool
        var note: String
    }

    private var formSnapshot: FormSnapshot {
        FormSnapshot(
            name: name, amount: amount, frequency: frequency,
            hasNextPayDate: hasNextPayDate, nextPayDate: nextPayDate,
            monthlyDayText: monthlyDayText, monthlyIsLastDay: monthlyIsLastDay,
            twiceMonthlyFirstDayText: twiceMonthlyFirstDayText, twiceMonthlyFirstIsLastDay: twiceMonthlyFirstIsLastDay,
            twiceMonthlySecondDayText: twiceMonthlySecondDayText, twiceMonthlySecondIsLastDay: twiceMonthlySecondIsLastDay,
            note: note
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    amountSection
                        .padding(.horizontal, Theme.Spacing.lg)
                    detailsSection
                        .padding(.horizontal, Theme.Spacing.lg)
                    depositScheduleSection
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
                Text("Amount Per Deposit")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                CurrencyAmountField(
                    amount: $amount,
                    style: .hero,
                    isInvalid: hasAttemptedSave && (amount ?? 0) <= 0,
                    accessibilityLabel: "Amount per deposit"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var detailsSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Income Name")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                labeledField(title: "Name") {
                    TextField("e.g. Scott Paycheck", text: $name)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Income name")
                }

                if editingSource?.frequency == .oneTime {
                    legacyOneTimeNotice
                }

                LabeledPickerRow(title: "Frequency", selection: $frequency) {
                    ForEach(frequencyOptions) { option in
                        Text(option.label).tag(option)
                    }
                }
                .accessibilityLabel("Frequency")

                labeledField(title: "Note (optional)") {
                    TextField("e.g. Direct deposit", text: $note)
                        .textFieldStyle(.plain)
                }
            }
        }
    }

    private var legacyOneTimeNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.statusWarning)
            Text("This income uses the legacy One-Time frequency. It still calculates as before. One-Time is no longer offered for new income — choose a new Frequency below if this income actually repeats.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.statusWarning.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Deposit Schedule (frequency-specific)

    @ViewBuilder
    private var depositScheduleSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Deposit Schedule")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                if let explanation = frequencyExplanation {
                    Text(explanation)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                }

                switch frequency {
                case .weekly:
                    nextDepositDateField(title: "First or Next Deposit Date")
                case .biweekly:
                    nextDepositDateField(title: "First or Next Deposit Date")
                case .monthly:
                    depositDayField(
                        title: "Monthly Deposit",
                        dayText: $monthlyDayText,
                        isLastDay: $monthlyIsLastDay,
                        accessibilityPrefix: "Monthly deposit"
                    )
                case .twiceMonthly:
                    depositDayField(
                        title: "First Monthly Deposit",
                        dayText: $twiceMonthlyFirstDayText,
                        isLastDay: $twiceMonthlyFirstIsLastDay,
                        accessibilityPrefix: "First monthly deposit"
                    )
                    depositDayField(
                        title: "Second Monthly Deposit",
                        dayText: $twiceMonthlySecondDayText,
                        isLastDay: $twiceMonthlySecondIsLastDay,
                        accessibilityPrefix: "Second monthly deposit"
                    )
                    if let first = twiceMonthlyFirstDeposit, first == twiceMonthlySecondDeposit {
                        Text("Choose two different days — right now both are set to the \(first.displayLabel).")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.statusOver)
                    }
                case .yearly:
                    nextDepositDateField(title: "Deposit Date")
                case .oneTime:
                    nextDepositDateField(title: "Date")
                case .quarterly:
                    nextDepositDateField(title: "Next Deposit Date")
                }
            }
        }
    }

    /// PART 1/3: plain-language explanation of what the chosen Frequency actually means — shown
    /// directly under "Deposit Schedule" so "Every 2 Weeks" is never confused with "Twice a Month"
    /// (a genuinely different schedule: every 14 days from one anchor vs. two configured days each
    /// calendar month).
    private var frequencyExplanation: String? {
        switch frequency {
        case .weekly: return "Future deposits repeat every 7 days from this date."
        case .biweekly: return "A deposit repeats every 14 days from the date selected below."
        case .twiceMonthly: return "Choose the two days you receive this deposit each month."
        default: return nil
        }
    }

    @ViewBuilder
    private func nextDepositDateField(title: String) -> some View {
        Toggle(title, isOn: $hasNextPayDate.animation())
            .tint(Theme.accent)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityLabel(title)

        if hasNextPayDate {
            DatePicker(title, selection: $nextPayDate, displayedComponents: .date)
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityLabel(title)
        }
    }

    /// One "day within a month" picker for Monthly's single selector and Twice a Month's two
    /// selectors: a preset menu (Beginning of Month / Mid-Month / Last Day of Month / Choose a
    /// Day — the approved labels, PART 2) plus a numeric text field that only appears for "Choose
    /// a Day." High-contrast text, native numeric keyboard, VoiceOver label distinct per instance
    /// (`accessibilityPrefix`) so First/Second are never ambiguous.
    @ViewBuilder
    private func depositDayField(title: String, dayText: Binding<String>, isLastDay: Binding<Bool>, accessibilityPrefix: String) -> some View {
        let currentDay = MonthlyDepositDay.from(dayNumber: Int(dayText.wrappedValue), isLastDay: isLastDay.wrappedValue)
        let preset = MonthlyDepositDayPreset.matching(currentDay)

        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Picker(title, selection: Binding<MonthlyDepositDayPreset>(
                get: { preset },
                set: { newPreset in
                    switch newPreset {
                    case .beginningOfMonth:
                        isLastDay.wrappedValue = false
                        dayText.wrappedValue = "1"
                    case .midMonth:
                        isLastDay.wrappedValue = false
                        dayText.wrappedValue = "15"
                    case .lastDayOfMonth:
                        isLastDay.wrappedValue = true
                    case .chooseADay:
                        isLastDay.wrappedValue = false
                        if Int(dayText.wrappedValue) == nil { dayText.wrappedValue = "" }
                    }
                }
            )) {
                ForEach(MonthlyDepositDayPreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)
            .accessibilityLabel("\(accessibilityPrefix) preset")

            if preset == .chooseADay {
                TextField("1\u{2013}31", text: dayText)
                    .textFieldStyle(.plain)
                    .keyboardType(.numberPad)
                    .padding(Theme.Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityLabel("\(accessibilityPrefix) number")
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

        let resolvedNextPayDate = hasNextPayDate ? nextPayDate : nil
        let resolvedMonthlyDay: Int?
        switch monthlyDepositDay {
        case .some(.numericDay(let day)): resolvedMonthlyDay = day
        default: resolvedMonthlyDay = nil
        }
        let resolvedFirstDay: Int?
        switch twiceMonthlyFirstDeposit {
        case .some(.numericDay(let day)): resolvedFirstDay = day
        default: resolvedFirstDay = nil
        }
        let resolvedSecondDay: Int?
        switch twiceMonthlySecondDeposit {
        case .some(.numericDay(let day)): resolvedSecondDay = day
        default: resolvedSecondDay = nil
        }

        let record = AutosaveCommitter.commitIncomeSource(
            existing: activeRecord,
            name: name,
            amount: amount,
            frequency: frequency,
            timing: editingSource?.timing ?? .beginningMonth,
            dayOfMonth: resolvedMonthlyDay,
            nextPayDate: resolvedNextPayDate,
            monthlyDepositDayIsLastDay: monthlyIsLastDay,
            twiceMonthlyFirstDayNumber: resolvedFirstDay,
            twiceMonthlyFirstDayIsLastDay: twiceMonthlyFirstIsLastDay,
            twiceMonthlySecondDayNumber: resolvedSecondDay,
            twiceMonthlySecondDayIsLastDay: twiceMonthlySecondIsLastDay,
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
