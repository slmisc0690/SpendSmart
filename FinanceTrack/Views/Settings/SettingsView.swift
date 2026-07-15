import SwiftUI
import SwiftData
import UIKit

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

    @State private var weeklyLimit: Decimal?
    @State private var monthlyGoal: Decimal?
    @State private var isPresentingSecurityNotes = false
    @State private var isPresentingResetConfirmation = false
    @State private var isPresentingConnectedAccounts = false
    @State private var isPresentingMonthlyPlan = false
    @State private var isPresentingCategoryManagement = false
    @State private var isPresentingInsights = false
    @State private var isPresentingDataBackup = false
    @State private var isPresentingAccount = false
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
                    projectedSavingsRow
                    Divider().overlay(Theme.cardStroke)
                    labeledAmountField(title: "Monthly Goal (optional)", amount: $monthlyGoal, onSubmit: saveMonthlyGoal)
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

    /// Estimates what sticking to the weekly limit above would leave you with at month's end.
    /// Reads only the final projected number from Monthly Plan — never income or bill totals.
    @ViewBuilder
    private var projectedSavingsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Projected Monthly Savings")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)

            if !hasIncomeDataForProjection {
                Text("Add income and bills in Monthly Plan to estimate savings.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            } else if projectedSavingsFromWeeklyLimit >= 0 {
                HStack(spacing: 4) {
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
                HStack(spacing: 4) {
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
                                settings.requireFaceID = newValue
                                biometricAuth.isFaceIDRequired = newValue
                                if !newValue { biometricAuth.isUnlocked = true }
                            }
                        )
                    )

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

                    Text("SpendSmart is local-only for now. Your data stays on this device and is never sent anywhere.")
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
                    Text("All data is stored locally on this device. SpendSmart has no bank connection yet — nothing is uploaded or synced.")
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
                            Text("Manual & local-only personal finance tracker")
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
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
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
            .onChange(of: amount.wrappedValue) { _, _ in onSubmit() }
        }
    }

    private func saveWeeklyLimit() {
        guard let weeklyLimit, weeklyLimit >= 0 else { return }
        settings.weeklySpendingLimit = weeklyLimit
        settings.updatedAt = .now
    }

    private func saveMonthlyGoal() {
        guard let monthlyGoal else {
            settings.monthlyGoal = nil
            settings.updatedAt = .now
            return
        }
        guard monthlyGoal >= 0 else { return }
        settings.monthlyGoal = monthlyGoal
        settings.updatedAt = .now
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
