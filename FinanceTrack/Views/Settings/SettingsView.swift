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

/// SETTINGS ORGANIZATION PHASE — Tools has no destination screen of its own (it's a section
/// directly on the main Settings screen — see this app's own explicit "Tools is NOT a separate
/// screen" requirement). This is the lightweight mechanism that lets the `.tools` Dashboard
/// Favorite still "go" somewhere specific: it opens the canonical `SettingsView`, tagged with this
/// target, which a `ScrollViewReader` inside `SettingsView.body` uses to scroll straight to the
/// Tools section on appearance. Only one case exists today; additive by design if a future
/// Favorite ever needs to target another in-page anchor.
enum SettingsScrollTarget: Hashable, Sendable {
    case tools
}

/// SETTINGS ORGANIZATION PHASE (RECOVERY PASS) — the main Settings screen hosts: an "Account"
/// group (two navigation rows, "Profile" and "Account", each opening its own destination screen —
/// see `AccountView`/`AccountSettingsView`); a "Tools" group whose four subsections (Auto
/// Calculate, Quick Stats, Data Tools, Developer Options — DEBUG-only) are collapsible, collapsed
/// by default; a "Favorites" row (moved back here from `AccountView`/Profile — Favorites is on the
/// main Settings screen, not under Profile); and "About", always expanded. The standalone
/// assistant row this phase originally added here was later removed entirely — see the SPENDAI UI
/// PLACEMENT CORRECTION note further down this file. Categories moved to `AccountSettingsView`
/// (previously a Tools subsection here). Budget Settings, Monthly Plan, Security & Privacy,
/// Account Related Options, and Connected Accounts all MOVED to `AccountSettingsView` (this file's
/// own former `budgetSection`/`planningSection`/`securitySection`/parts of `accountSection`/
/// `dataSection`) — this is a pure reorganization, not a rewrite; every moved control's bindings/
/// persistence/crash-prevention snapshot pattern are unchanged, just relocated.
struct SettingsView: View {
    /// True when presented as a sheet (e.g. from the Dashboard's gear icon, or the `.tools`
    /// Favorite), which needs an explicit way to close it. False in the normal tab context, where
    /// dismiss would be a no-op and a "Done" button would just be dead UI.
    var isModal: Bool = false
    /// SETTINGS ORGANIZATION PHASE — optional scroll target for opening Settings already
    /// positioned at a specific section, used by the `.tools` Dashboard Favorite (which has no
    /// destination screen of its own — see `SettingsScrollTarget`'s own header). `nil` (the
    /// default) leaves the screen at its natural top-of-scroll position, matching every pre-
    /// existing `SettingsView()` call site exactly.
    var scrollTarget: SettingsScrollTarget? = nil

    @Query private var settingsList: [BudgetSettings]
    @Query(sort: \Category.name) private var categories: [Category]
    /// Kept here (duplicated from `AccountSettingsView`, which owns the live Budget Settings UI)
    /// solely so `resetAllData()` below can keep proactively recalculating the derived weekly/
    /// monthly budget figures immediately on reset, exactly as it always has — never touched by
    /// `MonthlyPlanCalculator.swift` itself, which this phase does not modify.
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

    @State private var showMonthlySpendingQuickStat = true
    @State private var showSavedThisMonthQuickStat = true
    /// Same `@State` primitive-snapshot safety pattern as every other `BudgetSettings`-backed
    /// value in this app (see `AccountSettingsView`'s own header for the exact real-device crash
    /// this pattern prevents) — Plaid `account_id`s, never read live from `settings` inside `body`.
    @State private var autoCalculateConnectedAccountIds: [String] = []
    @State private var isPresentingUsersGuide = false
    @State private var isPresentingResetConfirmation = false
    @State private var isPresentingDataBackup = false
    @State private var isPresentingFavorites = false
    /// SETTINGS ORGANIZATION PHASE — the four Tools subsections are collapsible, collapsed by
    /// default (a locked requirement); each gets its own independent `@State` so expanding one
    /// never affects the others.
    @State private var isAutoCalculateExpanded = false
    @State private var isQuickStatsExpanded = false
    @State private var isDataToolsExpanded = false
    @State private var isCalculateTransactionsExpanded = false
    #if DEBUG
    @State private var isDeveloperOptionsExpanded = false
    #endif
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
    @State private var isPresentingAccountSettings = false
    @State private var isPresentingQuickStats = false
    @State private var isPresentingCalculateTransactions = false
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

