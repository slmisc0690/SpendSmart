import SwiftUI

/// PHASE 9 — small "Shared" pill used on every screen in this file to make Primary-owned data
/// visually distinguishable from User B's own owned data at a glance, without a large banner or
/// new terminology (per this phase's own "minimal, existing visual language" requirement).
struct SharedBadge: View {
    var body: some View {
        Text("Shared")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Theme.accent.opacity(0.15))
            )
    }
}

/// PHASE 9 — read-only view of a Primary-shared Connected Account and its normalized
/// transactions. Deliberately has NO refresh/reconnect/disconnect/delete control of any kind —
/// those all require account OWNERSHIP (see `PlaidConnectionManager`/`RefreshPillButton`, which
/// this view never references), and this screen never operates on User B's own data at all.
struct SharedConnectedAccountDetailView: View {
    @State private var viewModel: SharedConnectedAccountViewModel

    init(account: SharedConnectedAccountDTO, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        _viewModel = State(initialValue: SharedConnectedAccountViewModel(account: account, backend: backend))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                content
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(viewModel.account.name ?? "Shared Account")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.account.name ?? "Connected Account")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                if let mask = viewModel.account.mask {
                    Text("•••• \(mask)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            SharedBadge()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xl)
        case .failed(let message):
            Text(message)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.statusOver)
                .padding(.horizontal, Theme.Spacing.lg)
        case .loaded(let transactions):
            if transactions.isEmpty {
                Text("No shared transactions yet.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    DashboardSectionHeader(title: "Shared Transactions")
                    CardBackground {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                                if index > 0 { Divider().overlay(Theme.cardStroke) }
                                SharedTransactionRow(
                                    title: transaction.merchantName ?? transaction.originalDescription,
                                    date: transaction.transactionDate,
                                    amount: transaction.amount,
                                    isPending: transaction.isPending
                                )
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
        }
    }
}

private struct SharedTransactionRow: View {
    let title: String
    let date: Date?
    let amount: Decimal
    let isPending: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: Theme.Spacing.xs) {
                    if let date {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if isPending {
                        Text("Pending")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.statusWarning)
                    }
                }
            }
            Spacer()
            AmountText(amount: amount, font: Theme.bodyFont, color: Theme.textPrimary)
        }
    }
}

/// PHASE 9 — read-only view of a Primary-shared Manual Account and its transactions. Deliberately
/// has NO edit/delete controls and NO "add transaction" affordance of any kind — those all require
/// account OWNERSHIP, and this screen never operates on User B's own data.
struct SharedManualAccountDetailView: View {
    @State private var viewModel: SharedManualAccountViewModel

    init(account: SharedManualAccountDTO, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        _viewModel = State(initialValue: SharedManualAccountViewModel(account: account, backend: backend))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                content
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(viewModel.account.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xl)
        case .failed(let message):
            Text(message)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.statusOver)
                .padding(.horizontal, Theme.Spacing.lg)
        case .loaded(nil):
            // No longer shared (or never was) — anti-enumeration means this looks identical to
            // "doesn't exist"; see this type's own header. Never falls back to any cached/owned
            // data.
            Text("This account is no longer shared with you.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Spacing.lg)
        case .loaded(let detail?):
            header(for: detail)
            if detail.transactions.isEmpty {
                Text("No shared transactions yet.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.lg)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    DashboardSectionHeader(title: "Shared Transactions")
                    CardBackground {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            ForEach(Array(detail.transactions.enumerated()), id: \.element.id) { index, transaction in
                                if index > 0 { Divider().overlay(Theme.cardStroke) }
                                SharedTransactionRow(
                                    title: transaction.note,
                                    date: transaction.transactionDate,
                                    amount: transaction.amount,
                                    isPending: transaction.isPending
                                )
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
        }
    }

    private func header(for detail: SharedManualAccountDetailDTO) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.name)
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                if let balance = detail.currentBalance {
                    AmountText(amount: balance, font: Theme.captionFont, color: Theme.textTertiary)
                }
                // PHASE B REFRESH — RE-FETCH only (see SharedManualAccountViewModel's own doc
                // comment): re-requests the same already-authorized read call this screen's own
                // `.task` already makes on appearance. Reuses `RefreshPillButton` exactly as the
                // Dashboard's owned Connected Account row does, with `isRateLimited` always false
                // — a re-fetch has no daily limit, unlike Plaid's SOURCE REFRESH.
                RefreshPillButton(isRefreshing: viewModel.isRefreshing, isRateLimited: false) {
                    Task { await viewModel.load() }
                }
            }
            Spacer()
            SharedBadge()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }
}

