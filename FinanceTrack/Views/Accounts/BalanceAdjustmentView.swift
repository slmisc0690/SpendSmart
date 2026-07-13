import SwiftUI
import SwiftData

/// Manual balance correction flow. Creates an audit-trail `FinanceTransaction` (type
/// `.balanceAdjustment`, excluded from all reports) recording the change, then applies the new
/// balance via `AccountBalanceManager`.
struct BalanceAdjustmentView: View {
    @Bindable var account: Account
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var newBalance: Decimal?
    @State private var note: String = ""
    @State private var date: Date = .now
    @State private var hasAttemptedSave = false
    @State private var isPresentingDiscardConfirmation = false

    init(account: Account) {
        self.account = account
        _newBalance = State(initialValue: account.currentBalance)
    }

    private var isValid: Bool { newBalance != nil }

    /// This screen intentionally does not autosave — it creates an audit-trail `FinanceTransaction`
    /// and mutates the account balance, and autosaving that on every keystroke risks applying the
    /// same balance change more than once. Instead, unsaved edits are protected with a
    /// confirm-on-dismiss prompt rather than silently discarded.
    private var hasMeaningfulInput: Bool {
        newBalance != account.currentBalance || !note.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var shouldConfirmDiscard: Bool { hasMeaningfulInput }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("New Balance for \(account.name)")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: $newBalance,
                                style: .hero,
                                isInvalid: hasAttemptedSave && newBalance == nil,
                                accessibilityLabel: "New balance for \(account.name)"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

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
                                TextField("e.g. Corrected after reconciling", text: $note)
                                    .padding(Theme.Spacing.sm)
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                            .fill(Theme.cardSurface)
                                    )
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    if hasAttemptedSave, !isValid {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.statusOver)
                            Text("Enter a valid balance.")
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
            .navigationTitle("Adjust Balance")
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
                PremiumActionButton(title: "Save Adjustment", systemIconName: "checkmark") {
                    save()
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

    private func save() {
        hasAttemptedSave = true
        guard isValid, let newBalance else { return }

        let delta = newBalance - account.currentBalance
        let transaction = FinanceTransaction(
            amount: delta,
            date: date,
            type: .balanceAdjustment,
            source: .manual,
            note: note.isEmpty ? "Balance adjustment" : note,
            countsTowardWeeklyBudget: false,
            isExcludedFromReports: true,
            account: account
        )
        modelContext.insert(transaction)
        AccountBalanceManager.applyBalanceAdjustment(account: account, newBalance: newBalance)

        dismiss()
    }
}

#Preview {
    BalanceAdjustmentView(account: Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55))
        .modelContainer(SampleData.previewContainer)
}