    /// Duplicated from `AccountSettingsView` — see this type's own `@Query incomeSources`
    /// property header for why. Used only by `resetAllData()`.
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

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        header
                        accountRowsSection
                        toolsHeader
                        autoCalculateConnectedAccountsSection
                        quickStatsSection
                        dataSection
                        calculateTransactionsSection
                        #if DEBUG
                        debugSection
                        #endif
                        favoritesSection
                        aboutSection
                    }
                    .padding(.vertical, Theme.Spacing.lg)
                }
                .onAppear {
                    guard scrollTarget == .tools else { return }
                    // Deferred to the next run loop turn so the ScrollView has laid out its
                    // content at least once before `scrollTo` is asked to locate the anchor —
                    // matching this app's own "no arbitrary time-based workaround" convention
                    // (this is a scheduling deferral, not a sleep/fixed delay).
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo(SettingsScrollTarget.tools, anchor: .top)
                    }
                }
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
                showMonthlySpendingQuickStat = settings.showMonthlySpendingQuickStat ?? true
                showSavedThisMonthQuickStat = settings.showSavedThisMonthQuickStat ?? true
                autoCalculateConnectedAccountIds = settings.autoCalculateConnectedAccountIds ?? []
                prepareCSVExport()
            }
            .sheet(isPresented: $isPresentingUsersGuide) {
                UsersGuideView()
            }
            .sheet(isPresented: $isPresentingFavorites) {
                FavoritesConfigurationView()
            }
            .sheet(isPresented: $isPresentingDataBackup) {
                DataBackupView()
            }
            .sheet(isPresented: $isPresentingAccount) {
                AccountView()
            }
            .sheet(isPresented: $isPresentingAccountSettings) {
                AccountSettingsView()
            }
            // CORRECTION (2026-08-18) — a modally-presented sheet does not auto-dismiss just
            // because the content underneath it swaps (e.g. `FinanceTrackApp`'s root Group
            // switching to `AuthFlowView` once `sessionState` flips to `.signedOut`). Without this,
            // sign-out from `AccountView`'s sheet visibly "does nothing" until the user manually
            // taps Done, closing the sheet and only THEN revealing the already-signed-out root.
            // Safe to do here (unlike the `dismiss()` call deliberately removed from
            // `AccountView.signOut()` — see that file's header comment for the exact crash that
            // caused): this view's `body` only ever reads primitive `@State` snapshots, never a
            // live `settings.<property>` Binding, so re-evaluating it here touches no
            // already-invalidated `BudgetSettings`/`ModelContext` state. `isPresentingAccountSettings`
            // dismisses `AccountSettingsView` (and, via the normal modal-presentation cascade,
            // anything IT had presented) — that view also defensively closes its own nested sheets
            // on this same signal, matching this app's established defensive-in-depth convention.
            .onChange(of: authService.sessionState) { _, newValue in
                guard newValue == .signedOut else { return }
                isPresentingAccount = false
                isPresentingAccountSettings = false
            }
            .sheet(isPresented: $isPresentingQuickStats) {
                QuickStatsConfigurationView()
            }
            .sheet(isPresented: $isPresentingCalculateTransactions) {
                CalculateTransactionsView()
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

    /// SETTINGS BRANDING (Settings-only — Dashboard branding is untouched) — Scott's supplied
    /// `New_Logo.png`/`App_Name.png` artwork, both byte-identical copies into their own imagesets
    /// (`SettingsLogo`/`SettingsAppName`). `.scaledToFit()` on both preserves each image's own
    /// source aspect ratio; neither is ever stretched.
    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image("SettingsLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(height: 64)
                .accessibilityLabel("SpendSmart")

            Image("SettingsAppName")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(height: 28)
                .accessibilityHidden(true)

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

    /// SETTINGS ORGANIZATION PHASE — replaces the prior single "Account" card (email/verification
    /// preview + Account Related Options + Lock Now, all inline) with two plain navigation rows,
    /// matching every other simple Settings row's convention (`Favorites`, `Quick Stats`, ...).
    /// "Profile" opens `AccountView` (email/verification, a future-Subscription placeholder, and
    /// sign-out/delete-account); "Account" opens `AccountSettingsView` (Account Related Options,
    /// Budget Settings, Monthly Plan, Security & Privacy, Connected Accounts, and Categories — all
    /// moved wholesale from this file, unchanged bindings). Favorites lives on the main Settings
    /// screen, not under either doorway.
    private var accountRowsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            MajorSectionHeaderCard(
                icon: "person.fill",
                title: "Account",
                infoTitle: "About Account",
                infoExplanation: """
                    Two doorways into your account.

                    PROFILE — your sign-in identity: email address, verification status, and signing \
                    out or permanently deleting your account.

                    ACCOUNT — your financial configuration: Account Related Options (household \
                    sharing, if you use it), Budget Settings, Monthly Plan, Security & Privacy, \
                    Connected Accounts, and Categories.

                    Example: to see whether your email is verified or to sign out, tap Profile. To \
                    invite someone to see your finances or turn on Face ID, tap Account.
                    """
            )
            .padding(.horizontal, Theme.Spacing.lg)

            accountChildRow(title: "Profile") {
                isPresentingAccount = true
            }
            accountChildRow(title: "Account") {
                isPresentingAccountSettings = true
            }
        }
    }

    /// SETTINGS ACCOUNT CHILD ROWS CORRECTION — Profile/Account no longer share one large card
    /// container; each is now its own plain row using the EXACT same visual treatment as
    /// the Tools children (Auto Calculate/Quick Stats/Data Tools' own `SettingsCollapsibleSection`
    /// header row): `Theme.headlineFont` text, the same 14pt bold chevron immediately after the
    /// title, the same leading indent, and the same row spacing (via this property's own VStack,
    /// now `Theme.Spacing.lg` to match the rhythm between every other top-level Settings row).
    /// Navigation is unchanged — each row's own `action` closure sets the exact same
    /// `isPresentingAccount`/`isPresentingAccountSettings` flags as before.
    private func accountChildRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.leading, Theme.Spacing.md)
    }

    // MARK: - A3. (SpendAI standalone Settings row removed — see below)
    //
    // SPENDAI UI PLACEMENT CORRECTION — the standalone assistant row/card that used to live
    // here was removed entirely per Scott's explicit instruction: Settings should not contain any
    // separate SpendAI option/card/row, no SpendAI image, no SpendAI header control, and no
    // Favorites bar. SpendAI remains reachable app-wide via Dashboard/Weekly/Activity/Manual
    // Accounts/Monthly Plan/the Dashboard Favorite — never from Settings.

    // MARK: - A4. Tools

    /// SETTINGS ORGANIZATION PHASE — Tools is a SECTION directly on this screen, never a separate
    /// `ToolsView` (an explicit, locked requirement). Its four subsections (Auto Calculate, Quick
    /// Stats, Data Tools, and DEBUG-only Developer Options) are each their own `SettingsCollapsibleSection`,
    /// collapsed by default. Favorites and About sit below Tools on the same main screen but are
    /// NOT part of the collapsible group — About always stays expanded, Favorites has no
    /// collapse/expand state at all. The `.id(SettingsScrollTarget.tools)` tag is what `body`'s
    /// `ScrollViewReader` targets for the `.tools` Dashboard Favorite — a stable, semantic anchor,
    /// never an arbitrary pixel offset.
    private var toolsHeader: some View {
        MajorSectionHeaderCard(
            icon: "wrench.fill",
            title: "Tools",
            infoTitle: "About Tools",
            infoExplanation: """
                Day-to-day configuration for how SpendSmart tracks and displays your finances. Tap \
                any section below to expand it.

                AUTO CALCULATE — choose which Connected (Plaid-linked) accounts automatically count
                their real transactions toward your Spent This Week/Month totals.

                QUICK STATS — choose which small stat tiles appear on your Dashboard.

                DATA TOOLS — back up, export, and restore your transactions, and manage Connected
                Accounts from the Account screen.

                Example: to have a credit card's purchases count toward your spending automatically, \
                turn it on under Auto Calculate below.
                """
        )
        .id(SettingsScrollTarget.tools)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.sm)
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

    /// Collapsed by default (`isAutoCalculateExpanded`, a locked Tools requirement). SETTINGS
    /// HIERARCHY CORRECTION — the collapsed title was shortened from "Auto Calculate Weekly/
    /// Monthly Based on Transactions for:" to exactly "Auto Calculate" (too long for a Tools
    /// child row); the dropped "Based on Transactions for:" phrase now appears as the first line
    /// INSIDE the expanded content, directly above the unchanged account-toggle rows. Uses the
    /// shared `SettingsCollapsibleSection` (never the default system disclosure presentation) for the corrected
    /// chevron + indentation; no binding/persistence/account-selection logic below was touched.
    private var autoCalculateConnectedAccountsSection: some View {
        SettingsCollapsibleSection(
            title: "Auto Calculate",
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
                """,
            isExpanded: $isAutoCalculateExpanded
        ) {
            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("Based on Transactions for:")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)

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
            .padding(.top, Theme.Spacing.sm)
        }
    }

    // MARK: - B1. Quick Stats visibility

    /// Collapsed by default (`isQuickStatsExpanded`) — same shared `SettingsCollapsibleSection`
    /// wrap as Auto Calculate above; the row's own binding/presentation is unchanged.
    private var quickStatsSection: some View {
        SettingsCollapsibleSection(
            title: "Quick Stats",
            infoTitle: "About Quick Stats",
            infoExplanation: """
                Which small stat tiles appear on your Dashboard's Quick Stats grid — Planned \
                Weekly Spending, Spent This Week, Planned Monthly Spending, Projected Available \
                After Spend, Saved This Month, and Saved.

                Tap "Quick Stats" below to check or uncheck any of them — the same picker also \
                reachable from the small "+" next to "Quick Stats" on your Dashboard. Nothing is \
                deleted when you hide one; it just tidies up the grid to show only the numbers \
                you actually check.

                Example: if you never look at "Saved This Month," open this picker and uncheck \
                it — it disappears from the grid, leaving more room for the stats you actually \
                use.
                """,
            isExpanded: $isQuickStatsExpanded
        ) {
            CardBackground {
                Button {
                    isPresentingQuickStats = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quick Stats")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Choose which stats appear on the Dashboard")
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
            .padding(.top, Theme.Spacing.sm)
        }
    }

    // MARK: - B2. Spend Sense
    //
    // ASK SPENDSMART PHASE — the Spend Sense enable/disable toggle UI that lived in this section
    // was removed: investigation confirmed it never gated any real behavior (the internal SpendSense
    // deterministic engine — `FinanceTrack/Services/SpendSense/` — has never been called from any
    // production UI; its only callers are unit tests and the `#if DEBUG` Developer Options harness,
    // neither of which read this toggle). `BudgetSettings.spendSenseEnabled` itself, its default,
    // and its backup/migration round-trip are all deliberately UNCHANGED — only this now-removed
    // Settings row and its explanatory card are gone. If the deterministic engine is ever wired to
    // a real, functioning toggle in a future phase, it would go here, between Quick Stats and Data
    // Tools.

    // MARK: - E. Data

    /// Collapsed by default (`isDataToolsExpanded`) — same shared `SettingsCollapsibleSection`
    /// wrap; visible title renamed "Data" → "Data Tools" to match the locked Tools subsection
    /// naming. No binding, button action, or persistence below was touched.
    private var dataSection: some View {
        SettingsCollapsibleSection(
            title: "Data Tools",
            infoTitle: "About Data Tools",
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
                """,
            isExpanded: $isDataToolsExpanded
        ) {
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
            .padding(.top, Theme.Spacing.sm)
        }
    }

    // MARK: - E1a. Calculate Transactions

    /// CALCULATE TRANSACTIONS PHASE — the fourth Tools child, immediately after Data Tools (its
    /// long-reserved intended position — see this file's own prior placeholder comment). Same
    /// shared `SettingsCollapsibleSection`/single-row-button pattern as `quickStatsSection` above
    /// (collapsed by default, opens a sheet) — a READ-ONLY calculator, never a data mutation
    /// surface; see `CalculateTransactionsView`'s own header for the full behavior.
    private var calculateTransactionsSection: some View {
        SettingsCollapsibleSection(
            title: "Calculate Transactions",
            infoTitle: "About Calculate Transactions",
            infoExplanation: """
                A read-only calculator: choose an account, check off individual transactions, and \
                see a running subtotal for that account.

                Switch to another account and select more — your prior selections are kept, so you \
                can build one combined Grand Total across transactions from multiple accounts.

                Nothing here is ever saved or changed — no transaction, balance, budget, or Monthly \
                Plan is touched. Your selections are only remembered while this screen is open.

                Example: add up two Amex charges and three Wells Fargo charges together, without \
                affecting either account's real balance or your budget.
                """,
            isExpanded: $isCalculateTransactionsExpanded
        ) {
            CardBackground {
                Button {
                    isPresentingCalculateTransactions = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Calculate Transactions")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Select transactions across accounts and total them up")
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
            .padding(.top, Theme.Spacing.sm)
        }
    }

    // MARK: - E2. Developer Options (DEBUG builds only — never present in Release/TestFlight/App Store)

    #if DEBUG
    /// Collapsed by default (`isDeveloperOptionsExpanded`) — SETTINGS HIERARCHY CORRECTION: unlike
    /// the three Tools children above, Developer Options must visually read as ITS OWN major
    /// section (same treatment as Account/Tools/About), not a Tools child, while still being
    /// collapsed-by-default content — `SettingsCollapsibleSection(isMajorSection: true)` gives it
    /// major-section typography with no extra indent, sharing the same corrected chevron.
    private var debugSection: some View {
        SettingsCollapsibleSection(title: "Developer Options", isMajorSection: true, majorSectionIcon: "chevron.left.forwardslash.chevron.right", isExpanded: $isDeveloperOptionsExpanded) {
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
            .padding(.top, Theme.Spacing.sm)
        }
        .padding(.top, Theme.Spacing.sm)
    }
    #endif

    // MARK: - E3. Favorites

    /// Moved back to the main Settings screen (not under Profile, not collapsible) — a locked
    /// requirement of the Settings Organization recovery pass.
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(
                title: "Favorites",
                infoTitle: "About Favorites",
                infoExplanation: """
                    Tap "Favorites" to choose up to 8 shortcuts — screens or actions you use most — \
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

    // MARK: - F. About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            MajorSectionHeaderCard(
                icon: "info.circle.fill",
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
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.sm)

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
        // leaving the fresh BudgetSettings at its own zero/nil defaults regardless — this keeps
        // Dashboard/Weekly/Monthly Plan's own reads of `weeklySpendingLimit`/`monthlyGoal` correct
        // immediately, without waiting for `AccountSettingsView` (which owns the equivalent UI
        // since the Settings Organization phase) to next appear and re-sync it itself.
        let goal = monthlyPlanSettingsList.first?.monthlySavingsGoal ?? 0
        // income/fixed bills/buffer/any custom override are untouched by this reset, so
        // `currentEffectivePlannedWeeklySpending` still reflects them correctly.
        freshSettings.applyMonthlyPlanAutoCalculate(monthlyPlanSavingsGoal: goal, monthlySpendRemaining: currentEffectivePlannedWeeklySpending * 4)

        privacyMode.isEnabled = freshSettings.hideBalancesByDefault
        biometricAuth.isFaceIDRequired = freshSettings.requireFaceID
        biometricAuth.isUnlocked = true
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
