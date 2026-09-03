import SwiftUI
import SwiftData

struct DashboardView: View {
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var settingsList: [BudgetSettings]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]
    @Query private var savingsEntries: [SavingsEntry]
    /// TWO-LINE FAVORITES PHASE — resolves the `.checkingRegister` Favorite to a real `Account` (see
    /// `handleFavoriteSelection(_:)`); never filtered to `.checking`-typed accounts only, since
    /// Scott picks the specific account himself (Part 6 audit found no reliable way to infer "the"
    /// checking account automatically, and no reason to assume he has only one).
    @Query(sort: \Account.createdAt) private var manualAccounts: [Account]
    /// Sorted deterministically (`\.id`), matching `FavoritesConfigurationView`'s own identically-
    /// sorted `@Query` — a proven real-device bug had these two screens each resolving `.first`
    /// against an UNSORTED query, so if more than one `FavoritesSettings` row ever existed
    /// (possible before the create-on-every-access bug in that screen was fixed —  see
    /// `FavoritesSettings.resolveCanonicalRecord`'s own header), the two screens could disagree on
    /// which row was canonical. This screen NEVER creates or merges rows itself (see
    /// `favoriteDestinations`'s own header) — it only ever needs to agree with Settings on which
    /// existing row to read.
    @Query(sort: \FavoritesSettings.id) private var favoritesSettingsList:  [FavoritesSettings]
    /// Same deterministic-sort reasoning as `favoritesSettingsList` above, for the analogous
    /// Quick Stats visibility picker (`QuickStatsConfigurationView`). This screen never creates or
    /// merges rows itself — only that screen's own explicit `.onAppear`/mutation call sites do.
    @Query(sort: \QuickStatsSettings.id) private var quickStatsSettingsList: [QuickStatsSettings]
    @State private var isPresentingQuickStatsConfiguration = false

    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(PlaidConnectionManager.self) private var plaidConnection
    @Environment(\.modelContext) private var modelContext
    #if DEBUG
    /// DEBUG-BUILD-ONLY — mirrors the same key `SettingsView`'s "Developer Options > Refresh
    /// Limit" toggle writes, via `@AppStorage`'s own built-in cross-view reactivity. Compiles out
    /// entirely in Release (see `DeveloperOptions`'s own header).
    @AppStorage(DeveloperOptions.refreshLimitEnabledKey) private var refreshLimitEnabled = true
    #endif
    /// PHASE 10 — the same instance `RootView.task` already keeps refreshed for every signed-in
    /// user (see that type's own header); read-only here, purely to surface
    /// `response?.primarySharedConnectedAccounts` for an active Secondary. Never mutated from this
    /// view, and never referenced by `testDashboardStillNeverCallsPlaidDirectlyAfterRawBalanceRestore`'s
    /// own forbidden-string list, since none of Plaid's own sync/refresh types are touched here.
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel
    /// CLIENT UI PHASE — existing app-lifecycle mechanism (same as `MonthlyPlanView`'s own use)
    /// keeping the server's Monthly Savings aggregate current across a calendar-month rollover
    /// without any polling/timer. See `syncSavingsSummaryIfNeeded()`.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPresentingAddExpense = false
    @State private var isPresentingActivity = false
    @State private var isPresentingMonthlyOutlookBreakdown = false
    @State private var isPresentingExcludeTransactionsPicker = false
    /// Non-`nil` while a Favorites Bar destination's sheet is presented — drives the single
    /// `.sheet(item:)` below (`destinationView(for:)`), which routes to each destination's existing
    /// canonical view unmodified. Never a second copy of any of those screens' own logic.
    @State private var presentedFavoriteDestination: FavoriteDestinationID?
    /// TWO-LINE FAVORITES PHASE — non-`nil` while the "Checking Register" Favorite's account picker
    /// is presented, shown either because no target has been configured yet or because the
    /// previously-configured account no longer exists (see `handleFavoriteSelection(_:)`).
    @State private var isPresentingCheckingRegisterPicker = false
    /// TWO-LINE FAVORITES PHASE — the resolved target for the "Checking Register" Favorite; drives
    /// its own `.sheet(item:)` presenting `ManualAccountDetailView` directly — the exact same
    /// canonical register screen `AccountListView` itself opens, never a duplicate.
    @State private var checkingRegisterTargetAccount: Account?
    @State private var selectedWeekIndex: Int?
    /// nil means "no explicit choice yet" — `effectiveActivityTab` below falls back to
    /// `ActivityTabPresenter.defaultTab`, same pattern as `selectedWeekIndex`/`effectiveWeekIndex`.
    @State private var selectedActivityTab: ActivityTab?
    /// Keyed by `ConnectedAccountsDashboardPresenter.Display.id` — tracks which single connected
    /// account's Refresh button is mid-request, so tapping one account's button never disables or
    /// otherwise affects any other account's button.
    @State private var refreshingAccountKeys: Set<String> = []
    /// Keyed the same way — set only after a real 429 from `refresh-connected-account` (or a
    /// mirrored `remaining == 0` from a prior successful response), never guessed client-side from
    /// a fresh calendar day. The server remains authoritative regardless: a stale-enabled button
    /// simply gets a graceful 429 on tap, handled the same way as any other failed refresh.
    @State private var rateLimitedAccountKeys: Set<String> = []

    /// CLIENT CORRECTION — TARGET ARCHITECTURE: a Secondary's This Week, Monthly Spending Quick
    /// Stat, Monthly Outlook, AND Week-by-Week all derive from this ONE authoritative shared
    /// aggregate (never four independent fetches, never a duplicated calculation) — the Primary's
    /// own already-computed `dashboard_summary` row, never a second, independent reconstruction
    /// from raw shared transactions. Owned here (not by a leaf subview) so every section that needs
    /// it reads the same in-flight/loaded/failed state. Fully transient — never written to
    /// SwiftData, never holds a stale previous-Primary's data (see `secondaryDashboardSummaryLoadKey`'s
    /// own doc comment for why a role/primary change always produces a fresh instance rather than
    /// reusing a stale one). `SharedMonthlyOutlookViewModel` (the raw-reconstruction path this
    /// replaced for Dashboard purposes) remains in use elsewhere, unmodified, by the separate
    /// `SharedMonthlyPlanView` Settings screen only.
    @State private var dashboardSummaryViewModel: SharedDashboardSummaryViewModel?

    private var settings: BudgetSettings? { settingsList.first }

    /// The Favorites Bar's own content: valid (non-stale) AND currently-eligible favorites, in the
    /// user's saved order. Deliberately a non-mutating, filtered PROJECTION — merely rendering the
    /// Dashboard must never itself write to `FavoritesSettings` (that would be exactly the kind of
    /// passive-render side effect this project's own sign-out safety rules forbid) — see
    /// `FavoritesConfigurationView.onAppear`'s explicit, user-visible-context
    /// `reconcileEligibility` call for where stale/ineligible entries actually get pruned from
    /// storage. An empty result here is what hides the bar entirely — see `favoritesBarSection`.
    private var favoriteDestinations: [FavoriteDestinationID] {
        guard let favorites = favoritesSettingsList.first else { return [] }
        return favorites.validDestinationIDs.filter {
            FavoriteDestinationID.isEligible($0, accountRelatedOptionsVisibility: accountRelatedOptionsViewModel.visibility)
        }
    }

    /// TWO-LINE FAVORITES PHASE — every non-archived Manual Account, the candidate list for the
    /// "Checking Register" Favorite's account picker. Deliberately not filtered to `.checking`-typed
    /// accounts (Part 6 audit: no reliable signal exists for "the" checking account, and Scott may
    /// have more than one) — he picks the specific account himself.
    private var checkingRegisterCandidateAccounts: [Account] {
        manualAccounts.filter { !$0.isArchived }
    }

    /// TWO-LINE FAVORITES PHASE — the ONE place tapping a Favorite is handled, so `.checkingRegister`
    /// (which needs a real `Account` resolved first, unlike every other stateless destination) can
    /// be special-cased here rather than inside `FavoritesBarView`/`favoriteDestinationView(for:)`.
    /// A missing/unconfigured/deleted target all safely fall through to the SAME picker — there is
    /// no separate "broken favorite" error state, just a re-prompt.
    private func handleFavoriteSelection(_ destination: FavoriteDestinationID) {
        guard destination == .checkingRegister else {
            presentedFavoriteDestination = destination
            return
        }
        if let targetID = favoritesSettingsList.first?.checkingRegisterAccountID,
           let account = checkingRegisterCandidateAccounts.first(where: { $0.id == targetID }) {
            checkingRegisterTargetAccount = account
        } else {
            isPresentingCheckingRegisterPicker = true
        }
    }

    /// TWO-LINE FAVORITES PHASE — the one explicit, user-visible-context mutation of
    /// `FavoritesSettings` this screen ever performs (see `favoriteDestinations`'s own header for
    /// why the Dashboard otherwise never writes to it): choosing an account from
    /// `CheckingRegisterAccountPickerView` is a deliberate tap, not a passive render side effect,
    /// exactly like `FavoritesConfigurationView`'s own mutation call sites — so it goes through the
    /// same canonical `resolveCanonicalRecord`.
    private func selectCheckingRegisterAccount(_ account: Account) {
        let record = FavoritesSettings.resolveCanonicalRecord(existing: favoritesSettingsList, in: modelContext)
        record.setCheckingRegisterAccount(account.id)
        try? modelContext.save()
        isPresentingCheckingRegisterPicker = false
        checkingRegisterTargetAccount = account
    }

    /// MONTH-ALIGNED FOUR-WEEK CORRECTION — This Week is always one of exactly 4 month-aligned
    /// blocks (Week 1 starting on the 1st of the month, weeks 1–3 seven days each, week 4 the
    /// remainder), never a Sunday/Monday calendar week — see
    /// `DateRangeHelper.fourWeekBlocks(in:)`'s own header for why (no cross-month bleed into
    /// Week-by-Week's totals). `BudgetSettings.weekStartsOnSunday` is intentionally no longer
    /// read here — it remains meaningful elsewhere (Insights/SpendSense/Scenario/Monthly
    /// Summary), just not for This Week/Week-by-Week/Monthly Outlook anymore.
    private var weekInterval: DateInterval {
        DateRangeHelper.currentFourWeekBlock()
    }

    private var monthInterval: DateInterval {
        DateRangeHelper.currentMonthRange()
    }

    private var includePending: Bool {
        settings?.includePendingTransactions ?? true
    }

    /// AUTO-TRACKED CONNECTED-ACCOUNT BUDGETING — the user's current selection under "Auto
    /// Calculate Weekly/Monthly Based on Transactions for:", read fresh from `settings` on every
    /// access (a plain `Set` computed property, not a stored `@State` snapshot — unlike this
    /// view's `weeklyLimit`/etc-style values, this is read-only and never written from this view,
    /// so it carries none of the sign-out live-`Binding`-getter risk those exist to avoid).
    private var autoTrackedAccountIds: Set<String> {
        Set(settings?.autoCalculateConnectedAccountIds ?? [])
    }

    /// EXCLUDE TRANSACTIONS — the user's current selection under "Budget Exclusions," read fresh
    /// from `settings` on every access (same read-only, non-`@State` pattern as
    /// `autoTrackedAccountIds` immediately above). Gated on `excludeTransactionsEnabled`: when the
    /// master toggle is off, this always returns empty regardless of what
    /// `excludedTransactionIDs` itself still holds, so turning the feature off is a true "as if it
    /// never existed" state for every budgeting calculation below.
    private var excludedTransactionIDs: Set<UUID> {
        guard settings?.excludeTransactionsEnabled ?? false else { return [] }
        return Set(settings?.excludedTransactionIDs ?? [])
    }

    private var spentThisWeek: Decimal {
        BudgetCalculator.weeklyActualSpending(transactions, in: weekInterval, includePending: includePending, autoTrackedAccountIds: autoTrackedAccountIds, excludedTransactionIDs: excludedTransactionIDs)
    }

    private var spentThisMonth: Decimal {
        BudgetCalculator.monthlyActualSpending(transactions, in: monthInterval, includePending: includePending, autoTrackedAccountIds: autoTrackedAccountIds, excludedTransactionIDs: excludedTransactionIDs)
    }

    /// URGENT REGRESSION FIX — computed live via the same shared `effectivePlannedWeeklySpending`
    /// authority every other consumer uses (`plannedWeeklySpendingForOutlook`, below), never
    /// `settings?.weeklySpendingLimit` directly. That stored field is only a snapshot, refreshed
    /// solely when Monthly Plan/Settings happen to run their own sync — reading it here could show
    /// a stale (or default-zero) number on a Dashboard opened before either of those screens ever
    /// ran. `nil` (no custom override) means Automatic mode, never "unconfigured": Automatic
    /// mode's own value (Flexible Spending Available ÷ 4) is still a real, positive weekly amount
    /// whenever Flexible Spending Available is positive — it is never $0 merely because no custom
    /// override was ever entered.
    private var weeklyLimit: Decimal {
        plannedWeeklySpendingForOutlook
    }

    private var status: SpendingStatus {
        BudgetCalculator.status(
            spent: spentThisWeek,
            limit: weeklyLimit,
            warningThreshold: settings?.warningThreshold ?? 0.70
        )
    }

    private var savedThisMonth: Decimal {
        SavingsCalculator.savedThisMonth(savingsEntries, in: monthInterval)
    }

    private var totalSavingsToDate: Decimal {
        SavingsCalculator.totalSavingsToDate(savingsEntries)
    }

    /// SAVED-TRACKING — the "Saved" Quick Stat's own value: the current month's total of
    /// `.transferToSavings` Manual Account entries, entirely independent of `savedThisMonth` above
    /// (which totals manually-logged `SavingsEntry` rows instead).
    private var savedViaTransferThisMonth: Decimal {
        SavedViaTransferCalculator.savedThisMonth(transactions, in: monthInterval)
    }

    /// QUICK STATS CUSTOMIZATION — the single source of truth for which Quick Stats show, read
    /// from `QuickStatsConfigurationView`'s own `QuickStatsSettings` record. This supersedes the
    /// old dedicated `BudgetSettings` per-toggle Settings row (removed in favor of this one general
    /// picker); the superseded `BudgetSettings` field is left in place, unused, rather than
    /// removed, matching this schema's own established pattern for a prior superseded toggle.
    /// Read-only here — this screen never creates or merges `QuickStatsSettings` rows itself, only
    /// `QuickStatsConfigurationView`'s own explicit call sites do.
    private func isQuickStatShown(_ stat: QuickStatID) -> Bool {
        !(quickStatsSettingsList.first?.isHidden(stat) ?? false)
    }

    private var showSavedThisMonthQuickStat: Bool {
        isQuickStatShown(.savedThisMonth)
    }

    /// LOCKED PRODUCT RULE — a Secondary never uses their own local `SavingsEntry` records to
    /// populate a savings Quick Stat; they see a separate, server-backed shared Quick Stat instead
    /// (see `SharedSavedThisMonthQuickStatCard`), gated by `Share Monthly Savings`, not by this
    /// device's own `showSavedThisMonthQuickStat` preference.
    private var isSecondary: Bool {
        accountRelatedOptionsViewModel.response?.role == .secondary
    }

    /// CLIENT UI PHASE — reconciles the server's Monthly Savings aggregate whenever this Primary's
    /// Dashboard loads/returns to the foreground. Best-effort, no-op for a Secondary (who has no
    /// own summary to push) — see `SavingsSummarySyncService`'s own header.
    ///
    /// CRASH FIX — two independent `EXC_BAD_ACCESS` risks on `@Query`-backed properties
    /// (`savingsEntries` here), both handled before either is ever touched:
    /// (1) TEARDOWN — `.task` cancellation is cooperative: when a sign-out/user-switch tears down
    /// this view (and its `@Query`-backed `ModelContainer`) while this task is still suspended on
    /// `await`, SwiftUI marks the task cancelled but does not stop it from resuming. The
    /// `Task.isCancelled` guard below is the same idiom already used for this exact class of
    /// teardown race elsewhere in this app — see `AutoBackupManager`/`ManualDataCloudSyncManager`/
    /// `MonthlyPlanCloudSyncManager`.
    /// (2) FRESH-ATTACH — on a fresh sign-in, `RootView` (and everything under it, including this
    /// view) mounts under a brand-new `.id(userId)` identity with a just-attached
    /// `.modelContainer(container)`; a `.task` can start running in the very same runloop turn,
    /// before SwiftData has finished wiring this view's `@Query` observation machinery to that new
    /// container — a real-device-confirmed crash, distinct from (1) since `Task.isCancelled` is
    /// still `false` here (nothing has torn down; the container is simply not fully attached yet).
    /// `Task.yield()` defers to the next main-actor turn — the same "let SwiftUI's already-
    /// triggered pass finish first" idiom `FinanceTrackApp`'s own deferred `userDataStore.detach()`
    /// call uses — giving that attachment a turn to complete before any `@Query` read is attempted.
    private func syncSavingsSummaryIfNeeded() async {
        guard !Task.isCancelled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard !isSecondary else { return }
        await SavingsSummarySyncService.sync(entries: savingsEntries)
    }

    /// WEBHOOK-DRIVEN BACKGROUND TRANSACTION SYNC — PULL-ONLY, PHASE 4: brings in whatever the
    /// server-side Item-sync engine (webhook-triggered, or a prior manual refresh) has already
    /// reconciled, on every Dashboard appear/foreground-return, WITHOUT ever asking Plaid to
    /// contact an institution itself. This is the ONLY automatic trigger for
    /// `PlaidConnectionManager.pullSyncedTransactions` in the entire app — deliberately calls that
    /// method and NEVER `syncAndImportTransactions`/`triggerItemTransactionSync`, so opening or
    /// foregrounding SpendSmart can never itself cause a real Plaid API call (confirmed by this
    /// project's own Phase 0 cost audit as the specific behavior to avoid). Not gated on
    /// `isSecondary` — Connected Accounts are per-owning-user, not a Primary-only shared aggregate
    /// like the sibling `syncSavingsSummaryIfNeeded`/`syncDashboardSummaryIfNeeded` above, so a
    /// Secondary's own Connected Accounts benefit from this exactly the same way a Primary's do.
    /// A connection already flagged `requiresReauth` is skipped — pulling would only ever return a
    /// 409 sync-transactions already treats as a no-op-worthy signal elsewhere, so skipping avoids
    /// a wasted round-trip. Best-effort per connection: one connection's failure (network, a
    /// transient decode error) never blocks any other connection's own pull, and none of this ever
    /// surfaces a raw error to the user — the exact same "silent, retried next time" posture this
    /// file's other `...IfNeeded` methods already use.
    private func pullSyncedTransactionsForConnectedAccountsIfNeeded() async {
        guard !Task.isCancelled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        for connection in plaidConnection.connections where !connection.requiresReauth {
            guard !Task.isCancelled else { return }
            do {
                try await plaidConnection.pullSyncedTransactions(connectionId: connection.id, context: modelContext)
            } catch {
                #if DEBUG
                print("[DashboardView] pullSyncedTransactions failed for connection \(connection.id) (non-fatal): \(error)")
                #endif
            }
        }
    }

    /// SAVED VIA TRANSFER SHARING — reconciles the server's Saved-via-Transfer aggregate whenever
    /// this Primary's Dashboard loads/returns to the foreground, mirroring
    /// `syncSavingsSummaryIfNeeded`'s own trigger/no-op-for-Secondary/teardown-safety posture
    /// exactly (see that method's own header for the two crash-fix races this same guard sequence
    /// protects against). Computed from the FULL local `transactions` collection —
    /// `SavedViaTransferCalculator` itself filters to `.transferToSavings` entries only.
    private func syncSavedViaTransferSummaryIfNeeded() async {
        guard !Task.isCancelled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard !isSecondary else { return }
        await SavedViaTransferSummarySyncService.sync(transactions: transactions)
    }

    /// USER B DASHBOARD PARITY — pushes this Primary's own authoritative Dashboard aggregate
    /// whenever the Dashboard loads/returns to the foreground, mirroring
    /// `syncSavingsSummaryIfNeeded`'s own trigger/no-op-for-Secondary posture exactly. Best-effort:
    /// a failed push is silently retried on the next trigger (see
    /// `PrimaryDashboardSummarySyncService`'s own header). Computed from the FULL local
    /// `transactions` collection — the exact same set `monthlyPlanSummary` above sums over — never
    /// a second, per-account-filtered subset (see that service's own header for why: the single
    /// `monthlyPlan` sharing permission already gates the entire aggregate). `authoritativeWeeklyLimit`
    /// passes this same view's own `weeklyLimit` (the value actually displayed above) through
    /// verbatim, so the uploaded `weekly_spending_limit` can never diverge from what this device is
    /// currently showing — the sync service itself no longer recomputes it independently.
    ///
    /// MONTHLY OUTLOOK + SCENARIO PERIOD-CASH-FLOW CORRECTION — `monthlyOutlookBudgeted` now
    /// passes `plannedMonthlySpendingForOutlook` (Planned Weekly Spending × 4, this view's own
    /// authoritative planning value — the same figure `monthlyOutlookSection` displays as
    /// "Budgeted"), never `BudgetSettings.monthlyGoal` (which mirrors the Savings Goal, not
    /// planned spending — that was the root cause of the prior $0.00 Budgeted defect when the
    /// Savings Goal was $0). `currentWeekIndex` passes
    /// `currentWeekComparisonIndexForUpload` — the SAME `weeklyComparisons.firstIndex(where:
    /// { $0.weekInterval.contains(.now) })` logic `currentWeekComparisonIndex`/`effectiveWeekIndex`
    /// use for display, but WITHOUT their `?? 0`/manual-selection fallbacks, so a month with no
    /// week actually containing today uploads `nil` (→ `NULL` current-plan-week fields) rather than
    /// a guessed Week 1.
    private func syncDashboardSummaryIfNeeded() async {
        guard !Task.isCancelled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard !isSecondary else { return }
        await PrimaryDashboardSummarySyncService.sync(
            transactions: transactions,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: monthlyPlanSettingsList.first,
            authoritativeWeeklyLimit: weeklyLimit,
            monthlyOutlookBudgeted: plannedMonthlySpendingForOutlook,
            currentWeekIndex: currentWeekComparisonIndexForUpload,
            weekInterval: weekInterval,
            monthInterval: monthInterval,
            weekStartsOnSunday: settings?.weekStartsOnSunday ?? true,
            includePending: includePending,
            warningThreshold: settings?.warningThreshold ?? 0.70,
            autoTrackedAccountIds: autoTrackedAccountIds,
            excludedTransactionIDs: excludedTransactionIDs
        )
    }

    /// Every selectable Recent Activity source — one per connected Plaid account actually
    /// referenced by a locally stored transaction, plus Manual Transactions. See
    /// `ActivityTabPresenter` for why this reads only persisted state, never Plaid.
    private var activityTabs: [ActivityTab] {
        ActivityTabPresenter.tabs(transactions: transactions, connections: plaidConnection.connections)
    }

    /// Same fallback pattern as `effectiveWeekIndex` below: `selectedActivityTab` is nil until the
    /// user explicitly picks one, and falls back to `ActivityTabPresenter.defaultTab` — which also
    /// covers the case where a previously selected connected account was since disconnected.
    private var effectiveActivityTab: ActivityTab {
        if let selectedActivityTab, activityTabs.contains(selectedActivityTab) { return selectedActivityTab }
        return ActivityTabPresenter.defaultTab(tabs: activityTabs)
    }

    /// The single source of truth for what Recent Activity shows — scoped to `effectiveActivityTab`
    /// FIRST, then opted-out Manual Accounts are filtered out, then the 5-item limit is applied to
    /// what remains, so a hidden account's transactions never silently consume a slot an eligible
    /// transaction should have gotten. `transactions` is already date-descending (see the `@Query`
    /// sort above), so filtering preserves that order.
    private var recentTransactions: [FinanceTransaction] {
        Array(
            ActivityTabPresenter.transactions(for: effectiveActivityTab, in: transactions)
                .filter(isEligibleForRecentActivity)
                .prefix(5)
        )
    }

    /// A transaction with no account, or one belonging to a Plaid-linked account (no opt-out
    /// concept exists for those today), is always eligible — this only ever excludes a Manual
    /// Account's transactions, and only when that account's own `showsInRecentActivity` is
    /// explicitly `false`.
    private func isEligibleForRecentActivity(_ transaction: FinanceTransaction) -> Bool {
        transaction.account?.showsInRecentActivity ?? true
    }

    /// Everything needed for the Monthly Outlook and Week-by-Week sections, computed once via
    /// the shared `MonthlyPlanCalculator` — never reimplemented here. Only status-level fields
    /// (projected savings, status, recommended limit, week-by-week comparisons) are ever read
    /// from this on the Dashboard; income/bill totals and lists stay private to Settings >
    /// Monthly Plan.
    private var monthlyPlanSummary: MonthlyPlanCalculator.Summary {
        MonthlyPlanCalculator.summary(
            month: monthInterval,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: monthlyPlanSettingsList.first,
            // CRASH FIX — must NOT be `weeklyLimit`: `weeklyLimit` now equals
            // `plannedWeeklySpendingForOutlook`, which reads `monthlyPlanSummary.
            // flexibleSpendingAvailable` — passing `weeklyLimit` here created a direct evaluation
            // cycle (`weeklyLimit` → `plannedWeeklySpendingForOutlook` → `monthlyPlanSummary` →
            // `weeklyLimit` → ...), an infinite recursion that stack-overflows on every access,
            // surfacing as a deterministic `EXC_BAD_ACCESS` (real-device-confirmed) wherever the
            // guard page happened to be hit — not a timing/teardown race, since this recursion is
            // pure synchronous computed-property evaluation with no `await` anywhere in the chain.
            // The raw stored field is exactly what `weeklyLimit` itself evaluated to before it was
            // changed to route through the live formula, so this restores the same non-circular
            // input `Summary`'s own fields (other than `flexibleSpendingAvailable`, which never
            // depended on this parameter in the first place) always received.
            weeklyBudgetLimit: settings?.weeklySpendingLimit ?? 0,
            transactions: transactions,
            weekInterval: weekInterval,
            weekStartsOnSunday: settings?.weekStartsOnSunday ?? true,
            includePending: includePending,
            warningThreshold: settings?.warningThreshold ?? 0.70,
            autoTrackedAccountIds: autoTrackedAccountIds,
            excludedTransactionIDs: excludedTransactionIDs
        )
    }

    /// The canonical running monthly balance: money after bills, minus the Monthly Savings Goal
    /// and optional Buffer, minus actual qualifying spending so far this month — built from
    /// `monthlyPlanSummary`'s own already-computed fields (never a duplicated income/bills/
    /// spending calculation) via `MonthlyPlanCalculator.moneyAfterBills`/`monthlySpendingBudget`/
    /// `monthlySpendRemaining`. This is the same authoritative result that drives
    /// `BudgetSettings.weeklySpendingLimit` (see `MonthlyPlanView.applyBudgetAutoCalculateIfNeeded`).
    // MARK: - MONTHLY OUTLOOK + SCENARIO PERIOD-CASH-FLOW CORRECTION — Planned Weekly Spending
    // planning path (Part 1/3/4). ONE SHARED CALCULATION PATH — every value below routes through
    // `MonthlyPlanCalculator`'s planning functions applied to `monthlyPlanSummary` (itself
    // unchanged), the exact same public functions `MonthlyPlanView`'s Planning section and
    // `PrimaryDashboardSummarySyncService.sync` use — never a second, competing formula written
    // here. `monthlyPlanSummary.projectedMonthlySavings` (the legacy actual-spending formula)
    // remains untouched and unused by this section.

    /// QUICK STATS REDESIGN — whether a REAL Custom Planned Weekly Spending override is currently
    /// in effect, matching `MonthlyPlanCalculator.effectivePlannedWeeklySpending`'s own
    /// `override > 0` condition exactly (never a bare `!= nil` check), same rule
    /// `MonthlyPlanView.isPlannedWeeklySpendingCustom` uses.
    private var isPlannedWeeklySpendingCustomForOutlook: Bool {
        (monthlyPlanSettingsList.first?.plannedWeeklySpendingOverride ?? 0) > 0
    }

    // MARK: - FIXED BILLS FORMULA UNIFICATION
    //
    // `monthlyPlanSummary.flexibleSpendingAvailable`/`estimatedMonthlyFixedExpenses` route through
    // `MonthlyPlanCalculator.estimatedMonthlyFixedExpenses`'s legacy per-frequency-converting
    // formula (Weekly ×52÷12, Quarterly ÷3, Yearly ÷12, ...) — the SAME formula
    // `FixedBillsReconciliation`/Scenario/SpendSense/the cloud sync payload still intentionally
    // use, so none of those are touched here. `MonthlyPlanView`'s own "corrected" figures
    // (`correctedFixedBillsTotal`/`correctedFlexibleSpendingAvailable`) instead use
    // `FixedBillsTimingFilter.displayedTotal` — a plain raw sum of each bill's `amount`, no
    // frequency conversion — which is what every bill's own row on screen (Fixed Bills list,
    // Scenario Bill Groups) already displays. For a Monthly-frequency bill the two formulas are
    // identical; they only diverge for a Weekly/Quarterly/Yearly bill, which is exactly what
    // produced a real, user-reported gap between Monthly Plan's own Flexible Spending Available
    // and the Dashboard's Quick Stats/Monthly Outlook for the same figure. Mirrored here (Dashboard
    // only) rather than changing the shared `estimatedMonthlyFixedExpenses` function itself, so
    // this stays scoped to the two screens that actually need to agree, without touching
    // Scenario/SpendSense/backend-sync's own established use of the legacy formula.
    private var activeRecurringExpensesForOutlook: [RecurringExpense] {
        recurringExpenses.filter { $0.isActive }
    }

    private var correctedFixedBillsTotalForOutlook: Decimal {
        FixedBillsTimingFilter.displayedTotal(for: activeRecurringExpensesForOutlook)
    }

    /// income − corrected Fixed Bills − savings goal − buffer, BEFORE Bill Payment Variance —
    /// same shape as `MonthlyPlanView.correctedFlexibleSpendingAvailable`.
    private var correctedPlannedFlexibleSpendingAvailableForOutlook: Decimal {
        monthlyPlanSummary.estimatedMonthlyIncome - correctedFixedBillsTotalForOutlook - monthlyPlanSummary.monthlySavingsGoal - monthlyPlanSummary.bufferAmount
    }

    /// The corrected baseline PLUS Bill Payment Variance (planned vs. actual, per bill actually
    /// paid this month — see `MonthlyPlanCalculator.billPaymentVariance`'s own header) — the ONE
    /// figure every Quick Stat/Monthly Outlook value below now reads instead of
    /// `monthlyPlanSummary.flexibleSpendingAvailable` directly. Nothing paid differently than
    /// planned this month ⇒ this equals `correctedPlannedFlexibleSpendingAvailableForOutlook`
    /// exactly, matching Monthly Plan's own displayed figure.
    private var correctedFlexibleSpendingAvailableForOutlook: Decimal {
        correctedPlannedFlexibleSpendingAvailableForOutlook + MonthlyPlanCalculator.billPaymentVariance(
            recurringExpenses: recurringExpenses,
            transactions: transactions,
            in: monthInterval
        )
    }

    private var plannedWeeklySpendingForOutlook: Decimal {
        MonthlyPlanCalculator.effectivePlannedWeeklySpending(
            override: monthlyPlanSettingsList.first?.plannedWeeklySpendingOverride,
            flexibleSpendingAvailable: correctedFlexibleSpendingAvailableForOutlook
        )
    }

    private var plannedMonthlySpendingForOutlook: Decimal {
        MonthlyPlanCalculator.plannedMonthlySpending(plannedWeeklySpending: plannedWeeklySpendingForOutlook)
    }

    /// QUICK STATS REDESIGN — Flexible Spending Available minus Planned Monthly Spending
    /// (`MonthlyPlanCalculator.additionalPlannedSavings`), extracted into its own named property
    /// (previously computed inline only within `projectedMonthlySavingsForOutlook` below) so the
    /// new "Projected Available After Spend" Quick Stat can display the SAME already-computed
    /// value that feeds `projectedMonthlySavingsForOutlook`, never a second calculation.
    private var projectedAvailableAfterSpendForOutlook: Decimal {
        MonthlyPlanCalculator.additionalPlannedSavings(
            flexibleSpendingAvailable: correctedFlexibleSpendingAvailableForOutlook,
            plannedMonthlySpending: plannedMonthlySpendingForOutlook
        )
    }

    private var projectedMonthlySavingsForOutlook: Decimal {
        MonthlyPlanCalculator.projectedSavingsFromPlannedSpending(
            monthlySavingsGoal: monthlyPlanSummary.monthlySavingsGoal,
            additionalPlannedSavings: projectedAvailableAfterSpendForOutlook
        )
    }

    private var projectedStatusForOutlook: SpendingStatus {
        MonthlyPlanCalculator.monthlyPlanStatus(projectedSavings: projectedMonthlySavingsForOutlook, savingsGoal: monthlyPlanSummary.monthlySavingsGoal)
    }

    private var monthlySpendRemaining: Decimal {
        // FIXED BILLS FORMULA UNIFICATION — `max(0, correctedFlexibleSpendingAvailableForOutlook)`
        // is exactly `monthlySpendingBudget`'s own shape (income − corrected Fixed Bills − savings
        // goal − buffer, clamped at 0) PLUS Bill Payment Variance, which the old
        // `moneyAfterBills`/`monthlySpendingBudget` pipeline never applied at all — see this
        // section's own header above.
        let spendingBudget = max(0, correctedFlexibleSpendingAvailableForOutlook)
        return MonthlyPlanCalculator.monthlySpendRemaining(
            monthlySpendingBudget: spendingBudget,
            actualMonthlySpending: monthlyPlanSummary.actualSpentThisMonth
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header
                    favoritesBarSection

                    weeklyCardSection
                    quickStatsSection
                    connectedAccountsSection
                    budgetExclusionsSection
                    monthlyOutlookAndWeekByWeekSection
                    recentActivitySection
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: favoriteDestinations)
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $isPresentingAddExpense) {
                AddExpenseView()
            }
            .sheet(isPresented: $isPresentingActivity) {
                // Reuses the existing full Activity screen (ExpenseListView) rather than building
                // a second one — presented modally, matching every other Dashboard destination in
                // this file, and opened with whatever tab is currently selected here.
                ExpenseListView(initialTab: effectiveActivityTab)
            }
            .sheet(isPresented: $isPresentingMonthlyOutlookBreakdown) {
                MonthlyOutlookBreakdownView(
                    weeks: monthlyOutlookBreakdown,
                    connections: plaidConnection.connections,
                    isPrivacyModeEnabled: privacyMode.isEnabled
                )
            }
            .sheet(item: $presentedFavoriteDestination) { destination in
                favoriteDestinationView(for: destination)
            }
            .sheet(isPresented: $isPresentingCheckingRegisterPicker) {
                CheckingRegisterAccountPickerView(accounts: checkingRegisterCandidateAccounts) { account in
                    selectCheckingRegisterAccount(account)
                }
            }
            .sheet(item: $checkingRegisterTargetAccount) { account in
                // TWO-LINE FAVORITES PHASE — the exact same canonical register destination
                // `AccountListView` itself opens for this account, never a duplicate.
                ManualAccountDetailView(account: account)
            }
            .sheet(isPresented: $isPresentingExcludeTransactionsPicker) {
                ExcludeTransactionsView()
            }
            .task {
                await syncSavingsSummaryIfNeeded()
            }
            .task {
                await syncDashboardSummaryIfNeeded()
            }
            .task {
                await syncSavedViaTransferSummaryIfNeeded()
            }
            .task {
                await pullSyncedTransactionsForConnectedAccountsIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await syncSavingsSummaryIfNeeded() }
                    Task { await syncDashboardSummaryIfNeeded() }
                    Task { await syncSavedViaTransferSummaryIfNeeded() }
                    Task { await pullSyncedTransactionsForConnectedAccountsIfNeeded() }
                    // SHARED USER REFRESH PARITY — re-pulls the Secondary's own shared Dashboard
                    // aggregate on foreground-return, same trigger the Primary's own push above
                    // already uses. A no-op for a Primary (`secondaryOutlookPrimaryUserId` is nil,
                    // same as `loadDashboardSummaryIfNeeded`'s own existing `.task(id:)` call
                    // already handles) — never touches what a Primary's own Dashboard displays.
                    Task { await loadDashboardSummaryIfNeeded() }
                }
            }
            // CLIENT CORRECTION — `RootView.task`'s own single, fire-and-forget
            // `accountRelatedOptionsViewModel.refresh()` call is the only launch-time trigger
            // anywhere in the app; if it fails (real-device network hiccup, cold-start token not
            // yet warm), nothing previously retried it for the rest of the session short of a
            // background/foreground cycle, silently leaving every Secondary-gated Dashboard
            // section (`accountRelatedOptionsLoaded`) stuck showing nothing. `refresh()` itself is
            // safe to call redundantly — it coalesces onto an already-in-flight request and never
            // re-shows a loading placeholder once `.loaded` (see that view model's own header) —
            // so giving Dashboard its own independent chance costs nothing extra on the happy path
            // and closes the single-point-of-failure on the unhappy one. No polling/timer: exactly
            // one call, tied to this view's own appearance, same as every other `.task` here.
            .task {
                await accountRelatedOptionsViewModel.refresh()
            }
            .task(id: secondaryDashboardSummaryLoadKey) {
                await loadDashboardSummaryIfNeeded()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    /// LOCKED PLACEMENT — Settings stays in the upper-right; "+ Add Expense" is now a SMALLER
    /// icon-only control (reusing `HeaderIconButton`, same as Settings/Privacy) stacked directly
    /// beneath the Settings/Privacy row, rather than the old full-width `PremiumActionButton` row.
    /// Its own trigger/destination is completely unchanged — still `isPresentingAddExpense` /
    /// `AddExpenseView()`, only the control that sets it is smaller. Freed-up width is what lets
    /// `favoritesBarSection` (rendered directly below, in its own centered full-content-width row)
    /// occupy the Dashboard's larger central horizontal area.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(DateRangeHelper.monthDisplayText(for: monthInterval))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                // PHASE 2B VISUAL ASSETS — the rendered "SpendSmart" text title is replaced by
                // Scott's supplied title.png artwork (`SpendSmartTitle` asset, byte-identical copy
                // — see this asset's own Contents.json `template-rendering-intent: original`).
                // `.scaledToFit()` preserves the source image's own aspect ratio, never stretched.
                // `.accessibilityLabel` keeps VoiceOver announcing "SpendSmart", matching the exact
                // spoken text before this change.
                //
                // PHASE 2B VISUAL FIX — raised from the initial 32pt (which read as too small/
                // timid on a physical device) to 42pt so the title reads as the app's main title
                // and is clearly, visually larger than the "Your spending at a glance" subtitle
                // below it (`Theme.captionFont`, ~12pt) — confirmed via pixel-content-bounds
                // analysis that `SpendSmartTitle`'s artwork already fills ~97% of its own canvas
                // height (negligible internal padding), so this frame height maps almost directly
                // to visible ink height, landing at the top of the requested "34–42pt text-title
                // presence" target for maximum title dominance.
                Image("SpendSmartTitle")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(height: 42)
                    .accessibilityLabel("SpendSmart")
                Text("Your spending at a glance")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    HeaderIconButton(systemName: privacyMode.isEnabled ? "eye.slash.fill" : "eye.fill") {
                        privacyMode.toggle()
                    }
                }
                HStack(spacing: Theme.Spacing.xs) {
                    // Purely visual — the button below still carries the ONE spoken
                    // "Add Expense" accessibility label, so this text is hidden from VoiceOver
                    // rather than combined with it (avoids a duplicated announcement). The `+`
                    // button's own trigger/destination is completely unchanged.
                    Text("Add Expense")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                    HeaderIconButton(systemName: "plus") {
                        isPresentingAddExpense = true
                    }
                    .accessibilityLabel("Add Expense")
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Favorites Bar

    /// LOCKED VISIBILITY — hidden entirely at zero favorites: no empty heading, no empty capsule,
    /// no reserved blank space (an `EmptyView()` branch contributes nothing to the surrounding
    /// `VStack`'s layout, so `weeklyCardSection` etc. simply lay out as if this row weren't there
    /// at all). The "Favorites" heading and the capsule are DELIBERATELY inside the SAME
    /// `if !favoriteDestinations.isEmpty` branch — one condition, never two — so neither can ever
    /// appear or disappear independently of the other. Appears the moment `favoriteDestinations`
    /// goes from empty to non-empty, and disappears the moment it goes back to empty — both
    /// together, via the same `.transition` (applied to the whole `VStack`, heading included),
    /// driven by `favoriteDestinations` itself changing (see the `.animation(value:)` on this
    /// view's outer `VStack` in `body`). `Reduce Motion` collapses the transition to a plain,
    /// motion-free cross-fade.
    ///
    /// CENTERED HEADING — deliberately NOT `DashboardSectionHeader` (the leading-aligned
    /// `HStack { Text; Spacer }` every OTHER Dashboard section uses — `quickStatsSection`/
    /// `connectedAccountsSection` keep using it, untouched). This is the one section whose heading
    /// must sit centered directly above its own content, matching `FavoritesBarView`'s own capsule
    /// (which centers itself — content-sized, never full-width — within the same available width).
    /// Same font/color as `DashboardSectionHeader` (`Theme.headlineFont`/`Theme.textPrimary`), same
    /// `Theme.Spacing.lg` horizontal padding as the capsule directly below it — centering both
    /// within the identical available width is what keeps the heading's center aligned with the
    /// capsule's own center at every favorite count (1 through the 6-item maximum), since the
    /// capsule's content-driven width still centers within that same space regardless of how many
    /// buttons it holds.
    ///
    /// STABLE-CENTERING ARCHITECTURE — no more `GeometryReader`/`PreferenceKey`/`.onPreferenceChange`
    /// round-trip here at all. That machinery existed only to feed `FavoritesBarView` a
    /// device-measured width so it could decide, one layout pass LATE, between two mutually-
    /// exclusive body branches (a manually-centered capsule vs. a plain leading-aligned
    /// `ScrollView`) — and that one-pass delay was the actual, physically-confirmed root cause of
    /// Scott's "pill loads centered, then jumps left" report: the branch could flip (or the
    /// centering math could recompute against a now-stale width) AFTER the first, already-centered
    /// frame had drawn. `FavoritesBarView` now measures its own available width directly, in the
    /// SAME layout pass it renders in (see that type's own `STABLE-CENTERING ARCHITECTURE` header),
    /// so there is nothing left for Dashboard to measure or hand down, and no second render to jump
    /// during. `.frame(maxWidth: .infinity)` on the heading Text below is untouched — it's still
    /// what makes the heading itself fill/center within the same content width the pill measures.
    @ViewBuilder
    private var favoritesBarSection: some View {
        if !favoriteDestinations.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Favorites")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Spacing.lg)

                // FAVORITES LAYOUT CORRECTION — leading/trailing inset reduced to
                // `FavoritesBarLayout.dashboardHorizontalPadding` (16pt, down from the 24pt the
                // "Favorites" heading above still uses) per Scott's explicit "content should
                // start slightly farther left" instruction — the bar's own inset only, not every
                // other Dashboard section's margin. Applied BEFORE `FavoritesBarView`'s own internal
                // `GeometryReader` measures its available width, so that measurement already
                // reflects this inset — never double-counted, never ignored.
                FavoritesBarView(destinations: favoriteDestinations) { destination in
                    handleFavoriteSelection(destination)
                }
                .padding(.horizontal, FavoritesBarLayout.dashboardHorizontalPadding)
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    /// Routes to each destination's existing canonical view, completely unmodified — never a
    /// second copy of any of these screens' own logic/data ownership. Matches exactly what
    /// `SettingsView` itself already presents for the same five sheets (`MonthlyPlanEntryView`,
    /// `ConnectedAccountsView`, `AccountRelatedOptionsView`, `DataBackupView`, `AskSpendSmartView`)
    /// plus `AddSavingsEntryView` (canonically sheet-presented from `MonthlyPlanView`, and equally
    /// safe to present standalone here since it takes no parameters and owns no external state).
    ///
    /// ASK SPENDSMART PHASE — `.insights` now routes to `AskSpendSmartView`, the always-available
    /// conversational assistant, replacing the old preset-question `InsightsView` (left in the
    /// repository, unreferenced, per that phase's own decision — see its own header comment).
    @ViewBuilder
    private func favoriteDestinationView(for destination: FavoriteDestinationID) -> some View {
        switch destination {
        case .monthlyPlan: MonthlyPlanEntryView()
        // PHASE 2B VISUAL FIX — `.addToSavings` is never reached via the canonical display path
        // (`FavoritesSettings.validDestinationIDs` always maps it to `.monthlyPlan` first — see
        // `FavoriteDestinationID.canonicalDisplayDestination`); this branch exists only for switch
        // exhaustiveness and as a defensive fallback if ever called directly, routing to the same
        // canonical Monthly Plan destination its favorite now collapses into.
        case .addToSavings: MonthlyPlanEntryView()
        case .connectedAccounts: ConnectedAccountsView()
        case .accountSharing: AccountRelatedOptionsView()
        case .backup: DataBackupView()
        case .insights: AskSpendSmartView(screenContext: .dashboard)
        // SETTINGS ORGANIZATION PHASE — Profile/Account route to their own canonical destination
        // screens (same views `Settings ▸ Profile`/`Settings ▸ Account` open — no duplicate
        // implementation). Tools has no destination screen of its own, so it opens the canonical
        // `SettingsView` itself, tagged to scroll straight to the Tools section — see
        // `SettingsScrollTarget`'s own header.
        case .profile: AccountView()
        case .account: AccountSettingsView()
        case .tools: SettingsView(isModal: true, scrollTarget: .tools)
        // TWO-LINE FAVORITES PHASE — `.checkingRegister` is never reached via this path in
        // practice: `handleFavoriteSelection(_:)` intercepts it before it ever reaches
        // `presentedFavoriteDestination` (it needs a real, user-chosen `Account`, which this
        // parameterless view builder has no way to supply). This branch exists only for switch
        // exhaustiveness and as a defensive fallback — Manual Accounts is the closest parameterless
        // equivalent if it were ever invoked directly.
        case .checkingRegister: AccountListView()
        }
    }

    // MARK: - Weekly hero card

    /// TARGET ARCHITECTURE — a Secondary's This Week must reflect the Primary's authorized shared
    /// weekly comparison (from the same `SharedMonthlyOutlookViewModel` summary already driving
    /// Monthly Outlook/Week-by-Week — never a second calculation), never this device's own local
    /// `BudgetSettings.weeklySpendingLimit` (which is a local, per-device preference, never synced
    /// from the Primary, and normally unset for a Secondary).
    ///
    /// URGENT REGRESSION FIX — for the Primary, the normal `SpendingCardView` now ALWAYS renders,
    /// in both Automatic and Custom weekly mode, exactly like every other Dashboard section. The
    /// removed empty-state gate incorrectly treated `plannedWeeklySpendingOverride == nil`
    /// (Automatic mode) and a deliberate custom zero limit the same way — not configured — and
    /// hid the real card behind a setup prompt Scott never asked for. Neither state has any
    /// bearing on whether Monthly Plan data exists; Automatic mode's own value (Flexible Spending
    /// Available ÷ 4) is a real number the moment income/bills exist, with nothing left for the
    /// user to set up first. CORRECTION (2026-08-18) — the card is no longer itself a tap target;
    /// see `WeeklyLimitEditView`'s own header for why (it's read-only, nothing to edit there).
    @ViewBuilder
    private var weeklyCardSection: some View {
        if accountRelatedOptionsLoaded {
            if isSecondary {
                // USER B DASHBOARD PARITY — reads the Primary's own authoritative, already-computed
                // shared aggregate (`sharedDashboardSummary`) — never a second independent
                // reconstruction from raw shared transactions. Guarantees exact parity with the
                // Primary's own Dashboard by construction: there is only one formula, computed once,
                // on the Primary's device.
                if secondaryOutlookAuthorized, let summary = sharedDashboardSummary {
                    SpendingCardView(
                        spent: summary.actualSpentThisWeek,
                        limit: summary.weeklySpendingLimit,
                        status: BudgetCalculator.status(spent: summary.actualSpentThisWeek, limit: summary.weeklySpendingLimit, warningThreshold: settings?.warningThreshold ?? 0.70),
                        weekInterval: sharedCurrentWeekInterval,
                        monthlyRemaining: summary.monthlySpendRemaining,
                        isPrivacyModeEnabled: privacyMode.isEnabled
                    )
                    .padding(.horizontal, Theme.Spacing.lg)

                    // SHARED USER REFRESH PARITY — explicit, on-demand re-pull of the Primary's
                    // shared Dashboard aggregate. Secondary-only; a Primary never sees this
                    // control, and their own Dashboard is otherwise untouched. Styled as a
                    // prominent centered pill (rather than a small text link) per Scott's
                    // explicit request — the Secondary consistently missed the previous
                    // low-visibility text-only control.
                    Button {
                        Task { await loadDashboardSummaryIfNeeded() }
                    } label: {
                        HStack(spacing: 6) {
                            if dashboardSummaryViewModel?.isRefreshing == true {
                                ProgressView().controlSize(.mini).tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text("Refresh Dashboard")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                    }
                    .disabled(dashboardSummaryViewModel?.isRefreshing == true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                // else: not authorized, or shared data not yet loaded — nothing, never a fake
                // local "set a budget" prompt for a Secondary.
            } else {
                SpendingCardView(
                    spent: spentThisWeek,
                    limit: weeklyLimit,
                    status: status,
                    weekInterval: weekInterval,
                    monthlyRemaining: monthlySpendRemaining,
                    isPrivacyModeEnabled: privacyMode.isEnabled
                )
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Quick stats

    /// CLIENT CORRECTION — savings-related Quick Stats must not pick a Primary/local vs.
    /// Secondary/shared branch while role is still unknown (`accountRelatedOptionsViewModel.state`
    /// not yet `.loaded`), since `isSecondary` defaults to `false` during `.idle`/`.loading` and
    /// would otherwise transiently render the LOCAL card for what may actually be a Secondary.
    /// Mirrors `MonthlyPlanEntryView`'s own "LOADING, NOT FLICKER" gate on the same state.
    private var accountRelatedOptionsLoaded: Bool {
        if case .loaded = accountRelatedOptionsViewModel.state { return true }
        return false
    }

    /// TARGET ARCHITECTURE — the single authorization gate for every shared-Monthly-Outlook-backed
    /// Dashboard section (This Week, Monthly Spending, Monthly Outlook, Week-by-Week): role/state
    /// authoritatively known AND the Primary currently shares Monthly Plan.
    private var secondaryOutlookAuthorized: Bool {
        accountRelatedOptionsLoaded && isSecondary && accountRelatedOptionsViewModel.response?.primaryMonthlyPlanShared == true
    }

    private var secondaryOutlookPrimaryUserId: UUID? {
        guard secondaryOutlookAuthorized else { return nil }
        return accountRelatedOptionsViewModel.response?.primaryUserId
    }

    /// USER B DASHBOARD PARITY — depends only on authorization + primary user id (not a shared
    /// account list) since `dashboard_summary` carries only the Primary's already-filtered
    /// aggregate, never a per-account list this device would need to react to directly.
    private var secondaryDashboardSummaryLoadKey: String {
        guard let primaryUserId = secondaryOutlookPrimaryUserId else { return "unauthorized" }
        return primaryUserId.uuidString
    }

    /// Creates (or replaces, on a Primary/user change) the authoritative shared Dashboard summary
    /// view model and loads it — or drops it entirely once no longer authorized, matching every
    /// other shared view model's own "state simply isn't reachable once unauthorized" clearing
    /// mechanism.
    @MainActor
    private func loadDashboardSummaryIfNeeded() async {
        guard let primaryUserId = secondaryOutlookPrimaryUserId else {
            dashboardSummaryViewModel = nil
            return
        }
        let viewModel: SharedDashboardSummaryViewModel
        if let existing = dashboardSummaryViewModel, existing.primaryUserId == primaryUserId {
            viewModel = existing
        } else {
            viewModel = SharedDashboardSummaryViewModel(primaryUserId: primaryUserId)
            dashboardSummaryViewModel = viewModel
        }
        await viewModel.load()
    }

    /// The loaded authoritative shared Dashboard aggregate, if any — the SAME numbers the
    /// Primary's own Dashboard already shows (already privacy-filtered on the Primary's device).
    /// This Week/Monthly Spending Quick Stat/Monthly Outlook/Week-by-Week all read from this
    /// directly — a single canonical source, never a second independent reconstruction.
    private var sharedDashboardSummary: SharedDashboardSummaryDTO? {
        guard case .loaded(let summary?) = dashboardSummaryViewModel?.state else { return nil }
        return summary
    }

    /// Same current-week interval `SharedMonthlyOutlookViewModel.load()` itself used to compute
    /// `summary.actualSpentThisWeek` — recomputed here only for display (the card's own week-range
    /// label), never for any spend arithmetic of its own.
    private var sharedCurrentWeekInterval: DateInterval {
        DateRangeHelper.currentFourWeekBlock()
    }

    /// SUPERSEDES the old "LOCKED PRODUCT RULE" (a Secondary's own Quick Stats picker was
    /// deliberately ignored for this shared card, per an earlier product decision) — Scott
    /// confirmed on 2026-08-18 that unchecking "Saved This Month" must hide it for a Secondary
    /// exactly like every other Quick Stat, including its own sibling
    /// (`sharedSavedViaTransferQuickStatVisible`, which already worked this way). This screen's
    /// own local `QuickStatsSettings` picker (`isQuickStatShown`) is a per-DEVICE display
    /// preference, distinct from `showSavedThisMonthQuickStat`'s now-superseded old Settings
    /// toggle, and applies to a Secondary the same as a Primary.
    private var showLocalSavedThisMonthQuickStat: Bool {
        accountRelatedOptionsLoaded && !isSecondary && showSavedThisMonthQuickStat
    }

    private var sharedSavingsQuickStatVisible: Bool {
        isQuickStatShown(.savedThisMonth) && accountRelatedOptionsLoaded && isSecondary && (accountRelatedOptionsViewModel.response?.primaryMonthlySavingsShared ?? false)
    }

    /// SAVED VIA TRANSFER SHARING — same gating shape as `sharedSavingsQuickStatVisible`, for the
    /// independent `savedViaTransfer` category.
    private var sharedSavedViaTransferQuickStatVisible: Bool {
        accountRelatedOptionsLoaded && isSecondary && (accountRelatedOptionsViewModel.response?.primarySavedViaTransferShared ?? false)
    }

    /// QUICK STATS REDESIGN — a budgeting summary rather than duplicate information: Planned
    /// Weekly Spending / Spent This Week / Planned Monthly Spending / Projected Available After
    /// Spend are all read live from this same view's own already-computed planning properties
    /// above (`plannedWeeklySpendingForOutlook`/`spentThisWeek`/`plannedMonthlySpendingForOutlook`/
    /// `projectedAvailableAfterSpendForOutlook`) — the exact same authoritative values the Weekly
    /// Card and Monthly Outlook section already display elsewhere on this screen, never a second
    /// calculation. Saved This Month keeps its pre-existing card/visibility logic verbatim
    /// (`showLocalSavedThisMonthQuickStat`/`sharedSavingsQuickStatVisible`), just repositioned to
    /// the final row; the prior Monthly Spending card (and its `MonthlySummaryView` sheet) is
    /// removed entirely, per this redesign's own requirement. `LazyVGrid`'s existing 2-column
    /// layout naturally produces the required 3-row shape (2 + 2 + 1) from 5 cards in this order —
    /// no separate row-break logic needed.
    @ViewBuilder
    private var quickStatsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Quick Stats")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Button {
                    isPresentingQuickStatsConfiguration = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Choose Quick Stats")
                Spacer()
                InfoButton(title: "About Quick Stats", explanation: Self.quickStatsInfoExplanation)
            }
            .padding(.horizontal, Theme.Spacing.lg)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.sm), GridItem(.flexible())], spacing: Theme.Spacing.sm) {
                // SHARED USER QUICK STATS PARITY — a Secondary reads these 4 tiles from the
                // Primary's own pushed `sharedDashboardSummary` aggregate instead of this device's
                // local (empty, for a Secondary) planning properties — never a second, local
                // reconstruction. A Primary's own branch below is completely unchanged from before
                // this parity work.
                if isQuickStatShown(.plannedWeeklySpending) {
                    if !isSecondary {
                        StatCard(
                            title: "Planned Weekly Spending",
                            systemIconName: "calendar",
                            amount: plannedWeeklySpendingForOutlook,
                            subtitle: isPlannedWeeklySpendingCustomForOutlook ? "Custom" : "Automatic",
                            accentColor: Theme.accent,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    } else if secondaryOutlookAuthorized, let summary = sharedDashboardSummary {
                        StatCard(
                            title: "Planned Weekly Spending",
                            systemIconName: "calendar",
                            amount: summary.weeklySpendingLimit,
                            subtitle: DateRangeHelper.weekDisplayText(for: sharedCurrentWeekInterval),
                            accentColor: Theme.accent,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    }
                }
                if isQuickStatShown(.spentThisWeek) {
                    if !isSecondary {
                        StatCard(
                            title: "Spent This Week",
                            systemIconName: "cart.fill",
                            amount: spentThisWeek,
                            subtitle: DateRangeHelper.weekDisplayText(for: weekInterval),
                            accentColor: Theme.statusOver,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    } else if secondaryOutlookAuthorized, let summary = sharedDashboardSummary {
                        StatCard(
                            title: "Spent This Week",
                            systemIconName: "cart.fill",
                            amount: summary.actualSpentThisWeek,
                            subtitle: DateRangeHelper.weekDisplayText(for: sharedCurrentWeekInterval),
                            accentColor: Theme.statusOver,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    }
                }
                if isQuickStatShown(.plannedMonthlySpending) {
                    if !isSecondary {
                        StatCard(
                            title: "Planned Monthly Spending",
                            systemIconName: "calendar.badge.clock",
                            amount: plannedMonthlySpendingForOutlook,
                            subtitle: DateRangeHelper.monthDisplayText(for: monthInterval),
                            accentColor: Theme.accentSecondary,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    } else if secondaryOutlookAuthorized, let summary = sharedDashboardSummary, let monthlyOutlookBudgeted = summary.monthlyOutlookBudgeted {
                        StatCard(
                            title: "Planned Monthly Spending",
                            systemIconName: "calendar.badge.clock",
                            amount: monthlyOutlookBudgeted,
                            subtitle: DateRangeHelper.monthDisplayText(for: monthInterval),
                            accentColor: Theme.accentSecondary,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    }
                }
                if isQuickStatShown(.projectedAvailableAfterSpend) {
                    if !isSecondary {
                        StatCard(
                            title: "Projected Available After Spend",
                            systemIconName: "banknote.fill",
                            amount: projectedAvailableAfterSpendForOutlook,
                            subtitle: DateRangeHelper.monthDisplayText(for: monthInterval),
                            accentColor: Theme.statusGood,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    } else if secondaryOutlookAuthorized, let summary = sharedDashboardSummary, let additionalPlannedSavings = summary.additionalPlannedSavings {
                        StatCard(
                            title: "Projected Available After Spend",
                            systemIconName: "banknote.fill",
                            amount: additionalPlannedSavings,
                            subtitle: DateRangeHelper.monthDisplayText(for: monthInterval),
                            accentColor: Theme.statusGood,
                            isPrivacyModeEnabled: privacyMode.isEnabled
                        )
                    }
                }
                if showLocalSavedThisMonthQuickStat {
                    SavedThisMonthQuickStatCard(
                        savedThisMonth: savedThisMonth,
                        totalSavingsToDate: totalSavingsToDate,
                        isPrivacyModeEnabled: privacyMode.isEnabled
                    )
                }
                if sharedSavingsQuickStatVisible, let primaryUserId = accountRelatedOptionsViewModel.response?.primaryUserId {
                    // Fresh `SharedMonthlySavingsViewModel` per presentation — see that type's
                    // own header for why revocation needs no explicit clearing: the moment
                    // `sharedSavingsQuickStatVisible` flips false, SwiftUI removes this whole
                    // branch (and the view model with it).
                    SharedSavedThisMonthQuickStatCard(primaryUserId: primaryUserId, isPrivacyModeEnabled: privacyMode.isEnabled)
                }
                // SAVED VIA TRANSFER SHARING — mirrors the Saved This Month/shared savings split
                // above: a Primary (or a Secondary the Primary hasn't shared this aggregate with)
                // sees their own local Transfer To Savings history; a Secondary the Primary HAS
                // shared it with sees the Primary's server-pushed aggregate instead — never both,
                // and never a local reconstruction from possibly-unshared accounts.
                if isQuickStatShown(.savedViaTransfer) && !sharedSavedViaTransferQuickStatVisible {
                    StatCard(
                        title: "Saved",
                        systemIconName: "arrow.turn.down.right",
                        amount: savedViaTransferThisMonth,
                        subtitle: "Transferred to Savings \u{2022} \(DateRangeHelper.monthDisplayText(for: monthInterval))",
                        accentColor: Theme.statusGood,
                        isPrivacyModeEnabled: privacyMode.isEnabled
                    )
                }
                if isQuickStatShown(.savedViaTransfer), sharedSavedViaTransferQuickStatVisible,
                   let primaryUserId = accountRelatedOptionsViewModel.response?.primaryUserId {
                    // Fresh `SharedSavedViaTransferViewModel` per presentation — see that type's
                    // own header for why revocation needs no explicit clearing: the moment
                    // `sharedSavedViaTransferQuickStatVisible` flips false, SwiftUI removes this
                    // whole branch (and the view model with it).
                    SharedSavedViaTransferQuickStatCard(
                        primaryUserId: primaryUserId,
                        monthInterval: monthInterval,
                        isPrivacyModeEnabled: privacyMode.isEnabled
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .sheet(isPresented: $isPresentingQuickStatsConfiguration) {
            QuickStatsConfigurationView()
        }
    }

    // MARK: - Connected accounts (locally cached balances — refresh delegates to
    // PlaidConnectionManager, never calls Plaid/the backend directly from this view)

    /// See `ConnectedAccountsDashboardPresenter` for the actual mapping logic — kept out of this
    /// view entirely so it's unit-testable without SwiftUI/environment involvement.
    private var connectedAccountBalanceDisplays: [ConnectedAccountsDashboardPresenter.Display] {
        ConnectedAccountsDashboardPresenter.displays(for: plaidConnection.connections)
    }

    /// Every Primary-owned Connected Account currently, effectively shared with this Secondary —
    /// already scoped server-side (migration 0016's `get_secondary_shared_data`, re-verified
    /// against the canonical evaluator) via `AccountRelatedOptionsViewModel`'s own already-running
    /// discovery refresh (see `RootView.task`). Empty for a Primary, an unrelated user, or a
    /// Secondary nothing is currently shared with.
    private var sharedConnectedAccounts: [SharedConnectedAccountDTO] {
        accountRelatedOptionsViewModel.response?.primarySharedConnectedAccounts ?? []
    }

    /// POST-PHASE-10 CORRECTION, PHASE B PARITY FIX STEP 1 — a shared account renders using the
    /// exact same `ConnectedAccountBalanceRow` component and card as an owned account (no visible
    /// "Shared" badge, no stripped-down summary row). `SharedConnectedAccountDTO` (migration
    /// 0017's extension of `get_secondary_shared_data`) now also carries
    /// `currentBalance`/`availableBalance`/`creditLimit`/`accountType`/`updatedAt`, the same
    /// non-secret fields the owner's own listing already exposes — fed through the exact same
    /// `PlaidBalanceFormatter.rows(for:)` an owned account's row uses, so a credit card's shared
    /// balance reads "Balance Owed" + "Available Credit" and a checking account reads "Available
    /// Balance" + "Current Balance" identically to what the Primary sees. For an account the
    /// Primary hasn't refreshed yet, every one of those fields is still `nil` from the server, so
    /// `rows` is empty and `updatedAt` stays `nil` here too — `ConnectedAccountBalanceRow` renders
    /// that as its existing, honest "Balance not
    /// refreshed yet" state, same as an owned-but-never-synced account; nothing is ever
    /// fabricated. `connectionId`/`accountId` remain synthetic/`nil` and `onRefresh` is never
    /// supplied for a shared display (see `connectedAccountsSection`'s own gating), so a shared
    /// row can never become eligible for `refreshConnectedAccount(_:)` — viewing a shared balance
    /// never triggers a new Plaid request and never consumes the Primary's own refresh allowance;
    /// this reads only the Primary's already-cached, already-authorized `plaid_accounts` row.
    private var sharedConnectedAccountDisplays: [ConnectedAccountsDashboardPresenter.Display] {
        sharedConnectedAccounts.map { account in
            let balance = PlaidAccountBalance(
                accountId: account.plaidAccountId.uuidString,
                name: account.name,
                officialName: nil,
                mask: account.mask,
                type: account.accountType,
                subtype: nil,
                currentBalance: account.currentBalance,
                availableBalance: account.availableBalance,
                creditLimit: account.creditLimit,
                isoCurrencyCode: nil,
                unofficialCurrencyCode: nil
            )
            return ConnectedAccountsDashboardPresenter.Display(
                id: "shared-connected-\(account.id.uuidString)",
                connectionId: "shared",
                accountId: nil,
                institutionName: account.name ?? "Connected Account",
                rows: PlaidBalanceFormatter.rows(for: balance),
                updatedAt: account.updatedAt
            )
        }
    }

    /// PHASE B PARITY FIX — an owned Dashboard row has never been tappable (only its Refresh
    /// button is interactive; see `refreshConnectedAccount(_:)`'s own doc comment). A shared row
    /// previously broke that parity by opening `SharedConnectedAccountDetailView` on tap, which
    /// this file's own real-device testing found inconsistent with User A's equivalent card. The
    /// detail/transactions screen this used to open is NOT removed from the app — it remains
    /// reachable from Settings > Account Related Options > "Shared with You"
    /// (`AccountRelatedOptionsView.swift`'s own `SharedByPrimarySectionView`), and the account's
    /// transactions also already appear in the normal Activity/Expenses screen alongside owned
    /// transactions (see `ExpenseListView`'s shared-activity composition) — exactly mirroring how
    /// an owned account's transactions are only ever browsed there, never via a Dashboard tap.
    @ViewBuilder
    private var connectedAccountsSection: some View {
        let displays = connectedAccountBalanceDisplays + sharedConnectedAccountDisplays
        if !displays.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                DashboardSectionHeader(title: "Connected Accounts")
                CardBackground {
                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                            ConnectedAccountBalanceRow(
                                display: display,
                                isPrivacyModeEnabled: privacyMode.isEnabled,
                                isRefreshing: refreshingAccountKeys.contains(display.id),
                                isRateLimited: rateLimitedAccountKeys.contains(display.id),
                                onRefresh: connectedAccountBalanceDisplays.contains(display) ? { refreshConnectedAccount(display) } : nil
                            )
                            if index < displays.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    /// Fires exactly one account's server-rate-limited manual refresh via
    /// `PlaidConnectionManager.refreshAccountBalance` — this view never names the backend service
    /// type or any Plaid sync/refresh helper directly (see
    /// `testDashboardStillNeverCallsPlaidDirectlyAfterRawBalanceRestore`); all networking happens
    /// behind that one already-injected environment object. `display.accountId` is only `nil` for
    /// the no-balance-cached-yet placeholder row, which never renders a Refresh button in the
    /// first place (see `ConnectedAccountBalanceRow`), so a nil here means the button that fired
    /// this call is stale and there is nothing to refresh — a silent no-op, not an error.
    /// CONNECTED ACCOUNT REFRESH CONSISTENCY — one tap now updates both balance and transactions
    /// (see `PlaidConnectionManager.refreshAccountBalanceAndTransactions`'s own doc comment for
    /// why this is still exactly one claimed 2/day/account event, not two). This view still never
    /// names the backend service type or any Plaid sync/refresh helper directly — only the
    /// already-injected `PlaidConnectionManager`, unchanged from before this task.
    private func refreshConnectedAccount(_ display: ConnectedAccountsDashboardPresenter.Display) {
        guard let accountId = display.accountId else { return }
        guard !refreshingAccountKeys.contains(display.id) else { return }
        refreshingAccountKeys.insert(display.id)
        Task {
            defer { refreshingAccountKeys.remove(display.id) }
            do {
                #if DEBUG
                if !refreshLimitEnabled {
                    // DEBUG unlimited testing path (Developer Options > Refresh Limit = OFF) —
                    // see `PlaidConnectionManager`'s own DEBUG-only method for exactly how this
                    // stays safe (a different, already-unlimited existing Plaid operation, never
                    // a client flag the server is asked to trust). Compiles out of Release.
                    _ = try await plaidConnection.refreshAccountBalanceAndTransactionsIgnoringDevelopmentQuota(
                        connectionId: display.connectionId,
                        accountId: accountId,
                        context: modelContext
                    )
                    rateLimitedAccountKeys.remove(display.id)
                    return
                }
                #endif
                _ = try await plaidConnection.refreshAccountBalanceAndTransactions(
                    connectionId: display.connectionId,
                    accountId: accountId,
                    context: modelContext
                )
                rateLimitedAccountKeys.remove(display.id)
            } catch PlaidBackendError.rateLimited {
                rateLimitedAccountKeys.insert(display.id)
            } catch {
                // Any other failure (network, environment mismatch, reauth-required, a
                // transaction-sync failure after a successful balance refresh, etc.) — the button
                // simply returns to its idle state so the user can try again; no raw backend
                // error is ever surfaced here per the product spec. A balance update that already
                // succeeded before a later transaction-sync failure is never rolled back — see
                // `refreshAccountBalanceAndTransactions`'s own ordering/failure-semantics doc.
            }
        }
    }

    // MARK: - Budget Exclusions

    /// EXCLUDE TRANSACTIONS — placed directly above `monthlyOutlookAndWeekByWeekSection` per this
    /// feature's own spec. The master toggle writes only `BudgetSettings.excludeTransactionsEnabled`;
    /// the picker sheet (`ExcludeTransactionsView`) is where individual transactions are actually
    /// selected — this section only shows entry points and a live count, never the picker UI
    /// itself.
    private var budgetExclusionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Budget Exclusions")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                InfoButton(title: "About Budget Exclusions", explanation: Self.budgetExclusionsInfoExplanation)
            }
            .padding(.horizontal, Theme.Spacing.lg)

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TransactionToggleRow(
                        title: "Exclude Transactions",
                        subtitle: "Choose transactions to leave out of Weekly/Monthly totals",
                        isOn: Binding(
                            get: { settings?.excludeTransactionsEnabled ?? false },
                            set: { newValue in setExcludeTransactionsEnabled(newValue) }
                        )
                    )

                    if settings?.excludeTransactionsEnabled ?? false {
                        Divider().overlay(Theme.cardStroke)

                        Button {
                            isPresentingExcludeTransactionsPicker = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Choose Transactions")
                                        .font(Theme.bodyFont)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(excludedTransactionsSummaryText)
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
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    /// "No excluded transactions selected." / "N transactions excluded" — driven directly by
    /// `excludedTransactionIDs` (which is already gated on the master toggle), so this always
    /// matches what's actually affecting budget totals right now, never a stale count.
    private var excludedTransactionsSummaryText: String {
        let count = excludedTransactionIDs.count
        return count == 0 ? "No excluded transactions selected." : "\(count) transaction\(count == 1 ? "" : "s") excluded"
    }

    static let quickStatsInfoExplanation = """
        These are quick snapshots of your spending plan for the month.

        • Planned Weekly Spending — the amount you've decided (or the app has worked out automatically) that you can spend each week, on top of your bills and savings.

        • Spent This Week — what you've actually spent so far this week.

        • Planned Monthly Spending — your weekly plan carried out across the whole month (Planned Weekly Spending × 4).

        • Projected Available After Spend — if you stick exactly to your Planned Monthly Spending for the rest of the month, this is how much would be left over on top of that.

        • Saved This Month — money you've logged as savings this month, using Monthly Plan's "Add to Savings."

        • Saved — money you've moved into a Savings account this month using the "Transfer To Savings" entry type in a Manual Account's register (for example, moving $200 from Checking to Savings). This never changes your Monthly Remaining or Projected Available — it's tracked separately, purely so you can see at a glance how much you've actually put into savings, distinct from "Saved This Month," which tracks manually-logged savings entries instead.

        Tap the "+" next to "Quick Stats" to choose which of these tiles show — nothing is deleted when you hide one, it just tidies up the grid.

        Example: your Planned Weekly Spending is $500 ($2,000 for the month), but you actually have $2,300 available after bills and savings. Projected Available After Spend would show $300 — money you're planning to keep rather than spend. If you also moved $200 from Checking to Savings this month, "Saved" would show $200.
        """

    static let weekByWeekInfoExplanation = """
        This splits the month into 4 weeks — Week 1 always starts on the 1st, no matter what day of the week that falls on — so you can see how your spending compares to your plan, week by week.

        Each week shows how much you spent against your Planned Weekly Spending amount. A week that goes over its limit is highlighted so you can spot it quickly and decide whether to ease up in the weeks that follow to stay on track for the month overall.

        Example: your plan is $500 a week, and Week 2 shows you spent $610 — that week ran $110 over. You might plan to spend a bit less in Week 3 to even things back out.
        """

    static let budgetExclusionsInfoExplanation = """
        Sometimes a purchase shouldn't count against your budget — for example, a big one-time expense you already planned for separately, or something you know you'll be reimbursed for. Budget Exclusions is where you set those aside.

        Any transaction you mark as excluded is left out of your Spent totals everywhere in the app (both weekly and monthly), but it still stays visible in your account register so you have a complete record of everything that happened.

        Example: you buy a $600 laptop for work that your employer will pay you back for next month. Excluding it here keeps it from making your weekly or monthly spending look unusually high while you wait to be reimbursed.
        """

    private func setExcludeTransactionsEnabled(_ isEnabled: Bool) {
        if let settings {
            settings.excludeTransactionsEnabled = isEnabled
            settings.updatedAt = .now
        } else {
            let created = BudgetSettings(excludeTransactionsEnabled: isEnabled)
            modelContext.insert(created)
        }
    }

    // MARK: - Monthly outlook

    /// CLIENT CORRECTION — real-device fix: the Dashboard's Monthly Outlook/Week-by-Week
    /// previously always used this device's OWN local `monthlyPlanSummary` unconditionally, for
    /// every role — for a Secondary (who normally has no local Monthly Plan data of their own),
    /// that rendered an honest-looking but meaningless "$0.00 everywhere" outlook, never the
    /// Primary's real shared plan. A LATER revision (`SharedMonthlyOutlookViewModel`-backed)
    /// reconstructed its own summary from raw shared transactions, inheriting the same defect class
    /// already fixed for `dashboard_summary`'s other fields, and rendered every week in the month
    /// instead of a single current week. USER B DASHBOARD PARITY (canonical) fix: read the SAME
    /// Primary-pushed `dashboard_summary` aggregate This Week/Monthly Spending already use — never a
    /// second calculator, never raw transactions, never more than the single canonical current week.
    @ViewBuilder
    private var monthlyOutlookAndWeekByWeekSection: some View {
        if accountRelatedOptionsLoaded {
            if isSecondary {
                if secondaryOutlookAuthorized, dashboardSummaryViewModel != nil {
                    SharedMonthlyOutlookSection(viewModel: dashboardSummaryViewModel, isPrivacyModeEnabled: privacyMode.isEnabled)
                }
                // else: Primary hasn't shared Monthly Plan, or shared data hasn't loaded yet —
                // no fake local $0.00 outlook.
            } else {
                monthlyOutlookSection
                weekByWeekSection
            }
        }
    }

    /// All 4 weeks' spending, each broken down by account (plus Bill Payment Variance for
    /// whichever account bills were actually paid from that week) — the drill-down behind tapping
    /// the Monthly Outlook card. Built from the exact same `transactions`/`recurringExpenses`
    /// this view's own `monthlyPlanSummary`/`weeklyComparisons` already read, so the per-account
    /// totals can never disagree with the numbers already on screen.
    private var monthlyOutlookBreakdown: [WeeklyOutlookBreakdown] {
        WeeklyOutlookBreakdownCalculator.breakdown(
            recurringExpenses: recurringExpenses,
            transactions: transactions,
            in: monthInterval,
            recommendedWeekly: plannedWeeklySpendingForOutlook,
            includePending: includePending,
            autoTrackedAccountIds: autoTrackedAccountIds,
            excludedTransactionIDs: excludedTransactionIDs,
            warningThreshold: settings?.warningThreshold ?? 0.70
        )
    }

    private var monthlyOutlookSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Monthly Outlook")

            MonthlyOutlookCard(
                budgetedMonthlySpend: plannedMonthlySpendingForOutlook,
                actualMonthlySpend: monthlyPlanSummary.actualSpentThisMonth,
                projectedSavings: projectedMonthlySavingsForOutlook,
                status: projectedStatusForOutlook,
                isPrivacyModeEnabled: privacyMode.isEnabled
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isPresentingMonthlyOutlookBreakdown = true
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Week-by-week

    private var weeklyComparisons: [MonthlyPlanCalculator.WeeklyPlanComparison] {
        monthlyPlanSummary.weeklyComparisons
    }

    /// Defaults to whichever week contains today; falls back to the first week if today somehow
    /// isn't covered (shouldn't happen — `weeksOverlapping` always spans the full month).
    private var currentWeekComparisonIndex: Int {
        weeklyComparisons.firstIndex(where: { $0.weekInterval.contains(.now) }) ?? 0
    }

    private var effectiveWeekIndex: Int {
        guard let selectedWeekIndex, weeklyComparisons.indices.contains(selectedWeekIndex) else {
            return currentWeekComparisonIndex
        }
        return selectedWeekIndex
    }

    /// USER B DASHBOARD PARITY — the canonical current-plan-week index uploaded to
    /// `dashboard_summary`, computed with the SAME `weeklyComparisons.firstIndex(where:
    /// { $0.weekInterval.contains(.now) })` rule `currentWeekComparisonIndex` above uses, but
    /// WITHOUT its display-only `?? 0` fallback: when no week actually contains today (shouldn't
    /// happen in practice, but must never be silently guessed), this is `nil` and the upload omits
    /// current-plan-week data entirely rather than defaulting to Week 1.
    private var currentWeekComparisonIndexForUpload: Int? {
        weeklyComparisons.firstIndex(where: { $0.weekInterval.contains(.now) })
    }

    private func weekMenuLabel(for index: Int) -> String {
        guard weeklyComparisons.indices.contains(index) else { return "" }
        return "Week \(index + 1): \(DateRangeHelper.weekDisplayText(for: weeklyComparisons[index].weekInterval))"
    }

    private var weekByWeekSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Week-by-Week")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                InfoButton(title: "About Week-by-Week", explanation: Self.weekByWeekInfoExplanation)
                if weeklyComparisons.count > 1 {
                    Menu {
                        ForEach(weeklyComparisons.indices, id: \.self) { index in
                            Button(weekMenuLabel(for: index)) {
                                selectedWeekIndex = index
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Week \(effectiveWeekIndex + 1)")
                                .font(Theme.captionFont)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if weeklyComparisons.indices.contains(effectiveWeekIndex) {
                WeeklyPlanComparisonRow(comparison: weeklyComparisons[effectiveWeekIndex], weekNumber: effectiveWeekIndex + 1, isPrivacyModeEnabled: privacyMode.isEnabled)
                    .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Recent activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Recent Activity")

            // Only shown once there's more than one source to choose between — a household with
            // no connected accounts yet never sees a single-option "Manual Transactions" tab.
            if activityTabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(activityTabs) { tab in
                            FilterChip(title: tab.label, isSelected: tab == effectiveActivityTab) {
                                selectedActivityTab = tab
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }

            if recentTransactions.isEmpty {
                EmptyStateCard(
                    systemIconName: "list.bullet.rectangle.portrait.fill",
                    message: emptyActivityMessage
                )
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                CardBackground {
                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(Array(recentTransactions.enumerated()), id: \.element.id) { index, transaction in
                            RecentActivityRow(transaction: transaction, isPrivacyModeEnabled: privacyMode.isEnabled)
                            if index < recentTransactions.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }

            Button {
                isPresentingActivity = true
            } label: {
                HStack(spacing: 4) {
                    Text("More")
                        .font(Theme.captionFont)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var emptyActivityMessage: String {
        if case .manual = effectiveActivityTab { return "No expenses added yet." }
        return "No connected transactions yet."
    }
}

/// One compact line per transaction on the Dashboard: date, name, amount — deliberately lighter
/// than the full `TransactionRow` used in Activity/Weekly, since this is a glance-only summary.
private struct RecentActivityRow: View {
    let transaction: FinanceTransaction
    var isPrivacyModeEnabled: Bool = false

    private var amountColor: Color {
        switch transaction.type {
        case .expense, .transferWithdrawal, .transferToSavings: return Theme.textPrimary
        case .refund, .income, .transferDeposit: return Theme.statusGood
        case .transfer, .creditCardPayment, .balanceAdjustment: return Theme.textTertiary
        }
    }

    private var signPrefix: String {
        switch transaction.type {
        case .expense, .transferWithdrawal, .transferToSavings: return "-"
        case .refund, .income, .transferDeposit: return "+"
        case .transfer, .creditCardPayment, .balanceAdjustment: return ""
        }
    }

    /// `displayName` (merchant/note) when there is one; otherwise the category name, then the
    /// transaction type — a compact row should never show a blank name.
    private var displayText: String {
        let name = transaction.displayName
        if !name.isEmpty { return name }
        return transaction.category?.name ?? transaction.type.label
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .leading)

            Text(displayText)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.sm)

            PrivacyAmountView(
                amount: transaction.amount,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.bodyFont,
                color: amountColor,
                prefix: signPrefix
            )
        }
    }
}

/// One connected Plaid account's cached balance on the Dashboard — reads only what
/// `ConnectedAccountsDashboardPresenter` already computed from persisted `PlaidConnectionManager`
/// state; this view has no networking of its own.
private struct ConnectedAccountBalanceRow: View {
    let display: ConnectedAccountsDashboardPresenter.Display
    var isPrivacyModeEnabled: Bool = false
    /// `nil` only when this account has no `accountId` yet (the no-balance-cached-yet placeholder
    /// row) — there is nothing for a per-account Refresh button to target in that case, so the row
    /// simply omits the button rather than showing one that can't do anything.
    var isRefreshing: Bool = false
    var isRateLimited: Bool = false
    var onRefresh: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.accent.opacity(0.16)))

            VStack(alignment: .leading, spacing: 2) {
                Text(display.institutionName)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitleText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            if !display.rows.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(Array(display.rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .trailing, spacing: 1) {
                            PrivacyAmountView(
                                amount: row.amount,
                                isPrivacyModeEnabled: isPrivacyModeEnabled,
                                font: Theme.bodyFont,
                                color: Theme.textPrimary
                            )
                            Text(row.label)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    if let onRefresh, display.accountId != nil {
                        RefreshPillButton(isRefreshing: isRefreshing, isRateLimited: isRateLimited, action: onRefresh)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitleText: String {
        guard let updatedAt = display.updatedAt else { return "Balance not refreshed yet" }
        return "Last updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Small circular icon button used in the dashboard header (privacy toggle, settings).
private struct HeaderIconButton: View {
    let systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.cardSurface))
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// One Quick Stat tile showing two related savings figures together — Saved This Month (this
/// month's manually-recorded total, via `SavingsCalculator.savedThisMonth`) and the cumulative
/// Total Savings to Date (`SavingsCalculator.totalSavingsToDate`). Kept as a single purpose-built
/// card rather than forcing a second value into `StatCard`'s single-subtitle slot, which would
/// make a full monetary figure read as a caption.
private struct SavedThisMonthQuickStatCard: View {
    let savedThisMonth: Decimal
    let totalSavingsToDate: Decimal
    var isPrivacyModeEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Image(systemName: "banknote.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.statusGood)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.statusGood.opacity(0.16)))

            PrivacyAmountView(
                amount: savedThisMonth,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                font: Theme.amountFont(19),
                color: Theme.textPrimary
            )
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            VStack(alignment: .leading, spacing: 1) {
                Text("Saved This Month")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 3) {
                    Text("Total:")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                    PrivacyAmountView(
                        amount: totalSavingsToDate,
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: .system(size: 11, weight: .medium, design: .rounded),
                        color: Theme.textTertiary
                    )
                }
                .lineLimit(1)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }
}

/// RELIABILITY CORRECTION (2026-08-18) — a card-shaped placeholder (spinner + "Loading…") shown
/// only while a shared Quick Stat card is genuinely fetching, matching `StatCard`'s own exact
/// background/stroke/padding so the Quick Stats grid never visibly jumps between this and the
/// real card. Deliberately NOT shown for `.loaded(nil)` (confirmed not shared) — a spinner there
/// would be actively misleading, not just unhelpful.
private struct SharedQuickStatLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)

            Text(" ")
                .font(Theme.amountFont(19))
                .opacity(0)

            VStack(alignment: .leading, spacing: 1) {
                Text("Loading…")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Text(" ")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .opacity(0)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }
}

/// CLIENT UI PHASE — Secondary-only read-only counterpart to `SavedThisMonthQuickStatCard` above.
/// Fully transient (see `SharedMonthlySavingsViewModel`'s own header): loads from
/// `get-monthly-savings-summary` on appear, never touches SwiftData, never inserts a local
/// `SavingsEntry`. RELIABILITY CORRECTION — shows `SharedQuickStatLoadingPlaceholder` while
/// genuinely loading (see that type's own header); still renders nothing once confirmed not
/// shared. Reuses `SavedThisMonthQuickStatCard` verbatim once loaded, so a Secondary's shared
/// figure looks identical to a Primary's own. No tap target of any kind — same as the Primary's
/// own card, this offers no savings-edit navigation.
private struct SharedSavedThisMonthQuickStatCard: View {
    let primaryUserId: UUID
    let isPrivacyModeEnabled: Bool

    @State private var viewModel: SharedMonthlySavingsViewModel

    init(primaryUserId: UUID, isPrivacyModeEnabled: Bool) {
        self.primaryUserId = primaryUserId
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
        _viewModel = State(initialValue: SharedMonthlySavingsViewModel(primaryUserId: primaryUserId))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            // RELIABILITY CORRECTION (2026-08-18, Scott's explicit request) — a genuine "still
            // loading" must never look identical to "not shared" (both previously rendered
            // nothing, which read as unreliable/flaky rather than as a normal brief load). Only
            // `.loading` gets the placeholder; `.loaded(nil)` (confirmed not shared) stays
            // EmptyView() — showing a spinner there would be actively misleading.
            case .loading:
                SharedQuickStatLoadingPlaceholder()
            case .loaded(nil):
                EmptyView()
            case .loaded(let summary?):
                SavedThisMonthQuickStatCard(
                    savedThisMonth: summary.savedThisMonth,
                    totalSavingsToDate: summary.totalSavingsToDate,
                    isPrivacyModeEnabled: isPrivacyModeEnabled
                )
            case .failed(let message):
                // CLIENT CORRECTION — a genuine failure must never look identical to "not
                // shared"/"still loading" (both of which render nothing above). Minimal,
                // non-blocking: same `Text(message)` convention `SharedPrimaryDataViews.swift`
                // already uses for every other shared-data failure state.
                Text(message)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.statusOver)
            }
        }
        .task(id: primaryUserId) {
            await viewModel.load()
        }
    }
}

/// SAVED VIA TRANSFER SHARING — Secondary-only read-only counterpart to the local "Saved" Quick
/// Stat card above, mirroring `SharedSavedThisMonthQuickStatCard` exactly, including the
/// RELIABILITY CORRECTION loading placeholder (see `SharedQuickStatLoadingPlaceholder`'s own
/// header). Fully transient (see `SharedSavedViaTransferViewModel`'s own header): loads from
/// `get-saved-via-transfer-summary` on appear, never touches SwiftData, and renders nothing once
/// confirmed not shared — only `.loaded(let summary)` with a non-nil `summary` ever produces the
/// tile.
private struct SharedSavedViaTransferQuickStatCard: View {
    let primaryUserId: UUID
    let monthInterval: DateInterval
    let isPrivacyModeEnabled: Bool

    @State private var viewModel: SharedSavedViaTransferViewModel

    init(primaryUserId: UUID, monthInterval: DateInterval, isPrivacyModeEnabled: Bool) {
        self.primaryUserId = primaryUserId
        self.monthInterval = monthInterval
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
        _viewModel = State(initialValue: SharedSavedViaTransferViewModel(primaryUserId: primaryUserId))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            // RELIABILITY CORRECTION — see `SharedSavedThisMonthQuickStatCard`'s own identical
            // header for why only `.loading` gets a placeholder.
            case .loading:
                SharedQuickStatLoadingPlaceholder()
            case .loaded(nil):
                EmptyView()
            case .loaded(let summary?):
                StatCard(
                    title: "Saved",
                    systemIconName: "arrow.turn.down.right",
                    amount: summary.savedViaTransferThisMonth,
                    subtitle: "Transferred to Savings \u{2022} \(DateRangeHelper.monthDisplayText(for: monthInterval))",
                    accentColor: Theme.statusGood,
                    isPrivacyModeEnabled: isPrivacyModeEnabled
                )
            case .failed(let message):
                Text(message)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.statusOver)
            }
        }
        .task(id: primaryUserId) {
            await viewModel.load()
        }
    }
}

/// USER B DASHBOARD PARITY (canonical) — Secondary-only Dashboard counterpart to the local
/// `monthlyOutlookSection`/`weekByWeekSection` above. Reads the SAME Primary-pushed
/// `dashboard_summary` aggregate This Week/Monthly Spending Quick Stat already use — never a
/// second calculator, never raw shared transactions, never more than the single canonical current
/// week. Renders nothing while loading, on failure, or once the Primary's Monthly Plan is no
/// longer shared (`.loaded(nil)`) — never a fabricated $0.00 outlook. For a loaded summary whose
/// Monthly Outlook or current-plan-week fields are `nil` (an older row predating this field
/// extension, or a Primary with no valid current-week comparison) — an honest "not available yet"
/// message, never the previously-shown incorrect reconstructed values.
private struct SharedMonthlyOutlookSection: View {
    /// TARGET ARCHITECTURE — owned by `DashboardView` itself (`dashboardSummaryViewModel`), not
    /// this leaf view, so This Week and the Monthly Spending Quick Stat can read the SAME loaded/
    /// loading/failed state without a second independent fetch. Loading itself is driven entirely
    /// by `DashboardView`'s own `.task(id: secondaryDashboardSummaryLoadKey)` — this view only
    /// renders.
    let viewModel: SharedDashboardSummaryViewModel?
    let isPrivacyModeEnabled: Bool

    /// USER B FULL WEEK-BY-WEEK PARITY — nil means "no explicit choice yet", same
    /// fallback-to-current-week convention as `DashboardView.selectedWeekIndex`/
    /// `effectiveWeekIndex` itself.
    @State private var selectedWeekIndex: Int?

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel?.state {
        case nil, .loading, .loaded(nil):
            EmptyView()
        case .failed(let message):
            // CLIENT CORRECTION — a genuine failure must never look identical to "Primary hasn't
            // shared Monthly Plan" (both previously rendered nothing). Same minimal,
            // non-blocking `Text(message)` convention already used by the shared savings card.
            Text(message)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.statusOver)
                .padding(.horizontal, Theme.Spacing.lg)
        case .loaded(let summary?):
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    DashboardSectionHeader(title: "Monthly Outlook")
                    if let status = summary.monthlyOutlookStatus,
                       let actual = summary.monthlyOutlookActual,
                       let projectedSavings = summary.monthlyOutlookProjectedSavings {
                        MonthlyOutlookCard(
                            budgetedMonthlySpend: summary.monthlyOutlookBudgeted,
                            actualMonthlySpend: actual,
                            projectedSavings: projectedSavings,
                            status: status,
                            isPrivacyModeEnabled: isPrivacyModeEnabled
                        )
                        .padding(.horizontal, Theme.Spacing.lg)
                    } else {
                        unavailableText.padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                weekByWeekBlock(summary: summary)
            }
        }
    }

    private var unavailableText: some View {
        Text("Not available yet.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
    }

    /// USER B FULL WEEK-BY-WEEK PARITY — when the Primary has pushed the full 4-week array
    /// (migration 0026), shows the SAME week selector `DashboardView.weekByWeekSection` itself
    /// uses, backed by `summary.weeklyComparisons` instead of a second independent calculation.
    /// Falls back to the single `currentPlanWeek` (pre-0026 behavior) for an older row that
    /// predates this field — never a hard "unavailable" for data that's still perfectly valid,
    /// just narrower.
    @ViewBuilder
    private func weekByWeekBlock(summary: SharedDashboardSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                DashboardSectionHeader(title: "Week-by-Week")
                if let comparisons = summary.weeklyComparisons, comparisons.count > 1 {
                    Spacer()
                    Menu {
                        ForEach(comparisons.indices, id: \.self) { index in
                            Button("Week \(index + 1): \(DateRangeHelper.weekDisplayText(for: comparisons[index].weekInterval))") {
                                selectedWeekIndex = index
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Week \(effectiveWeekIndex(comparisons: comparisons) + 1)")
                                .font(Theme.captionFont)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.trailing, Theme.Spacing.lg)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if let comparisons = summary.weeklyComparisons, !comparisons.isEmpty {
                let index = effectiveWeekIndex(comparisons: comparisons)
                WeeklyPlanComparisonRow(
                    comparison: MonthlyPlanCalculator.WeeklyPlanComparison(
                        weekInterval: comparisons[index].weekInterval,
                        recommendedLimit: comparisons[index].recommended,
                        actualSpent: comparisons[index].actual,
                        status: comparisons[index].status
                    ),
                    weekNumber: index + 1,
                    isPrivacyModeEnabled: isPrivacyModeEnabled
                )
                .padding(.horizontal, Theme.Spacing.lg)
            } else if let currentPlanWeek = summary.currentPlanWeek {
                WeeklyPlanComparisonRow(
                    comparison: MonthlyPlanCalculator.WeeklyPlanComparison(
                        weekInterval: currentPlanWeek.weekInterval,
                        recommendedLimit: currentPlanWeek.recommended,
                        actualSpent: currentPlanWeek.actual,
                        status: currentPlanWeek.status
                    ),
                    isPrivacyModeEnabled: isPrivacyModeEnabled
                )
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                unavailableText.padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    /// Defaults to whichever week contains today (matching `DashboardView.currentWeekComparisonIndex`'s
    /// own rule), falling back to index 0 if today somehow isn't covered.
    private func effectiveWeekIndex(comparisons: [SharedDashboardSummaryDTO.CurrentPlanWeek]) -> Int {
        if let selectedWeekIndex, comparisons.indices.contains(selectedWeekIndex) {
            return selectedWeekIndex
        }
        return comparisons.firstIndex(where: { $0.weekInterval.contains(.now) }) ?? 0
    }
}

#Preview("Populated") {
    DashboardView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
        .environment(AccountRelatedOptionsViewModel())
}

#Preview("Privacy Mode") {
    DashboardView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager(isEnabled: true))
        .environment(PlaidConnectionManager())
        .environment(AccountRelatedOptionsViewModel())
}

#Preview("Empty") {
    DashboardView()
        .modelContainer(SampleData.emptyPreviewContainer())
        .environment(PrivacyModeManager())
        .environment(PlaidConnectionManager())
        .environment(AccountRelatedOptionsViewModel())
}