/// PHASE 9 — read-only view of the Primary's Monthly Plan. Shows only the raw synced values
/// (goal, buffer, income sources, recurring expenses). PHASE B (Secondary Shared Monthly Outlook
/// Parity, Option A) added a SECOND, independent load path — `outlookViewModel` — which DOES feed
/// data through `MonthlyPlanCalculator`, but only ever transient `IncomeSource`/`RecurringExpense`/
/// `MonthlyPlanSettings`/`FinanceTransaction` instances built here and discarded, never inserted
/// into any persistent local store (see `SharedMonthlyOutlookViewModel`'s own header for the full contamination
/// argument and why reusing these exact `@Model` types is safe specifically because they're never
/// persisted). No sharing/edit control of any kind is present on this screen — those require
/// account ownership.
struct SharedMonthlyPlanView: View {
    @State private var viewModel: SharedMonthlyPlanViewModel
    @State private var outlookViewModel: SharedMonthlyOutlookViewModel
    /// PHASE B — the caller-supplied, already server-authorized shared account lists (from
    /// `AccountRelatedOptionsViewModel.response`), threaded straight through to
    /// `outlookViewModel.load(...)`. This view never discovers or evaluates sharing itself.
    private let connectedAccounts: [SharedConnectedAccountDTO]
    private let manualAccounts: [SharedManualAccountDTO]

    init(
        primaryUserId: UUID,
        connectedAccounts: [SharedConnectedAccountDTO] = [],
        manualAccounts: [SharedManualAccountDTO] = [],
        backend: HouseholdSharingService = SupabaseHouseholdSharingService()
    ) {
        _viewModel = State(initialValue: SharedMonthlyPlanViewModel(primaryUserId: primaryUserId, backend: backend))
        _outlookViewModel = State(initialValue: SharedMonthlyOutlookViewModel(primaryUserId: primaryUserId, backend: backend))
        self.connectedAccounts = connectedAccounts
        self.manualAccounts = manualAccounts
    }

    /// PHASE B — identifies exactly which authorized accounts are currently feeding the outlook,
    /// so `.task(id:)` below re-runs `outlookViewModel.load(...)` whenever the Primary shares or
    /// revokes an account (this view's own `@State` would otherwise never re-trigger just because
    /// its parent passed new array values) — the same `.task(id:)`-on-account-list pattern
    /// `ExpenseListView`'s own shared-activity load already uses.
    private var outlookAccountKey: [UUID] {
        connectedAccounts.map(\.id) + manualAccounts.map(\.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                content
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Shared Monthly Plan")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .task(id: outlookAccountKey) {
            await outlookViewModel.load(connectedAccounts: connectedAccounts, manualAccounts: manualAccounts)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xl)
        case .failed(let message):
            Text(message)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.statusOver)
                .padding(.horizontal, Theme.Spacing.lg)
        case .loaded(nil):
            Text("The Monthly Plan is no longer shared with you.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Spacing.lg)
        case .loaded(let plan?):
            outlookSection
            summarySection(for: plan)
            if !plan.incomeSources.isEmpty {
                listSection(title: "Income Sources") {
                    ForEach(plan.incomeSources) { source in
                        HStack {
                            Text(source.name)
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            AmountText(amount: source.amount, font: Theme.bodyFont, color: Theme.textPrimary)
                        }
                    }
                }
            }
            if !plan.recurringExpenses.isEmpty {
                listSection(title: "Recurring Expenses") {
                    ForEach(plan.recurringExpenses) { expense in
                        HStack {
                            Text(expense.name)
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            AmountText(amount: expense.amount, font: Theme.bodyFont, color: Theme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - PHASE B — Shared Monthly Outlook (Option A: shared-accounts-only Actual spending)

    @ViewBuilder
    private var outlookSection: some View {
        switch outlookViewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.sm)
        case .failed, .loaded(nil):
            EmptyView()
        case .loaded(let summary?):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    DashboardSectionHeader(title: "Monthly Outlook")
                    Spacer()
                    // PHASE B REFRESH — RE-FETCH only, same convention as
                    // SharedManualAccountDetailView's own Refresh control.
                    RefreshPillButton(isRefreshing: outlookViewModel.isRefreshing, isRateLimited: false) {
                        Task { await outlookViewModel.load(connectedAccounts: connectedAccounts, manualAccounts: manualAccounts) }
                    }
                    .padding(.trailing, Theme.Spacing.lg)
                }
                MonthlyOutlookCard(
                    budgetedMonthlySpend: summary.flexibleSpendingAvailable,
                    actualMonthlySpend: summary.actualSpentThisMonth,
                    projectedSavings: summary.projectedMonthlySavings,
                    status: summary.projectedStatus
                )
                .padding(.horizontal, Theme.Spacing.lg)

                if !summary.weeklyComparisons.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        DashboardSectionHeader(title: "Week-by-Week")
                        VStack(spacing: Theme.Spacing.md) {
                            ForEach(summary.weeklyComparisons) { comparison in
                                WeeklyPlanComparisonRow(comparison: comparison)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
            }
        }
    }

    private func summarySection(for plan: SharedMonthlyPlanDTO) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                DashboardSectionHeader(title: "Monthly Plan")
                Spacer()
                SharedBadge()
                    .padding(.trailing, Theme.Spacing.lg)
            }
            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack {
                        Text("Savings Goal")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        AmountText(amount: plan.monthlySavingsGoal, font: Theme.bodyFont, color: Theme.textPrimary)
                    }
                    if let buffer = plan.bufferAmount {
                        HStack {
                            Text("Buffer")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            AmountText(amount: buffer, font: Theme.bodyFont, color: Theme.textPrimary)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private func listSection(title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: title)
            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md, content: rows)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

