import SwiftUI
import SwiftData

struct AccountListView: View {
    static let infoExplanation = """
        These are the accounts you track by hand — a checking or savings account, cash, or \
        anything else you're not connecting through your bank. Each one keeps its own balance and \
        its own running register of transactions.

        Tap an account to see its full history, add an entry, or pay a bill from it. Tap the + \
        button to add a new account.

        If a household member has shared an account with you, it shows up in its own section \
        below your own accounts, clearly labeled "Shared with You" so it's never confused with \
        something you own.

        Example: you keep a Manual Account for your checking account, entering deposits and bill \
        payments by hand since your bank isn't connected. Its balance updates every time you add \
        or edit an entry, giving you an accurate running total without needing a bank connection.
        """

    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    @Environment(PrivacyModeManager.self) private var privacyMode
    /// PHASE 10 — same already-refreshed instance as everywhere else; read-only here, purely to
    /// surface `response?.primarySharedManualAccounts` for an active Secondary.
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel

    @State private var isPresentingAdd = false
    @State private var isPresentingAskSpendSmart = false
    @State private var accountPendingEdit: Account?
    @State private var accountPendingAdjustment: Account?
    @State private var selectedCreditCard: Account?
    @State private var selectedManualAccount: Account?
    @State private var accountPendingArchive: Account?
    @State private var isPresentingConnectedAccounts = false
    /// PHASE 10 — drives the read-only shared Manual Account detail sheet.
    @State private var selectedSharedManualAccount: SharedManualAccountDTO?
    /// POST-PHASE-10 CORRECTION — loads each shared account's balance/institution/last-four (the
    /// detail DTO, not the minimal list DTO) so the normal-card row below can show real figures
    /// instead of a name-only placeholder. See that view model's own header.
    @State private var sharedManualAccountsSummary = SharedManualAccountsSummaryViewModel()

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
                    sharedManualAccountsSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Manual Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    InfoButton(title: "About Manual Accounts", explanation: Self.infoExplanation)
                }
                // SPENDAI LAUNCHER VISUAL CORRECTION — "+" and the SpendAI launcher are one
                // `ToolbarItemGroup` (Apple's documented way to combine related toolbar controls
                // into a single shared Liquid Glass pill — see SwiftUI's own Landmarks Liquid Glass
                // sample) rather than two separately-placed `ToolbarItem`s, which were letting the
                // system's automatic shared-background sizing clip content off the pill's trailing
                // edge on a physical device. Order was swapped per Scott's explicit instruction:
                // SpendAI now sits FIRST/LEFT, "+" SECOND/RIGHT, inside the same pill — a
                // `ToolbarItemGroup`'s items lay out left-to-right in declaration order even though
                // the group as a whole is trailing-aligned. Leading padding on SpendAI and trailing
                // padding on "+" guard both ends of the pill; each button keeps its own separate tap
                // target and destination — this only changes layout, never merges their actions.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // SPENDAI UI PLACEMENT CORRECTION — app-wide access entry point for the primary
                    // Manual Accounts area. Deliberately screen-level (`.manualAccounts`), not tied
                    // to any single account — see this app's own Phase 2 decision to leave
                    // per-account selected-account context as a future enhancement rather than
                    // touching the separate account-detail screen. Artwork ABOVE the SpendAI
                    // wordmark via the one shared `SpendAILauncherControl` (never a per-screen
                    // duplicate). Explicit leading padding guards against the pill clipping its
                    // leading edge now that this control is first.
                    SpendAILauncherControl(glyphSize: 28) {
                        isPresentingAskSpendSmart = true
                    }
                    .padding(.leading, Theme.Spacing.xs)

                    Button {
                        isPresentingAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .padding(.trailing, Theme.Spacing.xs)
                }
            }
            .sheet(isPresented: $isPresentingAdd) {
                AddAccountView()
            }
            .sheet(isPresented: $isPresentingAskSpendSmart) {
                AskSpendSmartView(screenContext: .manualAccounts)
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
            .sheet(item: $selectedSharedManualAccount) { account in
                // PHASE 10 — reuses the exact Phase 9 read-only detail screen.
                SharedManualAccountDetailView(account: account)
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
        .task(id: sharedManualAccounts.map(\.id)) {
            await sharedManualAccountsSummary.load(accounts: sharedManualAccounts)
        }
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

    // MARK: - Phase 10: Primary-shared Manual Accounts (normal-area integration)

    /// Every Primary-owned Manual Account currently, effectively shared with this Secondary —
    /// only ever what migration 0016's `get_secondary_shared_data` already scoped server-side;
    /// this view performs no filtering of its own, and never hardcodes an account name/id.
    private var sharedManualAccounts: [SharedManualAccountDTO] {
        accountRelatedOptionsViewModel.response?.primarySharedManualAccounts ?? []
    }

    /// Deliberately separate from `allAccounts`/`activeAccounts` (both SwiftData `@Query`-backed)
    /// — a shared account is never appended to that array, never given an `Account` identity,
    /// never eligible for edit/archive/add-transaction. Shown even when `activeAccounts` is empty,
    /// so a Secondary with no Manual Accounts of their own still sees what the Primary shares.
    ///
    /// POST-PHASE-10 CORRECTION — renders with the same icon/name/subtitle/balance composition as
    /// `AccountCard` (no visible "Shared" badge), sourced from `sharedManualAccountsSummary`'s
    /// detail fetch. Never constructs an `Account` — `SharedManualAccountCardRow` below is a
    /// lightweight look-alike built entirely from primitives/DTOs, with no edit/archive menu
    /// (those require ownership) and tapping opens the existing read-only detail sheet.
    @ViewBuilder
    private var sharedManualAccountsSection: some View {
        if !sharedManualAccounts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // SHARED-SECTION LABELING CORRECTION — this section shows accounts belonging to
                // another household member, shared TO the current user; reusing "Manual Accounts"
                // (the exact same title as this screen's own accounts, right above) made it
                // impossible to tell the two sections apart at a glance. "Shared with You" is
                // exclusive to this section — the user's own accounts section keeps its unchanged
                // "Manual Accounts" title elsewhere in this file.
                DashboardSectionHeader(title: "Shared with You")
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(sharedManualAccounts) { account in
                        SharedManualAccountCardRow(
                            account: account,
                            detail: sharedManualAccountsSummary.detailsByAccountId[account.id],
                            isPrivacyModeEnabled: privacyMode.isEnabled,
                            onSelect: { selectedSharedManualAccount = account }
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }
}

/// POST-PHASE-10 CORRECTION — a shared Manual Account rendered with the same visual composition
/// as the owned `AccountCard` (icon circle, name, type/institution/last-four subtitle, prominent
/// balance) but built entirely from `SharedManualAccountDTO`/`SharedManualAccountDetailDTO` —
/// never an `Account` instance. No Edit/Adjust Balance/Archive menu (those require ownership); the
/// whole card is a single tap target that opens the read-only shared detail screen, same as every
/// other Phase 9/10 shared-data entry point. `detail` is `nil` until
/// `SharedManualAccountsSummaryViewModel.load` resolves (or if the account has since been
/// unshared/deleted) — the card still renders with just the name in that case, matching
/// `AccountCard`'s own "never fabricate a balance" principle.
private struct SharedManualAccountCardRow: View {
    let account: SharedManualAccountDTO
    let detail: SharedManualAccountDetailDTO?
    var isPrivacyModeEnabled: Bool = false
    var onSelect: () -> Void

    private var resolvedType: AccountType {
        AccountType(rawValue: detail?.accountType ?? account.accountType) ?? .other
    }

    private var subtitleParts: [String] {
        var parts = [resolvedType.label]
        if let lastFour = detail?.lastFourDigits, !lastFour.isEmpty {
            parts.append("\u{2022}\u{2022}\u{2022}\u{2022} \(lastFour)")
        }
        if let institution = detail?.institutionName, !institution.isEmpty {
            parts.append(institution)
        }
        return parts
    }

    var body: some View {
        Button(action: onSelect) {
            CardBackground {
                HStack(alignment: .top) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: resolvedType.systemIconName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.accent.opacity(0.18)))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .font(Theme.headlineFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text(subtitleParts.joined(separator: " \u{00B7} "))
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if let balance = detail?.currentBalance {
                        PrivacyAmountView(
                            amount: balance,
                            isPrivacyModeEnabled: isPrivacyModeEnabled,
                            font: Theme.amountFont(20),
                            color: Theme.textPrimary
                        )
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview("Populated") {
    AccountListView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(AccountRelatedOptionsViewModel())
}

#Preview("Empty") {
    AccountListView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
        .environment(AccountRelatedOptionsViewModel())
}
