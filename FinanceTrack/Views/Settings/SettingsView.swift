import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

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
    @Query(sort: \Account.name) private var accountsForCSVExport: [Account]
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactionsForCSVExport: [FinanceTransaction]
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
    @State private var spendSenseEnabled = true
    @State private var showMonthlySpendingQuickStat = true
    @State private var showSavedThisMonthQuickStat = true
    @State private var requireFaceIDSetting = false
    @State private var hideBalancesByDefault = false
    /// Same `@State` primitive-snapshot safety pattern as every other `BudgetSettings`-backed
    /// value on this screen (see this file's own header comment above `includePendingTransactions`
    /// for the exact real-device crash this pattern prevents) — Plaid `account_id`s, never read
    /// live from `settings` inside `body`.
    @State private var autoCalculateConnectedAccountIds: [String] = []
    @State private var faceIDToggleErrorMessage: String?
    @State private var isPresentingSecurityNotes = false
    @State private var isPresentingUsersGuide = false
    @State private var isPresentingResetConfirmation = false
    @State private var isPresentingConnectedAccounts = false
    @State private var isPresentingMonthlyPlan = false
    @State private var isPresentingCategoryManagement = false
    @State private var isPresentingInsights = false
    @State private var isPresentingDataBackup = false
    /// `nil` until `prepareCSVExport()` completes at least once — see `hasPreparedCSVExport` for
    /// how this distinguishes "still preparing" from "prepared but genuinely nothing to export."
    @State private var csvExportURL: URL?
    @State private var hasPreparedCSVExport = false
    @State private var isPresentingCSVImporter = false
    @State private var csvImportPreview: TransactionCSVImportService.PreviewResult?
    @State private var isPresentingCSVImportPreview = false
    @State private var csvImportErrorMessage: String?
    @State private var isPresentingCSVImportError = false
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
                    autoCalculateConnectedAccountsSection
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
                spendSenseEnabled = settings.spendSenseEnabled ?? true
                showMonthlySpendingQuickStat = settings.showMonthlySpendingQuickStat ?? true
                showSavedThisMonthQuickStat = settings.showSavedThisMonthQuickStat ?? true
                requireFaceIDSetting = settings.requireFaceID
                hideBalancesByDefault = settings.hideBalancesByDefault
                biometricAuth.isFaceIDRequired = settings.requireFaceID
                autoCalculateConnectedAccountIds = settings.autoCalculateConnectedAccountIds ?? []
                prepareCSVExport()
            }
            .sheet(isPresented: $isPresentingSecurityNotes) {
                SecurityNotesView()
            }
            .sheet(isPresented: $isPresentingUsersGuide) {
                UsersGuideView()
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
            .sheet(isPresented: $isPresentingCSVImportPreview) {
                if let csvImportPreview {
                    CSVImportPreviewView(
                        preview: csvImportPreview,
                        accounts: accountsForCSVExport,
                        categories: categories,
                        onFinished: { self.csvImportPreview = nil }
                    )
                }
            }
            .fileImporter(isPresented: $isPresentingCSVImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                handleCSVImportSelection(result)
            }
            .alert("Couldn't Read CSV", isPresented: $isPresentingCSVImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(csvImportErrorMessage ?? "This file couldn't be read.")
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
            DashboardSectionHeader(
                title: "Account",
                infoTitle: "About Account",
                infoExplanation: """
                    Your sign-in and, if you're sharing your finances with someone, the controls \
                    for that.

                    THE TOP ROW (your email)
                    Tap it to see your account details, change your password, or sign out. \
                    "Verified" means you've confirmed your email address; "Not Verified" means you \
                    still need to click the confirmation link that was emailed to you.

                    THE SECOND ROW (household sharing) — only appears once your role is known
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
            DashboardSectionHeader(
                title: "Favorites",
                infoTitle: "About Favorites",
                infoExplanation: """
                    Tap "Favorites" to choose up to 6 shortcuts — screens or actions you use most — \
                    shown in a quick-access bar right at the top of your Dashboard. Reorder them by \
                    dragging, and remove any you no longer want there.

                    Example: you check your Weekly Budget and add a new expense almost every day. \
                    Adding both as Favorites puts them one tap away from the Dashboard, instead of \
                    navigating through the tabs each time.
                    """
            )

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
            DashboardSectionHeader(
                title: "Budget Settings",
                infoTitle: "About Budget Settings",
                infoExplanation: """
                    A read-only summary plus one real control.

                    WEEKLY SPENDING LIMIT / MONTHLY SAVINGS GOAL — these two fields are shown for \
                    reference only (you can't type into them here); they're always calculated from \
                    your Monthly Plan (or your Custom Planned Weekly Spending, if you've set one — \
                    see the Planning section). To actually change them, go to Planning → Monthly Plan.

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
                    // MONTH-ALIGNED FOUR-WEEK CORRECTION — the Sunday-vs-Monday week-boundary
                    // toggle that used to live here is intentionally removed: This Week/
                    // Week-by-Week/Monthly Outlook/Monthly Plan no longer use a calendar week at
                    // all (see `DateRangeHelper.fourWeekBlocks(in:)`), so the toggle would control
                    // nothing visible anymore. `BudgetSettings.weekStartsOnSunday` itself is kept,
                    // unchanged, on the model — several other, unrelated features still read it
                    // directly, and it may be surfaced again later.
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

    // MARK: - B0. Auto Calculate Weekly/Monthly from Connected-Account Transactions

    /// One row per known account (a connection with nothing cached yet has nothing to select),
    /// distinguished by institution name PLUS mask (e.g. "Wells Fargo •••5678") — mask alone is
    /// never stable/unique enough on its own, and two accounts at the same institution are
    /// otherwise indistinguishable, but the SELECTION itself is always keyed by `id`
    /// (`accountId`, Plaid's own `account_id` — the SAME stable identifier
    /// `FinanceTransaction.plaidAccountId` already uses), never by this display label. Built
    /// directly from `PlaidConnectionManager`'s already-cached balances — never a fresh Plaid
    /// call, this screen never syncs anything on its own.
    private struct EligibleAutoCalculateAccount: Identifiable {
        let id: String
        let label: String
    }

    private var eligibleAutoCalculateAccounts: [EligibleAutoCalculateAccount] {
        plaidConnection.connections.flatMap { connection -> [EligibleAutoCalculateAccount] in
            guard let cached = connection.cachedBalances, !cached.isEmpty else { return [] }
            return cached.values
                .sorted { $0.accountId < $1.accountId }
                .map { balance in
                    let maskSuffix = balance.mask.map { " •••\($0)" } ?? ""
                    return EligibleAutoCalculateAccount(
                        id: balance.accountId,
                        label: "\(connection.institutionName)\(maskSuffix)"
                    )
                }
        }
    }

    /// `true` when `accountId` is currently selected — reads the `@State` snapshot only, never
    /// `settings` live, matching this screen's own established crash-prevention pattern (see
    /// `includePendingTransactions`'s own header comment above).
    private func isAutoCalculateAccountSelected(_ accountId: String) -> Bool {
        autoCalculateConnectedAccountIds.contains(accountId)
    }

    /// CORRECTED ARCHITECTURE — toggling only ever changes WHICH account IDs are selected; no
    /// transaction object is read or written here. `BudgetCalculator.weeklyActualSpending`/
    /// `monthlyActualSpending` (the canonical read-only query every budget screen consumes) re-run
    /// automatically the next time those screens render, since `settings` is a live SwiftData
    /// model and this write triggers the normal `@Query` change notification — no explicit
    /// recompute call, no Plaid refresh, and no transaction mutation of any kind needed for the
    /// change to take effect immediately.
    private func setAutoCalculateAccountSelected(_ accountId: String, isSelected: Bool) {
        var updated = Set(autoCalculateConnectedAccountIds)
        if isSelected {
            updated.insert(accountId)
        } else {
            updated.remove(accountId)
        }
        let updatedArray = Array(updated)
        autoCalculateConnectedAccountIds = updatedArray
        settings.autoCalculateConnectedAccountIds = updatedArray
        settings.updatedAt = .now
    }

    private var autoCalculateConnectedAccountsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Auto Calculate Weekly/Monthly Based on Transactions for:",
                infoTitle: "About Auto Calculate",
                infoExplanation: """
                    This list shows every Connected (Plaid-linked) bank or credit card account on \
                    your device. Each has its own switch.

                    Turning an account ON means every real purchase or refund that syncs from that \
                    account counts toward your Spent This Week/Spent This Month automatically — you \
                    never have to type it in by hand. Turning it OFF means that account's \
                    transactions are visible in Activity for your records, but never added to your \
                    spending totals.

                    Only turn an account ON if the names its transactions sync under actually match \
                    what you'd expect — banks sometimes show a merchant name (like "SQ *COFFEE \
                    SHOP") that's different from how you'd normally describe the purchase. If a \
                    connected account's names don't line up with your own Monthly Plan or register, \
                    it's often clearer to leave it off and track that account manually instead.

                    Example: you turn on your credit card here. From then on, every purchase on it \
                    counts toward your Spent This Week the moment it syncs, with no manual entry \
                    required. Your checking account stays off because the payee names it syncs \
                    don't match your bills, so you keep tracking that one by hand instead.
                    """
            )

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if eligibleAutoCalculateAccounts.isEmpty {
                        Text("No connected accounts yet. Link an account in Connected Accounts to auto-calculate spending from its transactions.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(Array(eligibleAutoCalculateAccounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 {
                                Divider().overlay(Theme.cardStroke)
                            }
                            TransactionToggleRow(
                                title: account.label,
                                subtitle: "Imported transactions count toward Weekly/Monthly spending",
                                isOn: Binding(
                                    get: { isAutoCalculateAccountSelected(account.id) },
                                    set: { newValue in setAutoCalculateAccountSelected(account.id, isSelected: newValue) }
                                )
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - B1. Quick Stats visibility

    private var quickStatsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Quick Stats",
                infoTitle: "About Quick Stats",
                infoExplanation: """
                    Two switches controlling which small stat tiles appear on your Dashboard's \
                    Quick Stats grid.

                    SHOW MONTHLY SPENDING — turns the "Planned Monthly Spending" tile on the \
                    Dashboard on or off.

                    SHOW SAVED THIS MONTH — turns the "Saved This Month" tile on or off (this \
                    switch is only shown to a Primary — if you're a Secondary viewing someone else's \
                    shared finances, whether you see their savings figure is controlled entirely by \
                    what they've chosen to share with you, not by a setting here).

                    Turning a tile off doesn't delete anything — it just tidies up the Dashboard to \
                    show only the numbers you actually check.

                    Example: if you never look at "Saved This Month," turning it off here removes \
                    it from the grid, leaving more room for the stats you actually use.
                    """
            )

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
            DashboardSectionHeader(
                title: "Planning",
                infoTitle: "About Planning",
                infoExplanation: """
                    This section is your doorway into two tools: Monthly Plan and Insights.

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
                    yourself in this same Planning section. That weekly amount becomes your Weekly \
                    Spending Limit, which is what "Spent This Week" is measured against everywhere \
                    in the app (the Dashboard's "This Week" card, Weekly Budget, Quick Stats). It \
                    also drives "Monthly Remaining" and "Projected Savings" on the Dashboard's \
                    Monthly Outlook.

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

                    WHAT "INSIGHTS" IS

                    Insights (also called "Ask SpendSmart") is a simple question-and-answer tool \
                    over your own data — your bills, income, and spending — computed entirely on \
                    your device. Nothing you ask or any answer you get is ever sent anywhere. You \
                    can ask things like "how much do I have left this month" or "what bills are due \
                    this week" and get a plain-English answer built from your real numbers.

                    IF YOU DON'T USE MONTHLY PLAN AT ALL

                    You don't have to fill in Monthly Plan for the app to work. Your Spent This \
                    Week and Spent This Month totals are always based on your real transactions — \
                    Manual Account entries and any Connected Accounts you've turned on under Auto \
                    Calculate — whether or not Monthly Plan has anything in it. What changes is only \
                    the TARGET those totals are compared against: with nothing entered in Monthly \
                    Plan, Flexible Spending Available is $0, so Automatic weekly planning would also \
                    be $0 (making every dollar you spend look "over budget"). To avoid that, you can \
                    set a Custom Planned Weekly Spending amount right here in Planning — a plain \
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
            DashboardSectionHeader(
                title: "Spend Sense",
                infoTitle: "About Spend Sense",
                infoExplanation: """
                    Spend Sense looks at your own transactions, bills, and spending trends right on \
                    your device (nothing is sent anywhere) and surfaces useful, plain-English \
                    observations — a possible forgotten subscription, a category running higher than \
                    usual, or a helpful reminder based on your budget.

                    ENABLE SPEND SENSE — the one switch in this section. Turn it off if you'd rather \
                    the app never show these observations at all; turn it on to have it quietly \
                    watch your data and flag anything worth your attention.

                    Example: Spend Sense notices a $12.99 charge from the same merchant every month \
                    and flags it as a likely subscription, helping you catch one you meant to cancel.
                    """
            )

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

    // MARK: - E. Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Data",
                infoTitle: "About Data",
                infoExplanation: """
                    Backing up, restoring, and connecting your accounts.

                    DATA BACKUP — export your transactions to a file you can save, print, or open \
                    elsewhere, or restore missing transactions from a backup file if something's \
                    ever gone missing from your register.

                    CONNECTED ACCOUNTS — where you link a real bank or credit card through Plaid, \
                    manage which institutions are connected, and refresh their balances. This is \
                    entirely optional; the app works fully with only Manual Accounts if you prefer \
                    never to connect a bank.

                    RESTORE FROM CLOUD — pulls your Monthly Plan and Manual Account data back down \
                    from the cloud, useful after a new phone or a reinstall, as long as you're \
                    signed in to the same account.

                    RESET ALL DATA — permanently erases everything on this device. Use this only if \
                    you genuinely want to start completely over; there's no undo.

                    Example: you get a new phone. Signing in and using "Restore from Cloud" brings \
                    all your Manual Accounts and Monthly Plan back, so you don't have to start over \
                    from scratch.
                    """
            )

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

                    if let csvExportURL {
                        ShareLink(item: csvExportURL) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Export CSV")
                                        .font(Theme.bodyFont)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("Export your full transaction history, grouped by account")
                                        .font(Theme.captionFont)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack {
                            Text("Export CSV")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(hasPreparedCSVExport ? "No Transactions" : "Preparing…")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    Divider().overlay(Theme.cardStroke)

                    Button {
                        isPresentingCSVImporter = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Restore Missing Transactions from CSV")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Adds only transactions missing from this device — never replaces your current data")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)

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
            DashboardSectionHeader(
                title: "About",
                infoTitle: "About This Section",
                infoExplanation: """
                    App info, the legal documents, and the User's Guide — a complete, start-to-\
                    finish walkthrough covering Connected Accounts, Manual Accounts, whether or not \
                    to use a Monthly Plan, and everything else, written for someone brand new to \
                    the app.

                    If you're not sure where to begin, tap "User's Guide" below.
                    """
            )

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

                    Button {
                        isPresentingUsersGuide = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("User's Guide")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("A complete, start-to-finish walkthrough of the app")
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

    // MARK: - CSV export

    /// Builds (or rebuilds) the CSV export file up front, mirroring `DataBackupView.
    /// prepareManualExport()`'s own "ready before the user taps" pattern so `ShareLink` never has
    /// to wait on a tap. `hasPreparedCSVExport` is set on every path (success, genuinely-empty, or
    /// write failure) so the row can distinguish "still preparing" from "prepared but there is
    /// nothing to export" — `csvExportURL` staying `nil` alone is ambiguous between those two.
    private func prepareCSVExport() {
        defer { hasPreparedCSVExport = true }
        guard let csv = TransactionCSVExportService.csvString(for: accountsForCSVExport, allTransactions: transactionsForCSVExport) else {
            csvExportURL = nil
            return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(TransactionCSVExportService.exportFilename())
            try TransactionCSVExportService.write(csv, to: url)
            csvExportURL = url
        } catch {
            csvExportURL = nil
        }
    }

    // MARK: - CSV import (Restore Missing Transactions)

    /// Reads the picked file, strips a leading UTF-8 BOM if present (this app's own exporter
    /// writes one — see `TransactionCSVExportService.write`), parses it, and compares against
    /// the CURRENT user's own already-loaded accounts/transactions (`accountsForCSVExport`/
    /// `transactionsForCSVExport`, the same `@Query` results the export row already reads) —
    /// never a separate/parallel data-access path, so this can never cross into another user's
    /// store. Writes nothing: only builds the preview shown next.
    private func handleCSVImportSelection(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            csvImportErrorMessage = error.localizedDescription
            isPresentingCSVImportError = true
        case .success(let url):
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
            do {
                var data = try Data(contentsOf: url)
                let bom = Data([0xEF, 0xBB, 0xBF])
                if data.starts(with: bom) {
                    data.removeFirst(bom.count)
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    csvImportErrorMessage = "This file isn't valid UTF-8 text."
                    isPresentingCSVImportError = true
                    return
                }
                let parseResult = TransactionCSVImportService.parse(text)
                guard parseResult.isRecognizedFormat else {
                    csvImportErrorMessage = "This doesn't look like a SpendSmart CSV export."
                    isPresentingCSVImportError = true
                    return
                }
                let existingIDs = Set(transactionsForCSVExport.map(\.id))
                csvImportPreview = TransactionCSVImportService.preview(
                    parseResult: parseResult,
                    existingTransactionIDs: existingIDs,
                    accounts: accountsForCSVExport
                )
                isPresentingCSVImportPreview = true
            } catch {
                csvImportErrorMessage = "This file couldn't be read."
                isPresentingCSVImportError = true
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
        spendSenseEnabled = freshSettings.spendSenseEnabled ?? true
        requireFaceIDSetting = freshSettings.requireFaceID
        hideBalancesByDefault = freshSettings.hideBalancesByDefault
        // No reconcile call needed here: resetAllData already deletes every FinanceTransaction
        // row outright (above), so there is nothing left for AutoCalculateBudgetTransactionsService
        // to reconcile — only the UI snapshot needs to go back to empty, matching freshSettings.
        autoCalculateConnectedAccountIds = freshSettings.autoCalculateConnectedAccountIds ?? []
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
