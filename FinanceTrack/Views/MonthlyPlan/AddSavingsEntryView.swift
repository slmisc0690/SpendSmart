import SwiftUI
import SwiftData

/// Sheet for recording a single manual "Saved This Month" entry. Amount is editable; date is
/// captured once from `.now` at presentation and shown read-only — matching this feature's own
/// locked product decision that a savings entry is never edited in place (correcting a mistake is
/// delete + re-add, via `SavingsEntryRow`'s delete action back in `MonthlyPlanView`). No autosave:
/// a single explicit Save action, matching `AddExpenseView`'s explicit-save pattern rather than
/// `AddEditIncomeSourceView`'s debounced autosave — there's no multi-field draft worth silently
/// persisting here.
struct AddSavingsEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Decimal?
    @State private var hasAttemptedSave = false
    private let entryDate = Date.now

    private var isValid: Bool {
        guard let amount else { return false }
        return amount > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Savings Amount")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: $amount,
                                style: .hero,
                                allowsNegative: false,
                                allowsZero: false,
                                isInvalid: hasAttemptedSave && !isValid,
                                accessibilityLabel: "Savings amount"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Date")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            Text(entryDate, format: .dateTime.month(.defaultDigits).day().year(.twoDigits))
                                .font(Theme.headlineFont)
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    if hasAttemptedSave, !isValid {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.statusOver)
                            Text("Savings amount must be greater than $0.")
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
            .navigationTitle("Add Savings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PremiumActionButton(title: "Save", systemIconName: "checkmark") {
                    save()
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xs)
                .background(.ultraThinMaterial)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        hasAttemptedSave = true
        guard isValid, let amount else { return }
        let entry = SavingsEntry(amount: amount, date: entryDate)
        modelContext.insert(entry)
        try? modelContext.save()
        // CLIENT UI PHASE — best-effort aggregate reconciliation (see
        // `SavingsSummarySyncService`'s own header). A fresh fetch, not the (nonexistent in this
        // view) `@Query`, so the just-inserted entry is always included regardless of SwiftData's
        // own `@Query` update timing.
        let allEntries = (try? modelContext.fetch(FetchDescriptor<SavingsEntry>())) ?? []
        Task { await SavingsSummarySyncService.sync(entries: allEntries) }
        dismiss()
    }
}

#Preview {
    AddSavingsEntryView()
        .modelContainer(SampleData.previewContainer)
}
