import SwiftUI
import SwiftData
import UIKit

/// The two verified, hosted legal documents for SpendSmart — a single source of truth so
/// `SettingsView` (About section) and `ConnectedAccountsView` (pre-Link disclosure) never risk
/// drifting apart on the exact URL. Hosted at S&L Development LLC's own domain, not Plaid's —
/// these are SpendSmart's own Privacy Policy/Terms; the disclosure that Plaid's own separate
/// privacy policy/terms also apply is handled inline where it's shown, since that's a link to
/// plaid.com, not to either of these.
enum SpendSmartLegal {
    static let privacyPolicyURL = URL(string: "https://legal.sldevapps.com/privacy-policy.md")!
    static let termsOfServiceURL = URL(string: "https://legal.sldevapps.com/terms-of-service.md")!
}

struct SettingsView: View {
    /// True when presented as a sheet (e.g. from the Dashboard's gear icon), which needs an
    /// explicit way to close it. False in the normal tab context, where dismiss would be a no-op
    /// and a "Done" button would just be dead UI.
    var isModal: Bool = false

    @Query private var settingsList: [BudgetSettings]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(BiometricAuthManager.self) private var biometricAuth
    @Environment(PlaidConnectionManager.self) private var plaidConnection
    @Environment(AuthenticationService.self) private var authService
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel

    /// REVISED PRODUCT DIRECTION — always derived, display-only snapshots now (never manually
    /// edited from this screen). Still a primitive `@State` snapshot, matching every other
    /// `BudgetSettings`-backed value below, per the PROVEN sign-out crash fix architecture.
    @State private var weeklyLimit: Decimal?
    @State private var monthlyGoal: Decimal?
    /// PROVEN real-device crash fix ("This model instance was destroyed by calling ModelContext
    /// .reset... BudgetSettings", read via `includePendingTransactions`'s Binding getter) — every
    /// value `body` needs from `BudgetSettings` is snapshotted here, exactly mirroring the
    /// pre-existing `weeklyLimit`/`monthlyGoal` pattern above. `SettingsView` is a `TabView` child
    /// that stays mounted for as long as any of its own sheets (e.g. `AccountView`, presented
    /// during sign-out) are showing — a live `Binding` getter reading `settings.<property>`
    /// directly is re-evaluated at times outside this view's control (any SwiftUI re-render while
    /// still mounted), including possibly after the signed-out user's `ModelContext` has been
    /// invalidated. A `@State` primitive has no such risk: `body` never touches the `BudgetSettings`
    /// model to read these values, only to WRITE them, and writes only ever happen from a
    /// user-initiated toggle action, never a passive re-render.
    @State private var includePendingTransactions = true
    @State private var weekStartsOnSunday = true
    @State private var spendSenseEnabled = true
    @State private var showMonthlySpendingQuickStat = true
    @State private var showSavedThisMonthQuickStat = true
    @State private var requireFaceIDSetting = false
    @State private var hideBalancesByDefault = false
    @State private var faceIDToggleErrorMessage: String?
    @State private var isPresentingSecurityNotes = false
    @State private var isPresentingResetConfirmation = false
    @State private var isPresentingConnectedAccounts = false
    @State private var isPresentingMonthlyPlan = false
    @State private var isPresentingCategoryManagement = false
    @State private var isPresentingInsights = false
    @State private var isPresentingDataBackup = false
    @State private var isPresentingAccount = false
    @State private var isPresentingAccountRelatedOptions = false
    @State private var isPresentingFavorites = false
    /// LOCAL DATA RESTORE — drives the "Restore from Cloud" row's inline status. `nil` = idle
    /// (default state, including after a successful restore's brief confirmation fades away via
    /// user navigation — this is never auto-dismissed on a timer, only replaced by the next action).
    @State private var isRestoringFromCloud = false
    @State private var restoreFromCloudResultMessage: String?
    #if DEBUG
    @State private var isPresentingSpendSenseTest = false
    @State private var isPresentingSharedDataDiagnostics = false
    /// DEBUG-only developer preference — never synced, never tied to any specific authenticated
    /// user's data (see `DeveloperOptions.refreshLimitEnabledKey`'s own header for why plain
    /// standard `UserDefaults` is correct here, unlike this project's per-user-scoped settings).
    /// Defaults to `true` (normal, quota-limited behavior) on first launch.
    @AppStorage(DeveloperOptions.refreshLimitEnabledKey) private var refreshLimitEnabled = true
    #endif

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

