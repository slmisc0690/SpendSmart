import SwiftUI
import SwiftData

/// Full detail/register screen for a single NON-credit-card Manual Account (checking, savings,
/// cash, other) — the checking/savings/cash/other counterpart to `CreditCardDetailView`. Shows
/// the account's balance, its "Track as part of Monthly Spending?" default, and every manually
/// entered transaction against it, with safe per-transaction deletion.
struct ManualAccountDetailView: View {
    @Bindable var account: Account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PrivacyModeManager.self) private var privacyMode

    @Query(sort: \FinanceTransaction.date, order: .reverse) private var allTransactions: [FinanceTransaction]

    @State private var isPresentingAddExpense = false
    @State private var isPresentingEdit = false
    @State private var transactionPendingDeletion: FinanceTransaction?
    @State private var isPresentingDeletionError = false
    @State private var isPresentingAccountDeletionConfirmation = false
    @State private var accountDeletionBlockedMessage: String?

    private var accountTransactions: [FinanceTransaction] {
        allTransactions.filter { $0.account?.id == account.id || $0.transferDestinationAccount?.id == account.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    summaryCard
                        .padding(.horizontal, Theme.Spacing.lg)

                    actionsRow
                        .padding(.horizontal, Theme.Spacing.lg)

                    registerSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    accountOptionsMenu
                }
            }
            .sheet(isPresented: $isPresentingAddExpense) {
                AddExpenseView(preselectedAccount: account)
            }
            .sheet(isPresented: $isPresentingEdit) {
                AddAccountView(account: account)
            }
            .confirmationDialog(
                transactionPendingDeletion.map { ManualTransactionDeletionService.confirmationCopy(for: $0).title } ?? "Delete?",
                isPresented: Binding(
                    get: { transactionPendingDeletion != nil },
                    set: { isPresented in if !isPresented { transactionPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let transaction = transactionPendingDeletion {
                    Button(ManualTransactionDeletionService.confirmationCopy(for: transaction).destructiveActionTitle, role: .destructive) {
                        let succeeded = ManualTransactionDeletionService.delete(transaction, context: modelContext)
                        transactionPendingDeletion = nil
                        if !succeeded { isPresentingDeletionError = true }
                    }
                }
                Button("Cancel", role: .cancel) { transactionPendingDeletion = nil }
            } message: {
                if let transaction = transactionPendingDeletion {
                    Text(ManualTransactionDeletionService.confirmationCopy(for: transaction).message)
                }
            }
            .alert("Couldn't Delete", isPresented: $isPresentingDeletionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This transaction couldn't be safely deleted, so nothing was changed.")
            }
            .confirmationDialog(
                "Delete Manual Account?",
                isPresented: $isPresentingAccountDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    deleteAccount()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete this manual account and its manually entered account entries. This cannot be undone.")
            }
            .alert(
                "Can't Delete Account",
                isPresented: Binding(
                    get: { accountDeletionBlockedMessage != nil },
                    set: { isPresented in if !isPresented { accountDeletionBlockedMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accountDeletionBlockedMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func deleteAccount() {
        let eligibility = ManualAccountDeletionService.eligibility(for: account, transactions: allTransactions)
        guard eligibility == .eligible else {
            accountDeletionBlockedMessage = ManualAccountDeletionService.blockedMessage(for: eligibility)
            return
        }
        let succeeded = ManualAccountDeletionService.delete(account, transactions: allTransactions, context: modelContext)
        if succeeded {
            dismiss()
        } else {
            accountDeletionBlockedMessage = "This account couldn't be safely deleted, so nothing was changed."
        }
    }

    // MARK: - Sections

    private var summaryCard: some View {
        CardBackground(tint: Color(hex: account.colorHex) ?? Theme.accent) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.institutionName ?? account.type.label)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                        if let lastFour = account.lastFourDigits, !lastFour.isEmpty {
                            Text("\u{2022}\u{2022}\u{2022}\u{2022} \(lastFour)")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer()
                    manualBadge
                }

                PrivacyAmountView(
                    amount: account.currentBalance,
                    isPrivacyModeEnabled: privacyMode.isEnabled,
                    font: Theme.amountFont(),
                    color: Theme.textPrimary
                )

                HStack(spacing: 6) {
                    Image(systemName: account.defaultCountsTowardMonthlySpending ? "checkmark.circle.fill" : "circle.slash")
                        .font(.system(size: 12, weight: .semibold))
                    Text(account.defaultCountsTowardMonthlySpending
                        ? "New expenses count toward Monthly Spending by default"
                        : "New expenses do NOT count toward Monthly Spending by default")
                        .font(Theme.captionFont)
                }
                .foregroundStyle(account.defaultCountsTowardMonthlySpending ? Theme.statusGood : Theme.textTertiary)
            }
        }
    }

    private var manualBadge: some View {
        Text("Manual")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(0.15)))
    }

    private var actionsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            PremiumActionButton(title: "Add Expense", systemIconName: "plus") {
                isPresentingAddExpense = true
            }
            PremiumActionButton(title: "Edit", systemIconName: "pencil") {
                isPresentingEdit = true
            }
        }
    }

    /// The consolidated, clearly-visible account-actions control — replaces relying on a tiny
    /// bare glyph anywhere in this screen with a properly sized (44×44), high-contrast, labeled
    /// tap target.
    private var accountOptionsMenu: some View {
        Menu {
            Button("Edit Account", systemImage: "pencil", action: { isPresentingEdit = true })
            Button("Add Expense", systemImage: "plus", action: { isPresentingAddExpense = true })
            Divider()
            Button("Delete Account", systemImage: "trash", role: .destructive) {
                isPresentingAccountDeletionConfirmation = true
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Account Options")
    }

    private var hasEligibleManualTransactions: Bool {
        accountTransactions.contains { ManualTransactionDeletionService.eligibility(for: $0) == .eligible }
    }

    private var registerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Register")

            if accountTransactions.isEmpty {
                Text("No transactions yet")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else {
                if hasEligibleManualTransactions {
                    Text("Press and hold a manual entry for options, including Delete.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(accountTransactions.enumerated()), id: \.element.id) { index, transaction in
                            HStack(spacing: 0) {
                                TransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled, showsTypeBadge: true)
                                    .contextMenu {
                                        if ManualTransactionDeletionService.eligibility(for: transaction) == .eligible {
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                transactionPendingDeletion = transaction
                                            }
                                        }
                                    }
                                if ManualTransactionDeletionService.eligibility(for: transaction) == .eligible {
                                    transactionOptionsMenu(for: transaction)
                                }
                            }
                            if index < accountTransactions.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    private func transactionOptionsMenu(for transaction: FinanceTransaction) -> some View {
        Menu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                transactionPendingDeletion = transaction
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Transaction Options")
    }
}

#Preview {
    ManualAccountDetailView(account: Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55, defaultCountsTowardMonthlySpending: true))
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}
