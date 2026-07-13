import SwiftUI
import SwiftData

/// Add or edit a `RecurringExpense`. Passing `recurringExpense` switches this into edit mode,
/// mirroring `AddAccountView`'s add/edit pattern.
struct AddEditRecurringExpenseView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    private let editingExpense: RecurringExpense?

    @State private var name: String
    @State private var amount: Decimal?
    @State private var category: Category?
    @State private var frequency: PlanFrequency
    @State private var timing: PlanTiming
    @State private var dayOfMonthText: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var paymentAccount: Account?
    @State private var isEssential: Bool
    @State private var note: String
    @State private var hasAttemptedSave = false

    @State private var createdExpense: RecurringExpense?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var autosaveStatus: AutosaveStatus = .idle
    @State private var isPresentingDiscardConfirmation = false

    init(recurringExpense: RecurringExpense? = nil) {
        self.editingExpense = recurringExpense
        _name = State(initialValue: recurringExpense?.name ?? "")
        _amount = State(initialValue: recurringExpense?.amount)
        _category = State(initialValue: recurringExpense?.category)
        _frequency = State(initialValue: recurringExpense?.frequency ?? .monthly)
        _timing = State(initialValue: recurringExpense?.timing ?? .beginningMonth)
        _dayOfMonthText = State(initialValue: recurringExpense?.dayOfMonth.map { String($0) } ?? "")
        _hasDueDate = State(initialValue: recurringExpense?.dueDate != nil)
        _dueDate = State(initialValue: recurringExpense?.dueDate ?? .now)
        _paymentAccount = State(initialValue: recurringExpense?.paymentAccount)
        _isEssential = State(initialValue: recurringExpense?.isEssential ?? true)
        _note = State(initialValue: recurringExpense?.note ?? "")
    }

    private var isEditing: Bool { editingExpense != nil }
    /// The record autosave should write to: the one being edited, or the one autosave has
    /// already created for this brand-new draft (if any).
    private var activeRecord: RecurringExpense? { editingExpense ?? createdExpense }

    private var hasMeaningfulInput: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty || amount != nil
    }

    private var shouldConfirmDiscard: Bool { activeRecord == nil && hasMeaningfulInput }

    private var validationMessages: [String] {
        AutosaveCommitter.recurringExpenseValidationMessages(name: name, amount: amount, frequency: frequency, hasDueDate: hasDueDate)
    }

    private var isValid: Bool { validationMessages.isEmpty }

    private struct FormSnapshot: Equatable {
        var name: String
        var amount: Decimal?
        var category: Category?
        var frequency: PlanFrequency
        var timing: PlanTiming
        var dayOfMonthText: String
        var hasDueDate: Bool
        var dueDate: Date
        var paymentAccount: Account?
        var isEssential: Bool
        var note: String
    }

    private var formSnapshot: FormSnapshot {
        FormSnapshot(name: name, amount: amount, category: category, frequency: frequency, timing: timing, dayOfMonthText: dayOfMonthText, hasDueDate: hasDueDate, dueDate: dueDate, paymentAccount: paymentAccount, isEssential: isEssential, note: note)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    amountSection
                        .padding(.horizontal, Theme.Spacing.lg)
                    detailsSection
                        .padding(.horizontal, Theme.Spacing.lg)
                    linkSection
                        .padding(.horizontal, Theme.Spacing.lg)
                    if hasAttemptedSave, !validationMessages.isEmpty {
                        validationCard
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Bill" : "Add Bill")
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
                    PremiumActionButton(title: isEditing ? "Done" : "Add Bill", systemIconName: "checkmark") {
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
                    accessibilityLabel: "Bill amount"
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
                    TextField("e.g. Rent", text: $name)
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

                Toggle(frequency == .oneTime ? "Due Date" : "Next Due Date", isOn: $hasDueDate.animation())
                    .tint(Theme.accent)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)

                if hasDueDate {
                    DatePicker("Due Date", selection: $dueDate, displayedComponents: .date)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.textPrimary)
                }

                TransactionToggleRow(
                    title: "Essential",
                    subtitle: "Rent, insurance, and other must-pay bills",
                    isOn: $isEssential
                )

                labeledField(title: "Note (optional)") {
                    TextField("e.g. Auto-pay on the 1st", text: $note)
                        .textFieldStyle(.plain)
                }
            }
        }
    }

    private var linkSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Category & Account")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                LabeledPickerRow(title: "Category (optional)", selection: $category) {
                    Text("None").tag(Category?.none)
                    ForEach(categories) { option in
                        Text(option.name).tag(Optional(option))
                    }
                }

                LabeledPickerRow(title: "Payment Account (optional)", selection: $paymentAccount) {
                    Text("None").tag(Account?.none)
                    ForEach(accounts) { option in
                        Text(option.name).tag(Optional(option))
                    }
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

    /// Explicit "Add Bill" / "Done" tap: flushes any pending autosave immediately and only
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
        let resolvedDueDate = hasDueDate ? dueDate : nil

        let record = AutosaveCommitter.commitRecurringExpense(
            existing: activeRecord,
            name: name,
            amount: amount,
            category: category,
            frequency: frequency,
            timing: timing,
            dayOfMonth: resolvedDayOfMonth,
            dueDate: resolvedDueDate,
            paymentAccount: paymentAccount,
            isEssential: isEssential,
            note: note,
            modelContext: modelContext
        )
        if editingExpense == nil { createdExpense = record }
        autosaveStatus = .saved
        return true
    }
}

#Preview("Add") {
    AddEditRecurringExpenseView()
        .modelContainer(SampleData.previewContainer)
}

#Preview("Edit") {
    AddEditRecurringExpenseView(recurringExpense: RecurringExpense(name: "Rent", amount: 1800, frequency: .monthly, timing: .beginningMonth))
        .modelContainer(SampleData.previewContainer)
}