    /// LOCAL DATA RESTORE — user-initiated only (never automatic), matching this app's existing
    /// Connected Accounts restore pattern (`ConnectedAccountsView.refreshConnectionStatusFromServer`,
    /// which restores from `list-connections` every time that screen appears). This one is a manual
    /// button rather than an auto-run-on-appear because, unlike Connected Accounts, writing
    /// Monthly Plan/Manual Account rows back into SwiftData is a real local mutation — the user
    /// should choose when that happens, not have it happen silently. See
    /// `LocalDataRestoreService`'s own header for exactly what is/isn't recoverable and why this
    /// is always safe to re-run (upsert-by-id, never overwrites an existing local row).
    private func restoreFromCloud() {
        guard let userId = authService.currentUserId else { return }
        isRestoringFromCloud = true
        restoreFromCloudResultMessage = nil
        Task {
            defer { isRestoringFromCloud = false }
            do {
                let summary = try await LocalDataRestoreService.restore(context: modelContext, userId: userId)
                let total = summary.incomeSourcesRestored + summary.recurringExpensesRestored
                    + summary.manualAccountsRestored + summary.manualTransactionsRestored
                    + (summary.monthlyPlanRestored ? 1 : 0)
                restoreFromCloudResultMessage = total > 0
                    ? "Restored \(summary.manualAccountsRestored) account(s), \(summary.manualTransactionsRestored) transaction(s), \(summary.incomeSourcesRestored) income source(s), \(summary.recurringExpensesRestored) bill(s)."
                    : "Nothing new to restore — your local data is already up to date."
            } catch {
                restoreFromCloudResultMessage = "Restore failed: \(error.localizedDescription)"
            }
        }
    }

