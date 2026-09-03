import SwiftUI
import SwiftData

/// SETTINGS ORGANIZATION PHASE — the canonical "Account" destination (`Settings ▸ Account`, and
/// the `.account` Dashboard Favorite). Groups the financial-configuration screens that used to be
/// inline sections directly on `SettingsView`'s main scroll: Account Related Options, Budget
/// Settings, Monthly Plan, Security & Privacy, Connected Accounts, and (recovery pass) Categories
/// — previously a Tools subsection on `SettingsView`. This is a pure MOVE — every `@State`
/// snapshot, binding, and sync function below is unchanged from its prior home in `SettingsView`,
/// including the proven sign-out-safety pattern (see `weeklyLimit`/`monthlyGoal`'s own header):
/// `body` never reads a live `BudgetSettings`/`MonthlyPlanSettings` property directly, only these
/// `@State` primitives, refreshed in `.onAppear` and after each edit sheet closes.
struct AccountSettingsView: View {
    @Query private var settingsList: [BudgetSettings]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]
    @Query(sort: \Category.name) private var categories: [Category]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(BiometricAuthManager.self) private var biometricAuth
    @Environment(PlaidConnectionManager.self) private var plaidConnection
    @Environment(AuthenticationService.self) private var authService
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel

    @State private var weeklyLimit: Decimal?
    @State private var monthlyGoal: Decimal?
    @State private var includePendingTransactions = true
    @State private var requireFaceIDSetting = false
    @State private var hideBalancesByDefault = false
    @State private var faceIDToggleErrorMessage: String?
    @State private var isPresentingSecurityNotes = false
    @State private var isPresentingConnectedAccounts = false
    @State private var isPresentingMonthlyPlan = false
    @State private var isPresentingAccountRelatedOptions = false
    @State private var isPresentingWeeklySpendingEdit = false
    @State private var isPresentingSavingsGoalEdit = false
    @State private var isPresentingCategoryManagement = false

    private var settings: BudgetSettings {
        if let existing = settingsList.first {
            return existing
        }
        let created = BudgetSettings()
        modelContext.insert(created)
        return created
    }

    private var activeCategories: [Category] {
        categories.filter { !$0.isArchived }
    }

    /// Identical formula/call chain to `SettingsView`'s own prior copy — see that type's own
    /// header (before this move) for the full reasoning. Never a duplicated or alternate formula.
    private var currentMonthFlexibleSpendingAvailable: Decimal {
        let month = DateRangeHelper.currentMonthRange()
        let income = MonthlyPlanCalculator.estimatedMonthlyIncome(incomeSources, in: month)
        let fixedExpenses = MonthlyPlanCalculator.estimatedMonthlyFixedExpenses(recurringExpenses, in: month)
        let goal = monthlyPlanSettingsList.first?.monthlySavingsGoal ?? 0
        let buffer = monthlyPlanSettingsList.first?.bufferAmount ?? 0
        return MonthlyPlanCalculator.flexibleSpendingAvailable(income: income, fixedExpenses: fixedExpenses, savingsGoal: goal, bufferAmount: buffer)
    }

    private var currentEffectivePlannedWeeklySpending: Decimal {
        MonthlyPlanCalculator.effectivePlannedWeeklySpending(override: monthlyPlanSettingsList.first?.plannedWeeklySpendingOverride, flexibleSpendingAvailable: currentMonthFlexibleSpendingAvailable)
    }

    private var automaticPlannedWeeklySpending: Decimal {
        MonthlyPlanCalculator.automaticPlannedWeeklySpending(flexibleSpendingAvailable: currentMonthFlexibleSpendingAvailable)
    }

    private func syncBudgetSettingsFromMonthlyPlan() {
        let goal = monthlyPlanSettingsList.first?.monthlySavingsGoal ?? 0
        let expectedWeeklyLimit = currentEffectivePlannedWeeklySpending
        if settings.monthlyGoal != goal || settings.weeklySpendingLimit != expectedWeeklyLimit {
            settings.applyMonthlyPlanAutoCalculate(monthlyPlanSavingsGoal: goal, monthlySpendRemaining: expectedWeeklyLimit * 4)
        }
        weeklyLimit = settings.weeklySpendingLimit
        monthlyGoal = settings.monthlyGoal
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    accountRelatedOptionsSection
                    budgetSection
                    monthlyPlanSection
                    securitySection
                    connectedAccountsSection
                    categoriesSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.textSecondary)
                }
            }
            .onAppear {
                syncBudgetSettingsFromMonthlyPlan()
                includePendingTransactions = settings.includePendingTransactions
                requireFaceIDSetting = settings.requireFaceID
                hideBalancesByDefault = settings.hideBalancesByDefault
                biometricAuth.isFaceIDRequired = settings.requireFaceID
            }
            .sheet(isPresented: $isPresentingAccountRelatedOptions) {
                AccountRelatedOptionsView()
            }
            .sheet(isPresented: $isPresentingConnectedAccounts) {
                ConnectedAccountsView()
            }
            .sheet(isPresented: $isPresentingMonthlyPlan) {
                MonthlyPlanEntryView()
            }
            .sheet(isPresented: $isPresentingWeeklySpendingEdit) {
                PlannedWeeklySpendingEditView(settings: monthlyPlanSettingsList.first, automaticAmount: automaticPlannedWeeklySpending)
            }
            .sheet(isPresented: $isPresentingSavingsGoalEdit) {
                MonthlyPlanSettingsEditView(settings: monthlyPlanSettingsList.first)
            }
            .onChange(of: isPresentingWeeklySpendingEdit) { _, isPresented in
                if !isPresented { syncBudgetSettingsFromMonthlyPlan() }
            }
            .onChange(of: isPresentingSavingsGoalEdit) { _, isPresented in
                if !isPresented { syncBudgetSettingsFromMonthlyPlan() }
            }
            .sheet(isPresented: $isPresentingSecurityNotes) {
                SecurityNotesView()
            }
            .sheet(isPresented: $isPresentingCategoryManagement) {
                CategoryManagementView()
            }
            // Same defensive-in-depth sign-out safety this app already applies at every level that
            // owns a `.sheet` — see `SettingsView`'s own identical `.onChange(of: authService.
            // sessionState)` for the full proven-crash history this pattern guards against. This
            // screen now owns the sheets that used to be owned directly by `SettingsView`, so it
            // must close them itself rather than relying solely on the outer dismissal cascading.
            .onChange(of: authService.sessionState) { _, newValue in
                guard newValue == .signedOut else { return }
                isPresentingAccountRelatedOptions = false
                isPresentingConnectedAccounts = false
                isPresentingMonthlyPlan = false
                isPresentingWeeklySpendingEdit = false
                isPresentingSavingsGoalEdit = false
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Account Related Options

    private var accountRelatedOptionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Account Related Options",
                infoTitle: "About Account Related Options",
                infoExplanation: """
                    If you invite someone else to see your finances, you're the "Primary," and this \
                    row is called "Account Related Options" — from there you can invite someone, \
                    choose exactly which of your accounts and how much of your Monthly Plan they can \
                    see, and manage anyone already invited. If someone else invited YOU instead, \
                    you're the "Secondary," and this row is called "Share Connected Account" — it \
                    lets you optionally share your own accounts back with them.

                    Example: you invite your spouse to see your accounts. Once they accept, you \
                    choose exactly which accounts and Monthly Plan details they're allowed to see — \
                    nothing is shared automatically just because they accepted the invite.
                    """
            )

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    // Hidden entirely until the server-verified role has resolved (never inferred
                    // locally, see AccountRelatedOptionsViewModel's own doc comment for why). Once
                    // resolved: Primary/no-household see "Account Related Options"; an active
                    // Secondary sees only "Share Connected Account" — the same row leads to
                    // AccountRelatedOptionsView either way, which renders the correct role-scoped
                    // content itself.
                    if accountRelatedOptionsViewModel.visibility != .hidden {
                        Button {
                            isPresentingAccountRelatedOptions = true
                        } label: {
                            HStack {
                                Text(accountRelatedOptionsViewModel.visibility == .secondary ? "Share Connected Account" : "Account Related Options")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("Resolving your account role…")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            // LOCK NOW — same trigger/condition as before (`requireFaceIDSetting`,
            // `biometricAuth.lock()`), relocated here alongside Account Related Options, matching
            // its established placement from before this move.
            if requireFaceIDSetting {
                Button {
                    biometricAuth.lock()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Lock Now")
                            .font(Theme.bodyFont)
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Budget Settings

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Budget Settings",
                infoTitle: "About Budget Settings",
                infoExplanation: """
                    A read-only summary plus one real control.

                    WEEKLY SPENDING LIMIT / MONTHLY SAVINGS GOAL — these are always calculated from \
                    your Monthly Plan, so you can't type directly into the amount shown here — but \
                    tapping either row opens the real Monthly Plan editor for it (Planned Weekly \
                    Spending / Savings Goal), the same one reachable from Monthly Plan.

                    INCLUDE PENDING TRANSACTIONS — a "pending" transaction is one your bank has \
                    authorized but hasn't fully posted yet (common with debit/credit card purchases \
                    for a day or two). Turning this on counts pending purchases toward your Spent \
                    totals right away; turning it off waits until they post, which can make your \
                    spending look temporarily lower than it really is.

                    Example: you buy gas and it shows as "pending" for a day. With this ON, it \
                    counts toward Spent This Week immediately. With it OFF, it won't count until \
                    your bank finalizes it.
                    """
            )

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    labeledAmountField(title: "Weekly Spending Limit", amount: $weeklyLimit) {
                        isPresentingWeeklySpendingEdit = true
                    }
                    Divider().overlay(Theme.cardStroke)
                    labeledAmountField(title: "Monthly Savings Goal", amount: $monthlyGoal) {
                        isPresentingSavingsGoalEdit = true
                    }
                    derivedBudgetValuesHelperRow
                    Divider().overlay(Theme.cardStroke)

                    TransactionToggleRow(
                        title: "Include Pending Transactions",
                        subtitle: "Count pending transactions toward your totals",
                        isOn: Binding(
                            get: { includePendingTransactions },
                            set: { newValue in
                                includePendingTransactions = newValue
                                settings.includePendingTransactions = newValue
                                settings.updatedAt = .now
                            }
                        )
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var derivedBudgetValuesHelperRow: some View {
        Text("Automatically calculated from your Monthly Plan savings goal and projected savings.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
    }

    // MARK: - Monthly Plan

    private var monthlyPlanSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Monthly Plan",
                infoTitle: "About Monthly Plan",
                infoExplanation: """
                    WHAT MONTHLY PLAN IS FOR

                    Monthly Plan is where you tell the app your whole financial picture for the \
                    month: how much money comes in (income), what regular bills go out (rent, car \
                    payment, insurance, subscriptions, etc.), how much you want to save, and any \
                    extra cushion (buffer) you want to hold back. From those four numbers, the app \
                    works out one key figure: Flexible Spending Available — literally, money coming \
                    in, minus bills, minus your savings goal, minus your buffer. That's what's left \
                    over for you to actually spend day to day.

                    HOW IT AFFECTS YOUR SPENDING

                    Flexible Spending Available gets divided into a weekly amount — either \
                    automatically (divided evenly across 4 weeks) or a custom weekly amount you set \
                    yourself in this same Monthly Plan section. That weekly amount becomes your \
                    Weekly Spending Limit, which is what "Spent This Week" is measured against \
                    everywhere in the app (the Dashboard's "This Week" card, Weekly Budget, Quick \
                    Stats). It also drives "Monthly Remaining" and "Projected Savings" on the \
                    Dashboard's Monthly Outlook.

                    HOW IT AFFECTS YOUR SAVING

                    Because your Savings Goal is subtracted BEFORE working out what's left to spend, \
                    it's effectively protected — the app never counts your savings money as \
                    available to spend. "Projected Savings" on the Dashboard shows you, at a glance, \
                    whether you're on track to actually hit that goal based on your current plan.

                    IF A BILL COSTS MORE OR LESS THAN PLANNED

                    When you actually pay a bill (through Pay Bills or by tagging a register entry), \
                    the app compares what you paid to what you planned for it in Monthly Plan. If \
                    you paid less, that difference is added back to what's available to spend. If \
                    you paid more, it's subtracted. You can see this breakdown on the Monthly Plan \
                    screen under "Bill Payment Variance."

                    IF YOU DON'T USE MONTHLY PLAN AT ALL

                    You don't have to fill in Monthly Plan for the app to work. Your Spent This \
                    Week and Spent This Month totals are always based on your real transactions — \
                    Manual Account entries and any Connected Accounts you've turned on under Auto \
                    Calculate — whether or not Monthly Plan has anything in it. What changes is only \
                    the TARGET those totals are compared against: with nothing entered in Monthly \
                    Plan, Flexible Spending Available is $0, so Automatic weekly planning would also \
                    be $0 (making every dollar you spend look "over budget"). To avoid that, you can \
                    set a Custom Planned Weekly Spending amount right here in Monthly Plan — a plain \
                    dollar figure you choose yourself — and that becomes your Weekly Spending Limit \
                    without needing to fill in income or bills anywhere. Monthly Outlook figures \
                    like Projected Savings won't be meaningful without Monthly Plan filled in, but \
                    Spent This Week/Month and a Custom weekly limit work completely independently \
                    of it.

                    Example: you don't want to track your bills in detail, but you know you want to \
                    keep spending to $400/week. Set that as a Custom amount here — the app will \
                    track your real spending against that $400 every week, with no Monthly Plan \
                    setup required at all.
                    """
            )

            CardBackground {
                Button {
                    isPresentingMonthlyPlan = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Monthly Plan")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Income, bills, savings, and weekly budget planning")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Security & Privacy

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Security & Privacy",
                infoTitle: "About Security & Privacy",
                infoExplanation: """
                    Four controls for keeping your financial data private on this device.

                    REQUIRE FACE ID — locks the entire app behind Face ID, Touch ID, or your \
                    device passcode. Turning it on asks you to authenticate once, right then, to \
                    confirm it works before it takes effect.

                    HIDE BALANCES BY DEFAULT — when on, every time you open the app it starts with \
                    Privacy Mode already active, so your numbers are hidden until you choose to \
                    reveal them, rather than showing by default.

                    PRIVACY MODE — hides every dollar amount on screen behind dots ("••••") right \
                    now, everywhere in the app, until you tap to reveal them again. This is the \
                    same switch as the eye icon shown elsewhere in the app.

                    LOCK NOW — appears once Face ID is required; tap it to immediately lock the app, \
                    without waiting for it to background/foreground.

                    Below the switches, "Read Security Notes" opens a full explanation of exactly \
                    what stays on your device versus what syncs to a server, and how Connected \
                    Accounts work securely.

                    Example: you turn on Face ID and Hide Balances by Default. Now the app requires \
                    Face ID to open, and your balances stay hidden as "••••" until you tap to show \
                    them — handy if someone's looking over your shoulder.
                    """
            )

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TransactionToggleRow(
                        title: "Require Face ID",
                        subtitle: "Lock SpendSmart until you authenticate",
                        isOn: Binding(
                            get: { requireFaceIDSetting },
                            set: { newValue in
                                if newValue {
                                    Task { await enableFaceIDIfAuthenticated() }
                                } else {
                                    requireFaceIDSetting = false
                                    settings.requireFaceID = false
                                    settings.updatedAt = .now
                                    biometricAuth.isFaceIDRequired = false
                                    biometricAuth.isUnlocked = true
                                }
                            }
                        )
                    )
                    if let faceIDToggleErrorMessage {
                        Text(faceIDToggleErrorMessage)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.statusOver)
                    }

                    Divider().overlay(Theme.cardStroke)

                    TransactionToggleRow(
                        title: "Hide Balances by Default",
                        subtitle: "Start each launch with Privacy Mode on",
                        isOn: Binding(
                            get: { hideBalancesByDefault },
                            set: { newValue in
                                hideBalancesByDefault = newValue
                                settings.hideBalancesByDefault = newValue
                                settings.updatedAt = .now
                            }
                        )
                    )

                    Divider().overlay(Theme.cardStroke)

                    TransactionToggleRow(
                        title: "Privacy Mode",
                        subtitle: "Hide dollar amounts right now, everywhere in the app",
                        isOn: Binding(
                            get: { privacyMode.isEnabled },
                            set: { newValue in privacyMode.isEnabled = newValue }
                        )
                    )

                    Divider().overlay(Theme.cardStroke)

                    Text("Manually entered data stays on this device. Connecting a financial institution through Plaid is optional and, once connected, syncs account data through a secure backend — see Security Notes for details.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)

                    Button {
                        isPresentingSecurityNotes = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("Read Security Notes")
                                .font(Theme.captionFont)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Connected Accounts

    private var connectedAccountsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Connected Accounts",
                infoTitle: "About Connected Accounts",
                infoExplanation: """
                    Where you link a real bank or credit card through Plaid, manage which \
                    institutions are connected, and refresh their balances. This is entirely \
                    optional; the app works fully with only Manual Accounts if you prefer never to \
                    connect a bank.

                    Example: you connect your checking account. From then on its transactions sync \
                    automatically, and you can turn on Auto Calculate (in Tools) so they count \
                    toward your spending totals without typing anything by hand.
                    """
            )

            CardBackground {
                Button {
                    isPresentingConnectedAccounts = true
                } label: {
                    HStack {
                        Text("Connected Accounts")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(plaidConnection.isConnected ? "Connected" : "Not Connected")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Categories

    /// Moved verbatim from `SettingsView` (previously a Tools subsection) during the Settings
    /// Organization recovery pass — content/bindings unchanged, only relocated to the Account
    /// screen.
    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Categories",
                infoTitle: "About Categories",
                infoExplanation: """
                    Categories are the labels you tag transactions with — Groceries, Gas, Dining, \
                    and so on — used to group your spending on the breakdown charts in Weekly \
                    Budget and Activity.

                    Tap "Categories" to see the full list, add your own new one, rename one, or \
                    archive one you no longer use. Archiving hides a category from future choices \
                    without touching any transaction that already used it — its past entries keep \
                    that label and still count in your history exactly as before.

                    Example: you add a "Pet Care" category. From then on, you can tag vet visits and \
                    pet food with it, and see exactly how much you spend on your pets each month on \
                    the category breakdown chart.
                    """
            )

            CardBackground {
                Button {
                    isPresentingCategoryManagement = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Categories")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text(activeCategories.count == 1 ? "1 active category" : "\(activeCategories.count) active categories")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Helpers

    private func labeledAmountField(title: String, amount: Binding<Decimal?>, onEdit: @escaping () -> Void) -> some View {
        Button(action: onEdit) {
            HStack {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                CurrencyAmountField(
                    amount: amount,
                    style: .inline,
                    isDisabled: true,
                    accessibilityLabel: title
                )
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func enableFaceIDIfAuthenticated() async {
        faceIDToggleErrorMessage = nil
        await biometricAuth.authenticate(reason: "Enable Face ID for SpendSmart", surfaceErrors: true)
        if biometricAuth.isUnlocked {
            requireFaceIDSetting = true
            settings.requireFaceID = true
            settings.updatedAt = .now
            biometricAuth.isFaceIDRequired = true
        } else {
            faceIDToggleErrorMessage = biometricAuth.lastErrorMessage ?? "Face ID verification failed. Please try again."
        }
    }
}

#Preview {
    AccountSettingsView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(BiometricAuthManager())
        .environment(PlaidConnectionManager())
        .environment(AuthenticationService.shared)
}
