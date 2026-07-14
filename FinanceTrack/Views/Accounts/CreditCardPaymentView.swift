import SwiftUI
import SwiftData

/// Dedicated "pay my credit card" flow, opened from a specific card's `CreditCardDetailView`.
/// The destination card is fixed to whichever card you opened this from (shown, not editable);
/// only the paying account is chosen here, restricted to checking/savings/cash.
struct CreditCardPaymentView: View {
    let creditCardAccount: Account
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode

    @Query(sort: \Account.createdAt) private var allAccounts: [Account]

    @State private var amount: Decimal?
    @State private var note: String = ""
    @State private var date: Date = .now
    @State private var sourceAccount: Account?
    @State private var hasAttemptedSave = false
    @State private var isPresentingDiscardConfirmation = false

    private var sourceOptions: [Account] {
        allAccounts.filter { [.checking, .savings, .cash].contains($0.type) && !$0.isArchived }
    }

    private var validationMessages: [String] {
        var messages: [String] = []
        if amount == nil {
            messages.append("Payment amount is required.")
        } else if (amount ?? 0) <= 0 {
            messages.append("Payment amount must be greater than 0.")
        }
        if sourceOptions.isEmpty {
            messages.append("Add a checking, savings, or cash account to pay from.")
        } else if sourceAccount == nil {
            messages.append("Payment source account is required.")
        } else if sourceAccount?.id == creditCardAccount.id {
            messages.append("Payment source account cannot be the same as the credit card account.")
        }
        return messages
    }

    private var isValid: Bool { validationMessages.isEmpty }

    /// This screen intentionally does not autosave — it creates a `FinanceTransaction` and moves
    /// money between two account balances, and autosaving that on every keystroke risks applying
    /// the same payment more than once. Instead, unsaved edits are protected with a
    /// confirm-on-dismiss prompt rather than silently discarded.
    private var hasMeaningfulInput: Bool {
        amount != nil || !note.trimmingCharacters(in: .whitespaces).isEmpty || sourceAccount != nil
    }
    private var shouldConfirmDiscard: Bool { hasMeaningfulInput }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    amountSection
                        .padding(.horizontal, Theme.Spacing.lg)

                    destinationCard
                        .padding(.horizontal, Theme.Spacing.lg)

                    if !sourceOptions.isEmpty {
                        AccountPickerCard(
                            accounts: sourceOptions,
                            selectedAccount: $sourceAccount,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                        .padding(.horizontal, Theme.Spacing.lg)
                    }

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
            .navigationTitle("Add Payment")
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
                PremiumActionButton(title: "Save Payment", systemIconName: "checkmark") {
                    attemptSave()
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
        }
        .preferredColorScheme(.dark)
    }

    private var amountSection: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                Text("Payment Amount")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                CurrencyAmountField(
                    amount: $amount,
                    style: .hero,
                    isInvalid: hasAttemptedSave && (amount ?? 0) <= 0,
                    accessibilityLabel: "Payment amount"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var destinationCard: some View {
        CardBackground {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: creditCardAccount.type.systemIconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: creditCardAccount.colorHex) ?? Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((Color(hex: creditCardAccount.colorHex) ?? Theme.accent).opacity(0.16)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Paying")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    Text(creditCardAccount.name)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                }

                Spacer()

                PrivacyAmountView(
                    amount: creditCardAccount.currentBalance,
                    isPrivacyModeEnabled: privacyMode.isEnabled,
                    font: Theme.captionFont,
                    color: Theme.textSecondary
                )
            }
        }
    }

    private var detailsSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Details")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.textPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note (optional)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    TextField("e.g. Monthly payment", text: $note)
                        .padding(Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.cardSurface)
                        )
                        .foregroundStyle(Theme.textPrimary)
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

    private func attemptSave() {
        hasAttemptedSave = true
        guard isValid, let amount, let sourceAccount else { return }

        let transaction = FinanceTransaction(
            amount: amount,
            date: date,
            type: .creditCardPayment,
            source: .manual,
            note: note.isEmpty ? "Payment to \(creditCardAccount.name)" : note,
            countsTowardWeeklyBudget: false,
            isExcludedFromReports: true,
            account: sourceAccount,
            transferDestinationAccount: creditCardAccount
        )
        modelContext.insert(transaction)
        AccountBalanceManager.applyCreditCardPayment(amount: amount, from: sourceAccount, to: creditCardAccount)

        dismiss()
    }
}

#Preview {
    CreditCardPaymentView(creditCardAccount: Account(name: "Amex Gold", type: .creditCard, currentBalance: 812.40, creditLimit: 8000, colorHex: "#C7A15A"))
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}
