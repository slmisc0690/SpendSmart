import SwiftUI
import SwiftData

struct AccountListView: View {
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    @Environment(PrivacyModeManager.self) private var privacyMode

    @State private var isPresentingAdd = false
    @State private var accountPendingEdit: Account?
    @State private var accountPendingAdjustment: Account?
    @State private var selectedCreditCard: Account?
    @State private var selectedManualAccount: Account?
    @State private var accountPendingArchive: Account?
    @State private var isPresentingConnectedAccounts = false

    private var activeAccounts: [Account] {
        allAccounts.filter { !$0.isArchived }
    }

    private var creditCardAccounts: [Account] {
        activeAccounts.filter { $0.type == .creditCard }
    }

    private var totalCash: Decimal {
        AccountBalanceManager.totalBalance(of: activeAccounts, types: [.checking, .savings, .cash])
    }

    private var totalCreditCardBalance: Decimal {
        AccountBalanceManager.totalBalance(of: activeAccounts, types: [.creditCard])
    }

    private var totalAvailableCredit: Decimal {
        creditCardAccounts.reduce(Decimal(0)) {
            $0 + (CreditUtilizationCalculator.availableCredit(balance: $1.currentBalance, limit: $1.creditLimit) ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    headerSubtitle

                    if activeAccounts.isEmpty {
                        manualAccountsEmptyState
                            .padding(.horizontal, Theme.Spacing.lg)
                    } else {
                        summarySection
                        accountsSection
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Manual Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $isPresentingAdd) {
                AddAccountView()
            }
            .sheet(item: $accountPendingEdit) { account in
                AddAccountView(account: account)
            }
            .sheet(item: $accountPendingAdjustment) { account in
                BalanceAdjustmentView(account: account)
            }
            .sheet(item: $selectedCreditCard) { account in
                CreditCardDetailView(account: account)
            }
            .sheet(item: $selectedManualAccount) { account in
                ManualAccountDetailView(account: account)
            }
            .sheet(isPresented: $isPresentingConnectedAccounts) {
                ConnectedAccountsView()
            }
            .confirmationDialog(
                "Archive \(accountPendingArchive?.name ?? "Account")?",
                isPresented: Binding(
                    get: { accountPendingArchive != nil },
                    set: { isPresented in if !isPresented { accountPendingArchive = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Archive", role: .destructive) {
                    accountPendingArchive?.isArchived = true
                    accountPendingArchive?.updatedAt = .now
                    accountPendingArchive = nil
                }
                Button("Cancel", role: .cancel) {
                    accountPendingArchive = nil
                }
            } message: {
                Text("This account's history is kept, but it will no longer appear in your active accounts or totals.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSubtitle: some View {
        Text("Track cash, unsupported institutions, loans, assets, or accounts you do not want to connect through Plaid.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Empty state

    /// Composed locally rather than extending the shared `EmptyStateCard` — this screen is the
    /// only one that needs a title line above the message AND a second, lower-emphasis action,
    /// neither of which the shared component supports, and every other `EmptyStateCard` call site
    /// in the app is fine with its current single-title, single-action shape.
    private var manualAccountsEmptyState: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.accentGradient)

                Text("No Manual Accounts")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                Text("Add an account you want to track manually. Connected banks and credit cards are managed in Connected Accounts.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                PremiumActionButton(title: "Add Manual Tracked Account") {
                    isPresentingAdd = true
                }

                Button {
                    isPresentingConnectedAccounts = true
                } label: {
                    Text("Connect a Financial Institution")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Summary")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.sm), GridItem(.flexible())], spacing: Theme.Spacing.sm) {
                AccountSummaryCard(
                    title: "Cash Available",
                    systemIconName: "banknote.fill",
                    amount: totalCash,
                    subtitle: "Checking, savings & cash",
                    accentColor: Theme.statusGood,
                    isPrivacyModeEnabled: privacyMode.isEnabled
                )
                AccountSummaryCard(
                    title: "Credit Card Balance",
                    systemIconName: "creditcard.fill",
                    amount: totalCreditCardBalance,
                    subtitle: creditCardSubtitle,
                    accentColor: Theme.statusOver,
                    isPrivacyModeEnabled: privacyMode.isEnabled
                )
                AccountSummaryCard(
                    title: "Available Credit",
                    systemIconName: "checkmark.seal.fill",
                    amount: creditCardAccounts.isEmpty ? nil : totalAvailableCredit,
                    plainValue: creditCardAccounts.isEmpty ? "\u{2014}" : nil,
                    subtitle: creditCardAccounts.isEmpty ? "Add a credit card" : "Across your cards",
                    accentColor: Theme.accent,
                    isPrivacyModeEnabled: privacyMode.isEnabled
                )
                AccountSummaryCard(
                    title: "Active Accounts",
                    systemIconName: "person.crop.circle.fill",
                    plainValue: "\(activeAccounts.count)",
                    subtitle: activeAccounts.count == 1 ? "1 account" : "\(activeAccounts.count) accounts",
                    accentColor: Theme.accentSecondary
                )
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var creditCardSubtitle: String {
        switch creditCardAccounts.count {
        case 0: return "No credit cards yet"
        case 1: return "1 card"
        default: return "\(creditCardAccounts.count) cards"
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Accounts")

            VStack(spacing: Theme.Spacing.md) {
                ForEach(activeAccounts) { account in
                    AccountCard(
                        account: account,
                        isPrivacyModeEnabled: privacyMode.isEnabled,
                        onSelect: { handleSelect(account) },
                        onEdit: { accountPendingEdit = account },
                        onAdjustBalance: { accountPendingAdjustment = account },
                        onArchive: { accountPendingArchive = account }
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private func handleSelect(_ account: Account) {
        if account.type == .creditCard {
            selectedCreditCard = account
        } else {
            selectedManualAccount = account
        }
    }
}

#Preview("Populated") {
    AccountListView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}

#Preview("Empty") {
    AccountListView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
}