    /// WEEKLY SPENDING UNIFICATION — the canonical Effective Planned Weekly Spending, computed
    /// the same way `MonthlyPlanView.plannedWeeklySpending` does (income/fixed-expenses/savings-
    /// goal/buffer via the existing leaf calculator functions, then
    /// `MonthlyPlanCalculator.effectivePlannedWeeklySpending`, respecting a custom override) —
    /// never a duplicated or alternate formula. Used only to keep Budget Settings' derived values
    /// current when this screen appears; the authoritative, always-current sync also runs from
    /// `MonthlyPlanView`'s own lifecycle hooks. Deliberately NOT actual-spending-adjusted (unlike
    /// the prior `currentMonthlySpendRemaining`) — Effective Planned Weekly Spending is a stable
    /// planning figure, never reduced by spending that's already happened.
    private var currentEffectivePlannedWeeklySpending: Decimal {
        let month = DateRangeHelper.currentMonthRange()
        let income = MonthlyPlanCalculator.estimatedMonthlyIncome(incomeSources, in: month)
        let fixedExpenses = MonthlyPlanCalculator.estimatedMonthlyFixedExpenses(recurringExpenses, in: month)
        let goal = monthlyPlanSettingsList.first?.monthlySavingsGoal ?? 0
        let buffer = monthlyPlanSettingsList.first?.bufferAmount ?? 0
        let flexible = MonthlyPlanCalculator.flexibleSpendingAvailable(income: income, fixedExpenses: fixedExpenses, savingsGoal: goal, bufferAmount: buffer)
        return MonthlyPlanCalculator.effectivePlannedWeeklySpending(override: monthlyPlanSettingsList.first?.plannedWeeklySpendingOverride, flexibleSpendingAvailable: flexible)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header
                    accountSection
                    favoritesSection
                    budgetSection
                    quickStatsSection
                    planningSection
                    spendSenseSection
                    securitySection
                    categoriesSection
                    dataSection
                    #if DEBUG
                    debugSection
                    #endif
                    aboutSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .scrollDismissesKeyboard(.interactively)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if isModal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .onAppear {
                // REVISED PRODUCT DIRECTION — reconciles ANY pre-existing/stale Budget Settings
                // values to the Monthly Plan's own derived formula the moment this screen appears
                // (covers both new users and users who had values from before this formula
                // existed). Safe to call before the primitive snapshots below are set: it only
                // writes to the live `settings` model, never reads back from `body`.
                let goal = monthlyPlanSettingsList.first?.monthlySavingsGoal ?? 0
                let expectedWeeklyLimit = currentEffectivePlannedWeeklySpending
                if settings.monthlyGoal != goal || settings.weeklySpendingLimit != expectedWeeklyLimit {
                    settings.applyMonthlyPlanAutoCalculate(monthlyPlanSavingsGoal: goal, monthlySpendRemaining: expectedWeeklyLimit * 4)
                }
                weeklyLimit = settings.weeklySpendingLimit
                monthlyGoal = settings.monthlyGoal
                includePendingTransactions = settings.includePendingTransactions
                weekStartsOnSunday = settings.weekStartsOnSunday
                spendSenseEnabled = settings.spendSenseEnabled ?? true
                showMonthlySpendingQuickStat = settings.showMonthlySpendingQuickStat ?? true
                showSavedThisMonthQuickStat = settings.showSavedThisMonthQuickStat ?? true
                requireFaceIDSetting = settings.requireFaceID
                hideBalancesByDefault = settings.hideBalancesByDefault
                biometricAuth.isFaceIDRequired = settings.requireFaceID
            }
            .sheet(isPresented: $isPresentingSecurityNotes) {
                SecurityNotesView()
            }
            .sheet(isPresented: $isPresentingConnectedAccounts) {
                ConnectedAccountsView()
            }
            .sheet(isPresented: $isPresentingMonthlyPlan) {
                // Decides once, before presenting anything, between User B's own owned plan and
                // (for an active Secondary with Monthly Plan currently shared) the Primary's real
                // plan directly — see `MonthlyPlanEntryView`'s own header.
                MonthlyPlanEntryView()
            }
            .sheet(isPresented: $isPresentingCategoryManagement) {
                CategoryManagementView()
            }
            .sheet(isPresented: $isPresentingInsights) {
                InsightsView()
            }
            .sheet(isPresented: $isPresentingDataBackup) {
                DataBackupView()
            }
            .sheet(isPresented: $isPresentingAccount) {
                AccountView()
            }
            .sheet(isPresented: $isPresentingAccountRelatedOptions) {
                AccountRelatedOptionsView()
            }
            .sheet(isPresented: $isPresentingFavorites) {
                FavoritesConfigurationView()
            }
            #if DEBUG
            .sheet(isPresented: $isPresentingSpendSenseTest) {
                SpendSenseTestView()
            }
            .sheet(isPresented: $isPresentingSharedDataDiagnostics) {
                SharedDataDiagnosticsView()
            }
            #endif
            .confirmationDialog(
                "Reset All Data?",
                isPresented: $isPresentingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    resetAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes every account, transaction, and setting stored by SpendSmart on this device. This cannot be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - A. Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image("SpendSmartLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("SpendSmart")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Text("Plan. Track. Save.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)

            Text("Version 1.0.0")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - A2. Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Account")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Button {
                        isPresentingAccount = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                // PROVEN real-device UX fix — reads the sticky display-only
                                // mirror, never the live currentUserEmail/isEmailVerified, which
                                // clear immediately on sign-out while this row (SettingsView
                                // itself, the AccountView sheet's own presenter) is still
                                // mounted. See AuthenticationService.lastDisplayedUserEmail's own
                                // doc comment for the full reasoning.
                                Text(authService.lastDisplayedUserEmail ?? "Account")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(authService.lastDisplayedIsEmailVerified ? "Verified" : "Not Verified")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(authService.lastDisplayedIsEmailVerified ? Theme.statusGood : Theme.statusWarning)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    // Hidden entirely until the server-verified role has resolved (never inferred
                    // locally, see AccountRelatedOptionsViewModel's own doc comment for why). Once
                    // resolved: Primary/no-household see "Account Related Options"; an active
                    // Secondary (Phase 8D) sees only "Share Connected Account" — the same row
                    // leads to AccountRelatedOptionsView either way, which renders the correct
                    // role-scoped content itself.
                    if accountRelatedOptionsViewModel.visibility != .hidden {
                        Divider().overlay(Theme.cardStroke)

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
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - A3. Favorites

    /// Locked entry point — "Profile ▸ Favorites" is this row, reached from Settings exactly like
    /// every other configuration destination (`Categories`, `Data Backup`, ...). Deliberately no
    /// second configuration entry point anywhere on the Dashboard itself.
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Favorites")

            CardBackground {
                Button {
                    isPresentingFavorites = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Favorites")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Choose what appears on your Dashboard Favorites Bar")
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

    // MARK: - B. Budget Settings

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Budget Settings")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    labeledAmountField(title: "Weekly Spending Limit", amount: $weeklyLimit, isDisabled: true)
                    Divider().overlay(Theme.cardStroke)
                    labeledAmountField(title: "Monthly Savings Goal", amount: $monthlyGoal, isDisabled: true)
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

                    Divider().overlay(Theme.cardStroke)

                    TransactionToggleRow(
                        title: "Week Starts on Sunday",
                        subtitle: "Turn off for a Monday–Sunday week",
                        isOn: Binding(
                            get: { weekStartsOnSunday },
                            set: { newValue in
                                weekStartsOnSunday = newValue
                                settings.weekStartsOnSunday = newValue
                                settings.updatedAt = .now
                            }
                        )
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// REVISED PRODUCT DIRECTION — replaces the prior dual-editable-field helper rows (which
    /// described "which field did you just edit" — no longer applicable now that neither field
    /// is ever manually edited). Shown once, under Monthly Savings Goal, explaining that both
    /// values are always derived from the Monthly Plan.
    private var derivedBudgetValuesHelperRow: some View {
        Text("Automatically calculated from your Monthly Plan savings goal and projected savings.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
    }

    // MARK: - B1. Quick Stats visibility

    private var quickStatsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Quick Stats")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TransactionToggleRow(
                        title: "Show Monthly Spending",
                        subtitle: "Show the Monthly Spending Quick Stat on the Dashboard",
                        isOn: Binding(
                            get: { showMonthlySpendingQuickStat },
                            set: { newValue in
                                showMonthlySpendingQuickStat = newValue
                                settings.showMonthlySpendingQuickStat = newValue
                                settings.updatedAt = .now
                            }
                        )
                    )

                    // LOCKED PRODUCT RULE — a Secondary never gets this toggle: their shared
                    // savings Quick Stat visibility is controlled exclusively by the Primary's own
                    // "Share Monthly Savings" permission (Account Related Options), not by a local
                    // per-device preference. Role comes from `accountRelatedOptionsViewModel`
                    // (server-sourced), never from `BudgetSettings` — this does not touch the
                    // primitive-snapshot rule above.
                    if accountRelatedOptionsViewModel.response?.role != .secondary {
                        Divider().overlay(Theme.cardStroke)

                        TransactionToggleRow(
                            title: "Show Saved This Month",
                            subtitle: "Show the Saved This Month Quick Stat on the Dashboard",
                            isOn: Binding(
                                get: { showSavedThisMonthQuickStat },
                                set: { newValue in
                                    showSavedThisMonthQuickStat = newValue
                                    settings.showSavedThisMonthQuickStat = newValue
                                    settings.updatedAt = .now
                                }
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - B2. Planning

    private var planningSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Planning")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
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

                    Divider().overlay(Theme.cardStroke)

                    Button {
                        isPresentingInsights = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Insights")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Ask questions about bills, income, and spending")
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
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - B3. Spend Sense

    private var spendSenseSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Spend Sense")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TransactionToggleRow(
                        title: "Enable Spend Sense",
                        subtitle: "Local financial guidance based on your data",
                        isOn: Binding(
                            get: { spendSenseEnabled },
                            set: { newValue in
                                spendSenseEnabled = newValue
                                settings.spendSenseEnabled = newValue
                                settings.updatedAt = .now
                            }
                        )
                    )

                    Divider().overlay(Theme.cardStroke)

                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text("Spend Sense analyzes your financial activity locally to identify useful trends, budget updates, recurring patterns, and other financial observations.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - C. Security & Privacy

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Security & Privacy")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TransactionToggleRow(
                        title: "Require Face ID",
                        subtitle: "Lock SpendSmart until you authenticate",
                        isOn: Binding(
                            get: { requireFaceIDSetting },
                            set: { newValue in
                                if newValue {
                                    // OFF -> ON requires a successful biometric check first —
                                    // the toggle visually stays off until this completes (and
                                    // snaps back off if it fails), never flipping on speculatively.
                                    // `requireFaceIDSetting` itself is only set true inside
                                    // `enableFaceIDIfAuthenticated()`'s success branch, so this
                                    // exact prior behavior is preserved.
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

                    if requireFaceIDSetting {
                        Divider().overlay(Theme.cardStroke)
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
                    }

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

    // MARK: - D. Categories

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Categories")

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

    // MARK: - E. Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Data")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("Manually entered data is stored locally on this device. Connecting a financial institution through Plaid is optional and syncs account data through a secure backend.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)

                    Divider().overlay(Theme.cardStroke)

                    Button {
                        isPresentingDataBackup = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Data Backup")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Export, import, and protect your finance data")
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

                    Divider().overlay(Theme.cardStroke)

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

                    Divider().overlay(Theme.cardStroke)

                    Button {
                        restoreFromCloud()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Restore from Cloud")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Recover Monthly Plan and Manual Accounts already synced to the cloud")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            if isRestoringFromCloud {
                                ProgressView()
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRestoringFromCloud)

                    if let restoreFromCloudResultMessage {
                        Text(restoreFromCloudResultMessage)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Divider().overlay(Theme.cardStroke)

                    HStack {
                        Text("Export CSV")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("Coming Soon")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Divider().overlay(Theme.cardStroke)

                    Button {
                        isPresentingResetConfirmation = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Reset All Data")
                                .font(Theme.bodyFont)
                        }
                        .foregroundStyle(Theme.statusOver)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - E2. Developer Options (DEBUG builds only — never present in Release/TestFlight/App Store)

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Developer Options")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Button {
                        isPresentingSpendSenseTest = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Spend Sense Test")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("DEBUG only \u{2014} exercises the real Spend Sense engine without saving data")
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

                    Divider().overlay(Theme.cardStroke)

                    // CONNECTED ACCOUNT REFRESH — DEBUG unlimited testing (locked requirement):
                    // ON (default) preserves the exact normal, server-quota-limited manual refresh
                    // behavior. OFF lets a developer repeatedly exercise the balance+transaction
                    // refresh workflow on their OWN accounts without the 2/day/account production
                    // restriction — see `PlaidConnectionManager`'s own DEBUG-only bypass method for
                    // exactly how this stays safe (a different, already-unlimited existing Plaid
                    // operation, never a client flag the server is asked to trust).
                    Toggle(isOn: $refreshLimitEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Refresh Limit")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text("DEBUG only \u{2014} OFF removes the 2/day/account limit for your own Connected Accounts during testing")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .tint(Theme.accent)

                    Divider().overlay(Theme.cardStroke)

                    // SHARED DATA DIAGNOSTICS — read-only, on-device view of the same shared-state
                    // information already surfaced by AccountRelatedOptionsViewModel's own DEBUG
                    // console log (see SharedDataDiagnosticsView's own header). No new fetch, no
                    // refresh, no state change of any kind.
                    Button {
                        isPresentingSharedDataDiagnostics = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Shared Data Diagnostics")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("DEBUG only \u{2014} read-only view of current shared-state for a Secondary")
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
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
    #endif

    // MARK: - F. About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "About")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image("SpendSmartLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("SpendSmart")
                                .font(Theme.headlineFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Personal finance tracker with optional Plaid-connected accounts")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    Divider().overlay(Theme.cardStroke)

                    HStack {
                        Text("Version")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("1.0.0")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Divider().overlay(Theme.cardStroke)

                    legalLink(title: "Privacy Policy", url: SpendSmartLegal.privacyPolicyURL)

                    Divider().overlay(Theme.cardStroke)

                    legalLink(title: "Terms of Service", url: SpendSmartLegal.termsOfServiceURL)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// One row in the About section that opens a legal document in the system browser via
    /// standard SwiftUI `Link` behavior — never a custom in-app webview, so the user gets the
    /// real browser chrome (address bar, share sheet, etc.) for a document this important.
    @ViewBuilder
    private func legalLink(title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Helpers

    /// Resigns the keyboard's first responder — used by both the tap-outside gesture and the
    /// keyboard toolbar's "Done" button, since neither of Settings' number fields is otherwise
    /// reachable to dismiss (no built-in "return" action makes sense for a decimal pad).
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// REVISED PRODUCT DIRECTION — read-only display of a Budget Settings amount. `onSubmit`
    /// removed entirely: both call sites (Weekly Spending Limit, Monthly Savings Goal) always
    /// pass `isDisabled: true` now, since neither field is ever manually editable.
    private func labeledAmountField(title: String, amount: Binding<Decimal?>, isDisabled: Bool) -> some View {
        HStack {
            Text(title)
                .font(Theme.bodyFont)
                .foregroundStyle(isDisabled ? Theme.textTertiary : Theme.textPrimary)
            Spacer()
            CurrencyAmountField(
                amount: amount,
                style: .inline,
                isDisabled: isDisabled,
                accessibilityLabel: title
            )
        }
    }

    /// Turning "Require Face ID" ON must succeed a real biometric check first — never flips the
    /// setting speculatively. Only ever enables for the CURRENT per-user `BudgetSettings` row
    /// (this view's `settings`, already scoped to the signed-in user's isolated store), so one
    /// user enabling this can never affect another user's row.
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

    private func resetAllData() {
        try? modelContext.delete(model: FinanceTransaction.self)
        try? modelContext.delete(model: Account.self)
        try? modelContext.delete(model: Category.self)
        try? modelContext.delete(model: BudgetSettings.self)

        let freshSettings = BudgetSettings()
        modelContext.insert(freshSettings)
        Category.makeDefaultSet().forEach { modelContext.insert($0) }

        // REVISED PRODUCT DIRECTION — resetAllData wipes FinanceTransaction/Account/Category/
        // BudgetSettings but deliberately never touches MonthlyPlanSettings, so an existing
        // Monthly Plan savings goal survives this reset. Re-derive immediately rather than
        // leaving the fresh BudgetSettings at its own zero/nil defaults regardless.
        let goal = monthlyPlanSettingsList.first?.monthlySavingsGoal ?? 0
        // income/fixed bills/buffer/any custom override are untouched by this reset, so
        // `currentEffectivePlannedWeeklySpending` still reflects them correctly.
        freshSettings.applyMonthlyPlanAutoCalculate(monthlyPlanSavingsGoal: goal, monthlySpendRemaining: currentEffectivePlannedWeeklySpending * 4)

        privacyMode.isEnabled = freshSettings.hideBalancesByDefault
        biometricAuth.isFaceIDRequired = freshSettings.requireFaceID
        biometricAuth.isUnlocked = true
        weeklyLimit = freshSettings.weeklySpendingLimit
        monthlyGoal = freshSettings.monthlyGoal
        includePendingTransactions = freshSettings.includePendingTransactions
        weekStartsOnSunday = freshSettings.weekStartsOnSunday
        spendSenseEnabled = freshSettings.spendSenseEnabled ?? true
        requireFaceIDSetting = freshSettings.requireFaceID
        hideBalancesByDefault = freshSettings.hideBalancesByDefault
    }
}

#Preview {
    SettingsView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(BiometricAuthManager())
        .environment(PlaidConnectionManager())
        .environment(AuthenticationService.shared)
}
