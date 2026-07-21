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

    @State private var weeklyLimit: Decimal?
    @State private var monthlyGoal: Decimal?
    /// True only for the duration of a programmatic counterpart-field update inside
    /// `saveWeeklyLimit()`/`saveMonthlyGoal()` — see `labeledAmountField`'s `onChange` guard.
    @State private var isSyncingCounterpartField = false
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
    #if DEBUG
    @State private var isPresentingSpendSenseTest = false
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

    private var hasIncomeDataForProjection: Bool {
        MonthlyPlanCalculator.hasIncomeDataForProjection(incomeSources)
    }

    /// Weekly-limit savings projection, computed once via `MonthlyPlanCalculator` — never
    /// duplicated here. Only the final projected number is ever shown; income/bill totals and
    /// lists stay private to Monthly Plan itself.
    private var projectedSavingsFromWeeklyLimit: Decimal {
        let month = DateRangeHelper.currentMonthRange()
        let income = MonthlyPlanCalculator.estimatedMonthlyIncome(incomeSources, in: month)
        let fixedExpenses = MonthlyPlanCalculator.estimatedMonthlyFixedExpenses(recurringExpenses, in: month)
        let buffer = monthlyPlanSettingsList.first?.bufferAmount ?? 0
        let availableAfterBills = MonthlyPlanCalculator.availableAfterBills(income: income, fixedExpenses: fixedExpenses, bufferAmount: buffer)

        let spendingWeeks = DateRangeHelper.weeksOverlapping(month, weekStartsOnSunday: settings.weekStartsOnSunday).count
        let weeklyLimit = self.weeklyLimit ?? settings.weeklySpendingLimit
        let monthlyBudget = MonthlyPlanCalculator.monthlySpendingBudget(weeklyLimit: weeklyLimit, spendingWeeksInMonth: spendingWeeks)

        return MonthlyPlanCalculator.projectedSavingsFromWeeklyLimit(availableAfterBills: availableAfterBills, monthlySpendingBudget: monthlyBudget)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header
                    accountSection
                    budgetSection
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
                weeklyLimit = settings.weeklySpendingLimit
                monthlyGoal = settings.monthlyGoal
                biometricAuth.isFaceIDRequired = settings.requireFaceID
            }
            .sheet(isPresented: $isPresentingSecurityNotes) {
                SecurityNotesView()
            }
            .sheet(isPresented: $isPresentingConnectedAccounts) {
                ConnectedAccountsView()
            }
            .sheet(isPresented: $isPresentingMonthlyPlan) {
                MonthlyPlanView()
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
            #if DEBUG
            .sheet(isPresented: $isPresentingSpendSenseTest) {
                SpendSenseTestView()
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
                                Text(authService.currentUserEmail ?? "Account")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(authService.isEmailVerified ? "Verified" : "Not Verified")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(authService.isEmailVerified ? Theme.statusGood : Theme.statusWarning)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    // Primary-only — hidden entirely for a Secondary or until the server-verified
                    // role has resolved (never inferred locally, see
                    // AccountRelatedOptionsViewModel's own doc comment for why).
                    if accountRelatedOptionsViewModel.visibility != .hidden {
                        Divider().overlay(Theme.cardStroke)

                        Button {
                            isPresentingAccountRelatedOptions = true
                        } label: {
                            HStack {
                                Text("Account Related Options")
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

    // MARK: - B. Budget Settings

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Budget Settings")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    labeledAmountField(title: "Weekly Spending Limit", amount: $weeklyLimit, onSubmit: saveWeeklyLimit)
                    weeklySpendingLimitHelperRow
                    Divider().overlay(Theme.cardStroke)
                    labeledAmountField(title: "Monthly Savings Goal", amount: $monthlyGoal, onSubmit: saveMonthlyGoal)
                    monthlySavingsGoalHelperRow
                    Divider().overlay(Theme.cardStroke)

                    TransactionToggleRow(
                        title: "Include Pending Transactions",
                        subtitle: "Count pending transactions toward your totals",
                        isOn: Binding(
                            get: { settings.includePendingTransactions },
                            set: { newValue in
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
                            get: { settings.weekStartsOnSunday },
                            set: { newValue in
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

    /// Rendered directly under Weekly Spending Limit. Shows content only when the CALCULATED
    /// result belongs here — i.e. the user just edited Monthly Savings Goal, so this field's
    /// value is the derived one (`weeklyMonthlySyncSource == .monthly`) — or when neither field
    /// has ever been driven through the synced path yet (`nil`, the original Monthly-Plan-
    /// projection estimate, which has always been associated with the weekly limit). Renders
    /// nothing at all when `.weekly` (that case's calculated result belongs under Monthly
    /// Savings Goal instead — see `monthlySavingsGoalHelperRow`) — never both at once.
    @ViewBuilder
    private var weeklySpendingLimitHelperRow: some View {
        switch settings.weeklyMonthlySyncSource {
        case .weekly:
            EmptyView()
        case .monthly:
            VStack(alignment: .leading, spacing: 4) {
                Text("Weekly Spend Goal")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Text("Keeping your Weekly Spend at \(settings.weeklySpendingLimit.formatted(.currency(code: "USD").precision(.fractionLength(2)))) could help you reach your monthly savings goal.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.statusGood)
            }
        case nil:
            // Estimates what sticking to the weekly limit above would leave you with at month's
            // end. Reads only the final projected number from Monthly Plan — never income or
            // bill totals. Unchanged original behavior for a user who has never used the synced
            // fields; always associated with the weekly limit, since that's the number the
            // estimate is actually projected from.
            VStack(alignment: .leading, spacing: 4) {
                Text("Estimated Savings This Month")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)

                if !hasIncomeDataForProjection {
                    Text("Add income and bills in Monthly Plan to calculate this estimate — there isn't enough information yet.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                } else if projectedSavingsFromWeeklyLimit >= 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("You could save about")
                        PrivacyAmountView(
                            amount: projectedSavingsFromWeeklyLimit,
                            isPrivacyModeEnabled: privacyMode.isEnabled,
                            font: Theme.captionFont,
                            color: Theme.statusGood
                        )
                        Text("this month.")
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.statusGood)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("This weekly limit may overspend by")
                        PrivacyAmountView(
                            amount: abs(projectedSavingsFromWeeklyLimit),
                            isPrivacyModeEnabled: privacyMode.isEnabled,
                            font: Theme.captionFont,
                            color: Theme.statusOver
                        )
                        Text(".")
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.statusOver)
                }

                if hasIncomeDataForProjection {
                    Text("Estimated income minus planned bills and your Monthly Plan buffer, minus your Weekly Spending Limit for every week this month.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// Rendered directly under Monthly Savings Goal. Shows content only when the user just
    /// edited Weekly Spending Limit, so THIS field's value is the derived one
    /// (`weeklyMonthlySyncSource == .weekly`) — empty otherwise, so this and
    /// `weeklySpendingLimitHelperRow` never both show content for the same state.
    @ViewBuilder
    private var monthlySavingsGoalHelperRow: some View {
        if settings.weeklyMonthlySyncSource == .weekly {
            VStack(alignment: .leading, spacing: 4) {
                Text("Weekly Spend Goal")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                // `.firstTextBaseline` (not the HStack default `.center`) is what keeps the
                // amount aligned with the FIRST line of the sentence rather than vertically
                // centered against the whole (possibly two-line, on narrow widths) text block —
                // without it, a wrapped sentence pushes the amount down to visually "float"
                // between the two lines instead of reading as part of the same row.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("This amount reflects what you could save this month:")
                    PrivacyAmountView(
                        amount: settings.monthlyGoal ?? 0,
                        isPrivacyModeEnabled: privacyMode.isEnabled,
                        font: Theme.captionFont,
                        color: Theme.statusGood
                    )
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.statusGood)
            }
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
                            get: { settings.spendSenseEnabled ?? true },
                            set: { newValue in
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
                            get: { settings.requireFaceID },
                            set: { newValue in
                                if newValue {
                                    // OFF -> ON requires a successful biometric check first —
                                    // the toggle visually stays off until this completes (and
                                    // snaps back off if it fails), never flipping on speculatively.
                                    Task { await enableFaceIDIfAuthenticated() }
                                } else {
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
                            get: { settings.hideBalancesByDefault },
                            set: { newValue in
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

                    if settings.requireFaceID {
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

    // MARK: - E2. Debug (DEBUG builds only — never present in Release/TestFlight/App Store)

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Debug")

            CardBackground {
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

    @ViewBuilder
    private func labeledAmountField(title: String, amount: Binding<Decimal?>, onSubmit: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            CurrencyAmountField(
                amount: amount,
                style: .inline,
                accessibilityLabel: title
            )
            // Suppressed while a sync commit is programmatically updating the OTHER field's
            // state below (see `isSyncingCounterpartField`) — without this guard, that
            // programmatic update would itself be seen as "the user edited this field" and
            // recursively re-trigger the other save function.
            .onChange(of: amount.wrappedValue) { _, _ in
                if !isSyncingCounterpartField { onSubmit() }
            }
        }
    }

    /// Applies the canonical sync (`BudgetSettings.applyWeeklySpendingLimitCommit`) and mirrors
    /// the result into this screen's own local `monthlyGoal` `@State` (so the visible field
    /// updates immediately, without requiring the user to leave and return to Settings). The
    /// state write is wrapped in `isSyncingCounterpartField` so `labeledAmountField`'s
    /// `onChange` treats it as programmatic, never as a second user edit — this is what
    /// prevents a recursive call into `saveMonthlyGoal()`.
    private func saveWeeklyLimit() {
        guard let weeklyLimit, weeklyLimit >= 0 else { return }
        settings.applyWeeklySpendingLimitCommit(weeklyLimit)

        isSyncingCounterpartField = true
        monthlyGoal = settings.monthlyGoal
        isSyncingCounterpartField = false
    }

    /// Applies the canonical sync (`BudgetSettings.applyMonthlySavingsGoalCommit`) — same
    /// model-write-plus-visible-state-write reasoning as `saveWeeklyLimit()` above. Only
    /// mirrors into `weeklyLimit`'s local state when an actual numeric goal was committed;
    /// clearing the field to `nil` ("no monthly goal") never touches the weekly field.
    private func saveMonthlyGoal() {
        if let monthlyGoal, monthlyGoal < 0 { return }
        settings.applyMonthlySavingsGoalCommit(monthlyGoal)
        guard monthlyGoal != nil else { return }

        isSyncingCounterpartField = true
        weeklyLimit = settings.weeklySpendingLimit
        isSyncingCounterpartField = false
    }

    /// Turning "Require Face ID" ON must succeed a real biometric check first — never flips the
    /// setting speculatively. Only ever enables for the CURRENT per-user `BudgetSettings` row
    /// (this view's `settings`, already scoped to the signed-in user's isolated store), so one
    /// user enabling this can never affect another user's row.
    private func enableFaceIDIfAuthenticated() async {
        faceIDToggleErrorMessage = nil
        await biometricAuth.authenticate(reason: "Enable Face ID for SpendSmart", surfaceErrors: true)
        if biometricAuth.isUnlocked {
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

        privacyMode.isEnabled = freshSettings.hideBalancesByDefault
        biometricAuth.isFaceIDRequired = freshSettings.requireFaceID
        biometricAuth.isUnlocked = true
        weeklyLimit = freshSettings.weeklySpendingLimit
        monthlyGoal = nil
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
