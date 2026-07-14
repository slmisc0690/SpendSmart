import SwiftUI
import SwiftData

/// Add or edit an account. Passing `account` switches this into edit mode: fields are pre-filled
/// and Save mutates that account in place rather than inserting a new one. Editing the balance
/// here is a plain field correction (no `FinanceTransaction` record) — the audited way to change
/// a balance is `BalanceAdjustmentView`.
struct AddAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let editingAccount: Account?

    @State private var name: String
    @State private var type: AccountType
    @State private var balance: Decimal?
    @State private var institutionName: String
    @State private var lastFourDigitsText: String
    @State private var creditLimit: Decimal?
    @State private var minimumPayment: Decimal?
    @State private var hasPaymentDueDate: Bool
    @State private var paymentDueDate: Date
    @State private var defaultCountsTowardMonthlySpending: Bool
    @State private var showsInRecentActivity: Bool
    @State private var hasAttemptedSave = false

    @State private var createdAccount: Account?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var autosaveStatus: AutosaveStatus = .idle
    @State private var isPresentingDiscardConfirmation = false

    init(account: Account? = nil) {
        self.editingAccount = account
        _name = State(initialValue: account?.name ?? "")
        _type = State(initialValue: account?.type ?? .checking)
        _balance = State(initialValue: account?.currentBalance)
        _institutionName = State(initialValue: account?.institutionName ?? "")
        _lastFourDigitsText = State(initialValue: account?.lastFourDigits ?? "")
        _creditLimit = State(initialValue: account?.creditLimit)
        _minimumPayment = State(initialValue: account?.minimumPayment)
        _hasPaymentDueDate = State(initialValue: account?.paymentDueDate != nil)
        _paymentDueDate = State(initialValue: account?.paymentDueDate ?? .now)
        // A brand-new account defaults OFF (register-only-first) — an existing account being
        // edited always loads its own already-stored value, never this default.
        _defaultCountsTowardMonthlySpending = State(initialValue: account?.defaultCountsTowardMonthlySpending ?? false)
        // Both a brand-new account and an existing one default to visible in Recent Activity —
        // `Account.showsInRecentActivity`'s own schema default is `true`, this just mirrors that
        // for the form's starting state (an existing account always loads its own stored value).
        _showsInRecentActivity = State(initialValue: account?.showsInRecentActivity ?? true)
    }

    private var isEditing: Bool { editingAccount != nil }

    private var validationMessages: [String] {
        var messages: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            messages.append("Account name is required.")
        }
        if balance == nil {
            messages.append("Current balance is required.")
        }
        if type == .creditCard, let creditLimit, creditLimit < 0 {
            messages.append("Credit limit must be 0 or greater.")
        }
        if !lastFourDigitsText.isEmpty, lastFourDigitsText.count != 4 {
            messages.append("Last four digits must be exactly 4 digits.")
        }
        return messages
    }

    private var isValid: Bool { validationMessages.isEmpty }

    private var activeRecord: Account? { editingAccount ?? createdAccount }
    private var hasMeaningfulInput: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty || balance != nil
    }
    private var shouldConfirmDiscard: Bool { activeRecord == nil && hasMeaningfulInput }

    private struct FormSnapshot: Equatable {
        var name: String
        var type: AccountType
        var balance: Decimal?
        var institutionName: String
        var lastFourDigitsText: String
        var creditLimit: Decimal?
        var minimumPayment: Decimal?
        var hasPaymentDueDate: Bool
        var paymentDueDate: Date
        var defaultCountsTowardMonthlySpending: Bool
        var showsInRecentActivity: Bool
    }

    private var formSnapshot: FormSnapshot {
        FormSnapshot(name: name, type: type, balance: balance, institutionName: institutionName, lastFourDigitsText: lastFourDigitsText, creditLimit: creditLimit, minimumPayment: minimumPayment, hasPaymentDueDate: hasPaymentDueDate, paymentDueDate: paymentDueDate, defaultCountsTowardMonthlySpending: defaultCountsTowardMonthlySpending, showsInRecentActivity: showsInRecentActivity)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    accountSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    balanceSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    if type == .creditCard {
                        creditCardSection
                            .padding(.horizontal, Theme.Spacing.lg)
                    }

                    monthlySpendingDefaultSection
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
            .navigationTitle(isEditing ? "Edit Manual Tracked Account" : "Add Manual Tracked Account")
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
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Done" : "Add Account") {
                        save()
                    }
                    .disabled(!isValid)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if autosaveStatus != .idle {
                    AutosaveStatusView(status: autosaveStatus)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(.ultraThinMaterial)
                }
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

    // MARK: - Sections

    private var accountSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Account")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                labeledField(title: "Name") {
                    TextField("e.g. Everyday Checking", text: $name)
                        .textFieldStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Type")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    Picker("Type", selection: $type) {
                        ForEach(AccountType.allCases) { candidateType in
                            Text(candidateType.label).tag(candidateType)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                labeledField(title: "Institution (optional)") {
                    TextField("e.g. Chase", text: $institutionName)
                        .textFieldStyle(.plain)
                }

                labeledField(title: "Last Four Digits (optional)") {
                    TextField("1234", text: $lastFourDigitsText)
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                        .onChange(of: lastFourDigitsText) { _, newValue in
                            let sanitized = String(newValue.filter(\.isNumber).prefix(4))
                            if sanitized != newValue { lastFourDigitsText = sanitized }
                        }
                }
            }
        }
    }

    private var balanceSection: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                Text(type == .creditCard ? "Current Balance Owed" : "Current Balance")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                CurrencyAmountField(
                    amount: $balance,
                    style: .hero,
                    isInvalid: hasAttemptedSave && balance == nil,
                    accessibilityLabel: type == .creditCard ? "Current balance owed" : "Current balance"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var creditCardSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Credit Card Details")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                labeledField(title: "Credit Limit (optional)") {
                    CurrencyAmountField(
                        amount: $creditLimit,
                        style: .inline,
                        accessibilityLabel: "Credit limit"
                    )
                }

                labeledField(title: "Minimum Payment (optional)") {
                    CurrencyAmountField(
                        amount: $minimumPayment,
                        style: .inline,
                        accessibilityLabel: "Minimum payment"
                    )
                }

                Toggle("Set Payment Due Date", isOn: $hasPaymentDueDate.animation())
                    .tint(Theme.accent)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)

                if hasPaymentDueDate {
                    DatePicker("Payment Due Date", selection: $paymentDueDate, displayedComponents: .date)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private var monthlySpendingDefaultSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Toggle("Track as part of Monthly Spending?", isOn: $defaultCountsTowardMonthlySpending)
                    .tint(Theme.accent)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Text("When enabled, new expenses entered for this account will count toward your overall monthly spending. You can change this for each expense. This is only the default for future expenses — changing it does not retroactively modify prior transactions.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)

                Divider().overlay(Theme.cardStroke)

                Toggle("Show in Recent Activity", isOn: $showsInRecentActivity)
                    .tint(Theme.accent)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Text("When off, this account's transactions stay in its own register but won't appear in the Dashboard's Recent Activity list. Balances and spending totals are unaffected.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
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

    // MARK: - Save

    /// Explicit "Add Account" / "Done" tap: flushes any pending autosave immediately and only
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
    /// becomes valid) if valid. Editing the balance here is a plain field correction — never a
    /// `FinanceTransaction` — so repeated autosave commits can never double-apply anything.
    @discardableResult
    private func commitAutosaveNow() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil

        guard isValid, let balance else {
            if hasMeaningfulInput {
                hasAttemptedSave = true
                autosaveStatus = .invalidDraft
            }
            return false
        }

        let resolvedCreditLimit = type == .creditCard ? creditLimit : nil
        let resolvedMinimumPayment = type == .creditCard ? minimumPayment : nil
        let resolvedDueDate = (type == .creditCard && hasPaymentDueDate) ? paymentDueDate : nil
        let resolvedLastFour = lastFourDigitsText.isEmpty ? nil : lastFourDigitsText
        let resolvedInstitution = institutionName.isEmpty ? nil : institutionName

        if let existing = activeRecord {
            existing.name = name
            existing.type = type
            existing.currentBalance = balance
            existing.institutionName = resolvedInstitution
            existing.lastFourDigits = resolvedLastFour
            existing.creditLimit = resolvedCreditLimit
            existing.minimumPayment = resolvedMinimumPayment
            existing.paymentDueDate = resolvedDueDate
            existing.defaultCountsTowardMonthlySpending = defaultCountsTowardMonthlySpending
            existing.showsInRecentActivity = showsInRecentActivity
            existing.updatedAt = .now
        } else {
            let account = Account(
                name: name,
                type: type,
                currentBalance: balance,
                institutionName: resolvedInstitution,
                lastFourDigits: resolvedLastFour,
                creditLimit: resolvedCreditLimit,
                paymentDueDate: resolvedDueDate,
                minimumPayment: resolvedMinimumPayment,
                defaultCountsTowardMonthlySpending: defaultCountsTowardMonthlySpending,
                showsInRecentActivity: showsInRecentActivity
            )
            modelContext.insert(account)
            createdAccount = account
        }
        autosaveStatus = .saved
        return true
    }
}

#Preview("Add") {
    AddAccountView()
        .modelContainer(SampleData.previewContainer)
}

#Preview("Edit") {
    AddAccountView(account: Account(name: "Amex Gold", type: .creditCard, currentBalance: 812.40, institutionName: "American Express", lastFourDigits: "4821", creditLimit: 8000, minimumPayment: 35))
        .modelContainer(SampleData.previewContainer)
}
