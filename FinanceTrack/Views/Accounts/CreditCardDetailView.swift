import SwiftUI
import SwiftData

/// Full detail screen for a single credit card: balance, limit, available credit, utilization,
/// payment due date, minimum payment, recent activity, and quick actions.
struct CreditCardDetailView: View {
    @Bindable var account: Account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PrivacyModeManager.self) private var privacyMode

    @Query(sort: \FinanceTransaction.date, order: .reverse) private var allTransactions: [FinanceTransaction]

    @State private var isPresentingPayment = false
    @State private var isPresentingAdjustBalance = false
    @State private var isPresentingEdit = false
    @State private var transactionPendingDeletion: FinanceTransaction?
    @State private var isPresentingDeletionError = false

    private var recentCardTransactions: [FinanceTransaction] {
        Array(
            allTransactions
                .filter { $0.account?.id == account.id || $0.transferDestinationAccount?.id == account.id }
                .prefix(5)
        )
    }

    private var availableCredit: Decimal? {
        CreditUtilizationCalculator.availableCredit(balance: account.currentBalance, limit: account.creditLimit)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    summaryCard
                        .padding(.horizontal, Theme.Spacing.lg)

                    actionsRow
                        .padding(.horizontal, Theme.Spacing.lg)

                    recentActivitySection
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
            }
            .sheet(isPresented: $isPresentingPayment) {
                CreditCardPaymentView(creditCardAccount: account)
            }
            .sheet(isPresented: $isPresentingAdjustBalance) {
                BalanceAdjustmentView(account: account)
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
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var summaryCard: some View {
        CardBackground(tint: Color(hex: account.colorHex) ?? Theme.accent) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top, spacing: 4) {
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
                }

                PrivacyAmountView(
                    amount: account.currentBalance,
                    isPrivacyModeEnabled: privacyMode.isEnabled,
                    font: Theme.amountFont(),
                    color: Theme.textPrimary
                )

                CreditUtilizationView(balance: account.currentBalance, limit: account.creditLimit)

                HStack {
                    if let limit = account.creditLimit {
                        labeledAmount(title: "Credit Limit", amount: limit)
                    }
                    Spacer()
                    if let availableCredit {
                        labeledAmount(title: "Available Credit", amount: availableCredit)
                    }
                }

                if account.paymentDueDate != nil || account.minimumPayment != nil {
                    HStack {
                        if let dueDate = account.paymentDueDate {
                            labeledValue(title: "Payment Due", value: dueDate.formatted(date: .abbreviated, time: .omitted))
                        }
                        Spacer()
                        if let minimumPayment = account.minimumPayment {
                            labeledAmount(title: "Minimum Payment", amount: minimumPayment)
                        }
                    }
                }
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            PremiumActionButton(title: "Payment", systemIconName: "plus") {
                isPresentingPayment = true
            }
            PremiumActionButton(title: "Adjust", systemIconName: "slider.horizontal.3") {
                isPresentingAdjustBalance = true
            }
            PremiumActionButton(title: "Edit", systemIconName: "pencil") {
                isPresentingEdit = true
            }
        }
    }

    private var hasEligibleManualTransactions: Bool {
        recentCardTransactions.contains { ManualTransactionDeletionService.eligibility(for: $0) == .eligible }
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Recent Activity")

            if recentCardTransactions.isEmpty {
                Text("No transactions yet")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else {
                if hasEligibleManualTransactions {
                    Text("Use the options button or press and hold a manual entry to delete it.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(recentCardTransactions.enumerated()), id: \.element.id) { index, transaction in
                            HStack(spacing: 0) {
                                TransactionRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled)
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
                            if index < recentCardTransactions.count - 1 {
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

    @ViewBuilder
    private func labeledValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func labeledAmount(title: String, amount: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            PrivacyAmountView(
                amount: amount,
                isPrivacyModeEnabled: privacyMode.isEnabled,
                font: Theme.bodyFont,
                color: Theme.textSecondary
            )
        }
    }
}

#Preview {
    CreditCardDetailView(account: Account(name: "Amex Gold", type: .creditCard, currentBalance: 812.40, institutionName: "American Express", lastFourDigits: "4821", creditLimit: 8000, minimumPayment: 35, colorHex: "#C7A15A"))
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}
