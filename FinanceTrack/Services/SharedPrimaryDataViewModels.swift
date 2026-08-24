import Foundation
import Observation

/// PHASE 9 — three small, independent, fully transient view models driving the read-only screens
/// an active Secondary uses to view data the household Primary has explicitly shared. None of
/// these ever touches SwiftData/`ModelContext` — every value they hold comes straight from the
/// network response and is discarded when the view disappears, which is the entire owned-vs-
/// shared isolation mechanism: a Primary's shared data can never be written into, or confused
/// with, User B's own locally-persisted records, because it is never persisted locally at all.
///
/// Each `load()` re-fetches from the server every time it runs (never cached across
/// presentations) — this is also the revocation mechanism: if the Primary has since turned
/// sharing off for this item/category, the next `load()` (every screen's own `.task`, which reruns
/// each time the view appears) gets back the same "not found"/empty shape any unrelated caller
/// would see (see each read endpoint's own anti-enumeration header) and the screen presents that
/// directly — never falling back to a stale previously-loaded value.

@Observable
final class SharedConnectedAccountViewModel {
    enum LoadState {
        case loading
        case loaded([SharedConnectedAccountTransactionDTO])
        case failed(String)
    }

    let account: SharedConnectedAccountDTO
    private(set) var state: LoadState = .loading
    /// SHARED USER REFRESH PARITY — see `SharedManualAccountViewModel.isRefreshing`'s own header
    /// for the full rationale this mirrors exactly.
    private(set) var isRefreshing = false

    private let backend: HouseholdSharingService

    init(account: SharedConnectedAccountDTO, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.account = account
        self.backend = backend
    }

    @MainActor
    func load() async {
        let isInitialLoad: Bool
        if case .loaded = state {
            isInitialLoad = false
        } else if case .failed = state {
            isInitialLoad = false
        } else {
            isInitialLoad = true
        }

        if isInitialLoad {
            state = .loading
        } else {
            isRefreshing = true
        }
        defer { isRefreshing = false }

        do {
            let response = try await backend.getSharedConnectedAccountTransactions(plaidAccountId: account.plaidAccountId)
            state = .loaded(response.transactions)
        } catch {
            if isInitialLoad {
                state = .failed(Self.describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Shared data is not available right now."
            case .unauthorized: return "You need to sign in again to view shared data."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}

@Observable
final class SharedManualAccountViewModel {
    enum LoadState {
        case loading
        /// `nil` — the account is no longer shared (or never was): anti-enumeration means this is
        /// indistinguishable from "doesn't exist", exactly like the server's own response.
        case loaded(SharedManualAccountDetailDTO?)
        case failed(String)
    }

    let account: SharedManualAccountDTO
    private(set) var state: LoadState = .loading
    /// PHASE B REFRESH — true only while an explicit user-triggered `load()` re-fetch (via a
    /// Refresh control) is in flight AFTER the screen already has data. Drives that control's own
    /// busy state; `state` itself is deliberately left untouched by a refresh in progress (see
    /// `load()`'s own doc comment) so the screen never blanks mid-refresh.
    private(set) var isRefreshing = false

    private let backend: HouseholdSharingService

    init(account: SharedManualAccountDTO, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.account = account
        self.backend = backend
    }

    /// PHASE B REFRESH — RE-FETCH semantics only (see this file's own header): re-requests the
    /// SAME already-authorized `getSharedManualAccountData` call this type's initial `.task` load
    /// already makes — never contacts the bank-linking sync provider, never a mutation, and the server independently
    /// re-verifies sharing on every call exactly as it always has, so a revoked account correctly
    /// flips to `.loaded(nil)` on the next refresh. Matches
    /// `AccountRelatedOptionsViewModel.refresh()`'s own "no full-screen flash after initial load"
    /// convention: `state` only transitions through `.loading` (blanking the screen) on the very
    /// FIRST call; every subsequent call (including an explicit Refresh-button tap) fetches
    /// silently via `isRefreshing`, replacing `state` only once the new result is in — a failed
    /// refresh leaves the last-known-good `state` exactly as it was, surfacing nothing but a
    /// stopped spinner.
    @MainActor
    func load() async {
        let isInitialLoad: Bool
        if case .loaded = state {
            isInitialLoad = false
        } else if case .failed = state {
            isInitialLoad = false
        } else {
            isInitialLoad = true
        }

        if isInitialLoad {
            state = .loading
        } else {
            isRefreshing = true
        }
        defer { isRefreshing = false }

        do {
            let response = try await backend.getSharedManualAccountData(manualAccountId: account.id)
            state = .loaded(response.account)
        } catch {
            if isInitialLoad {
                state = .failed(Self.describe(error))
            }
            // A silent refresh failure leaves `state` untouched — the last-known-good data stays
            // on screen, matching the established convention this file follows throughout.
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Shared data is not available right now."
            case .unauthorized: return "You need to sign in again to view shared data."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}

@Observable
final class SharedMonthlyPlanViewModel {
    enum LoadState {
        case loading
        /// `nil` — no longer shared (or the Primary has no plan at all); indistinguishable by
        /// design, matching `get-monthly-plan-data`'s own anti-enumeration contract.
        case loaded(SharedMonthlyPlanDTO?)
        case failed(String)
    }

    let primaryUserId: UUID
    private(set) var state: LoadState = .loading

    private let backend: HouseholdSharingService

    init(primaryUserId: UUID, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.primaryUserId = primaryUserId
        self.backend = backend
    }

    @MainActor
    func load() async {
        state = .loading
        do {
            let response = try await backend.getSharedMonthlyPlan(ownerUserId: primaryUserId)
            state = .loaded(response.plan)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Shared data is not available right now."
            case .unauthorized: return "You need to sign in again to view shared data."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}

/// PHASE 10 — powers the "Shared Activity" section of the normal Activity screen
/// (`ExpenseListView`). Aggregates transactions across EVERY currently-shared Connected/Manual
/// Account into one chronological list, reusing the exact same `HouseholdSharingService` read
/// calls the individual Phase 9 detail screens already use — no duplicate networking. Like every
/// other Phase 9/10 shared-data view model, this is fully transient: `entries` lives only in this
/// `@Observable` instance, never SwiftData, and `load()` re-fetches from scratch every time it
/// runs (driven by the owning view's `.task(id:)`, keyed to the current discovered account list),
/// so revoked sharing simply stops appearing on the next load — never a stale cached entry.
@Observable
final class SharedActivityViewModel {
    /// One transaction from a shared account, flattened to exactly what the Activity row needs to
    /// display — deliberately NOT `FinanceTransaction` (see this project's owned-vs-shared
    /// isolation rule) and carries no owner/account foreign key of any kind, only the display name
    /// of the shared account it came from.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let accountName: String
        let date: Date?
        let description: String
        let amount: Decimal
        let isPending: Bool
        /// Which shared account this entry came from — mutually exclusive with
        /// `manualAccountId`, and the only thing a caller may use to filter entries down to one
        /// account's own tab (e.g. `ExpenseListView`'s per-account Activity tabs). Never a
        /// User-B-owned identifier of any kind.
        let connectedAccountId: UUID?
        let manualAccountId: UUID?
    }

    private(set) var entries: [Entry] = []
    private(set) var isLoading = false

    private let backend: HouseholdSharingService

    init(backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.backend = backend
    }

    @MainActor
    func load(connectedAccounts: [SharedConnectedAccountDTO], manualAccounts: [SharedManualAccountDTO]) async {
        isLoading = true
        var collected: [Entry] = []

        for account in connectedAccounts {
            guard let response = try? await backend.getSharedConnectedAccountTransactions(plaidAccountId: account.plaidAccountId) else { continue }
            collected.append(contentsOf: response.transactions.map { transaction in
                Entry(
                    id: transaction.id,
                    accountName: account.name ?? "Connected Account",
                    date: transaction.transactionDate,
                    description: transaction.merchantName ?? transaction.originalDescription,
                    amount: transaction.amount,
                    isPending: transaction.isPending,
                    connectedAccountId: account.id,
                    manualAccountId: nil
                )
            })
        }

        for account in manualAccounts {
            guard let response = try? await backend.getSharedManualAccountData(manualAccountId: account.id),
                  let detail = response.account
            else { continue }
            collected.append(contentsOf: detail.transactions.map { transaction in
                Entry(
                    id: transaction.id,
                    accountName: account.name,
                    date: transaction.transactionDate,
                    description: transaction.note,
                    amount: transaction.amount,
                    isPending: transaction.isPending,
                    connectedAccountId: nil,
                    manualAccountId: account.id
                )
            })
        }

        entries = collected.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        isLoading = false
    }
}

/// POST-PHASE-10 CORRECTION — powers normal-card parity for shared Manual Accounts on the
/// Manual Accounts screen. `SharedManualAccountDTO` (the list-level discovery DTO) carries only
/// `id`/`name`/`accountType` — no balance, no institution, no last-four — so this fetches each
/// shared account's DETAIL (`getSharedManualAccountData`, the exact same authorized call
/// `SharedManualAccountViewModel`/`SharedManualAccountDetailView` already make) up front, which
/// DOES carry `currentBalance`/`institutionName`/`lastFourDigits`/`updatedAt`. No new backend
/// contract, no new Edge Function — reuses the existing detail endpoint's already-authorized
/// response, just called once per discovered account instead of only on tap. Fully transient,
/// same as every other type in this file: never SwiftData, never an `Account` instance.
@Observable
final class SharedManualAccountsSummaryViewModel {
    private(set) var detailsByAccountId: [UUID: SharedManualAccountDetailDTO] = [:]
    private(set) var isLoading = false

    private let backend: HouseholdSharingService

    init(backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.backend = backend
    }

    @MainActor
    func load(accounts: [SharedManualAccountDTO]) async {
        isLoading = true
        var collected: [UUID: SharedManualAccountDetailDTO] = [:]
        for account in accounts {
            guard let response = try? await backend.getSharedManualAccountData(manualAccountId: account.id),
                  let detail = response.account
            else { continue }
            collected[account.id] = detail
        }
        detailsByAccountId = collected
        isLoading = false
    }
}

/// CLIENT UI PHASE — powers the Secondary Dashboard's read-only shared savings Quick Stat. Same
/// fully-transient shape as `SharedMonthlyPlanViewModel` above: never touches SwiftData, never
/// inserts a local `SavingsEntry`, and `load()` re-fetches from `get-monthly-savings-summary`
/// every time it runs — the server independently re-evaluates `monthlySavings` sharing on every
/// call, so a revoked share simply produces `.loaded(nil)` on the next load, and this view model
/// itself is discarded (see `DashboardView`'s own conditional presentation) the moment
/// `primaryMonthlySavingsShared` flips false, which is the entire clearing mechanism — no explicit
/// teardown code needed here.
@Observable
final class SharedMonthlySavingsViewModel {
    enum LoadState {
        case loading
        /// `nil` — no longer shared (or the Primary has no summary yet); indistinguishable by
        /// design, matching `get-monthly-savings-summary`'s own anti-enumeration contract.
        case loaded(SharedMonthlySavingsSummaryDTO?)
        case failed(String)
    }

    let primaryUserId: UUID
    private(set) var state: LoadState = .loading

    private let backend: HouseholdSharingService

    init(primaryUserId: UUID, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.primaryUserId = primaryUserId
        self.backend = backend
    }

    /// RELIABILITY CORRECTION (2026-08-18, Scott's explicit request — "should always work and not
    /// be iffy") — one automatic, immediate retry before surfacing `.failed`: a single transient
    /// network blip right after switching accounts previously required leaving and re-entering
    /// the screen to recover; now it's retried in place, invisibly, before the user can even
    /// notice. Still exactly one retry (never a loop/backoff/timer — this file's own established
    /// "no new scheduling mechanism" posture, matching `BiometricAuthManager`'s identical rule) —
    /// a second consecutive failure is a real problem worth surfacing, not silently swallowed.
    @MainActor
    func load() async {
        state = .loading
        do {
            let response = try await fetch()
            state = .loaded(response.summary)
            #if DEBUG
            print("[SharedMonthlySavingsViewModel] load succeeded — summary: \(response.summary != nil ? "present" : "null")")
            #endif
        } catch {
            do {
                let response = try await fetch()
                state = .loaded(response.summary)
                #if DEBUG
                print("[SharedMonthlySavingsViewModel] load succeeded on retry — summary: \(response.summary != nil ? "present" : "null")")
                #endif
            } catch {
                state = .failed(Self.describe(error))
                #if DEBUG
                print("[SharedMonthlySavingsViewModel] load failed after retry — \(Self.describe(error))")
                #endif
            }
        }
    }

    private func fetch() async throws -> SharedMonthlySavingsSummaryResponse {
        try await backend.getMonthlySavingsSummary(ownerUserId: primaryUserId)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Shared data is not available right now."
            case .unauthorized: return "You need to sign in again to view shared data."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}

/// SAVED VIA TRANSFER SHARING — the shared Saved-via-Transfer aggregate reader, mirroring
/// `SharedMonthlySavingsViewModel` exactly (same anti-enumeration contract, same error surface).
@Observable
final class SharedSavedViaTransferViewModel {
    enum LoadState {
        case loading
        /// `nil` — no longer shared (or the Primary has no summary yet); indistinguishable by
        /// design, matching `get-saved-via-transfer-summary`'s own anti-enumeration contract.
        case loaded(SharedSavedViaTransferSummaryDTO?)
        case failed(String)
    }

    let primaryUserId: UUID
    private(set) var state: LoadState = .loading

    private let backend: HouseholdSharingService

    init(primaryUserId: UUID, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.primaryUserId = primaryUserId
        self.backend = backend
    }

    /// RELIABILITY CORRECTION — one automatic, immediate retry before surfacing `.failed`; see
    /// `SharedMonthlySavingsViewModel.load()`'s own identical header for the full rationale.
    @MainActor
    func load() async {
        state = .loading
        do {
            let response = try await fetch()
            state = .loaded(response.summary)
            #if DEBUG
            print("[SharedSavedViaTransferViewModel] load succeeded — summary: \(response.summary != nil ? "present" : "null")")
            #endif
        } catch {
            do {
                let response = try await fetch()
                state = .loaded(response.summary)
                #if DEBUG
                print("[SharedSavedViaTransferViewModel] load succeeded on retry — summary: \(response.summary != nil ? "present" : "null")")
                #endif
            } catch {
                state = .failed(Self.describe(error))
                #if DEBUG
                print("[SharedSavedViaTransferViewModel] load failed after retry — \(Self.describe(error))")
                #endif
            }
        }
    }

    private func fetch() async throws -> SharedSavedViaTransferSummaryResponse {
        try await backend.getSavedViaTransferSummary(ownerUserId: primaryUserId)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Shared data is not available right now."
            case .unauthorized: return "You need to sign in again to view shared data."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}

/// USER B DASHBOARD PARITY — the authoritative shared Dashboard aggregate reader. Reads the exact
/// numbers the Primary's own device already computed and pushed via
/// `PrimaryDashboardSummarySyncService` (already privacy-filtered to only explicitly-shared
/// accounts) — NEVER a second, independent reconstruction from raw shared transactions. This
/// replaces `SharedMonthlyOutlookViewModel` as the authoritative source for This Week/Monthly
/// Spending on a Secondary's Dashboard; `SharedMonthlyOutlookViewModel` remains in place
/// unmodified for the separate Shared Monthly Plan (Monthly Outlook/Week-by-Week) presentation.
@Observable
final class SharedDashboardSummaryViewModel {
    enum LoadState {
        case loading
        /// `nil` — no longer shared (or the Primary has no summary yet); indistinguishable by
        /// design, matching `get-dashboard-summary`'s own anti-enumeration contract.
        case loaded(SharedDashboardSummaryDTO?)
        case failed(String)
    }

    let primaryUserId: UUID
    private(set) var state: LoadState = .loading
    /// SHARED USER REFRESH PARITY — true only while an explicit user-triggered `load()` re-fetch is
    /// in flight AFTER the screen already has data, matching `SharedManualAccountViewModel`'s own
    /// established "no full-screen flash after initial load" convention (see that type's own
    /// `load()` header for the full rationale). Drives a manual Refresh control's busy state and
    /// backs the Dashboard's pull-to-refresh / `onChange(of: scenePhase)` re-pull.
    private(set) var isRefreshing = false

    private let backend: HouseholdSharingService

    init(primaryUserId: UUID, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.primaryUserId = primaryUserId
        self.backend = backend
    }

    @MainActor
    func load() async {
        let isInitialLoad: Bool
        if case .loaded = state {
            isInitialLoad = false
        } else if case .failed = state {
            isInitialLoad = false
        } else {
            isInitialLoad = true
        }

        if isInitialLoad {
            state = .loading
        } else {
            isRefreshing = true
        }
        defer { isRefreshing = false }

        do {
            let response = try await backend.getDashboardSummary(ownerUserId: primaryUserId)
            state = .loaded(response.summary)
        } catch {
            if isInitialLoad {
                state = .failed(Self.describe(error))
            }
            // A silent refresh failure leaves `state` untouched — the last-known-good data stays
            // on screen, matching `SharedManualAccountViewModel`'s own convention.
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Shared data is not available right now."
            case .unauthorized: return "You need to sign in again to view shared data."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}

/// PHASE B — SECONDARY SHARED MONTHLY OUTLOOK PARITY (OPTION A, locked). Produces the same
/// `MonthlyPlanCalculator.Summary` the Primary's own Monthly Plan screen computes, fed with
/// Primary-owned data the caller is independently, server-authorized to see — never a second,
/// reimplemented formula, never a broader Primary total than OPTION A permits.
///
/// OPTION A ENFORCEMENT: "Actual" spending is built ONLY from transactions belonging to
/// Primary-owned Connected/Manual Accounts that are CURRENTLY in the caller-supplied
/// `connectedAccounts`/`manualAccounts` lists — and those lists themselves come from
/// `AccountRelatedOptionsViewModel.response.primarySharedConnectedAccounts`/
/// `primarySharedManualAccounts`, which is itself sourced from `get_secondary_shared_data`
/// (migration 0016/0017), already filtered server-side through the canonical
/// `is_effectively_shared_for_user` evaluator. This type never queries an account that isn't in
/// those lists, never asks the server for a broader Primary total, and performs no local
/// permission evaluation of its own — the authorized set is accepted as given, exactly as
/// `SharedActivityViewModel`/`SharedManualAccountsSummaryViewModel` above already do. An account
/// no longer present in a caller-supplied list on a later `load()` call simply stops contributing
/// — this IS the revocation mechanism, matching every other type in this file.
///
/// TRANSIENCE: `IncomeSource`/`RecurringExpense`/`MonthlyPlanSettings`/`FinanceTransaction`
/// instances built here are plain in-memory objects — never inserted into any `ModelContext`,
/// never touching this device's `@Query`-backed data, discarded when this view model is
/// deallocated. Reusing these `@Model` types (rather than inventing parallel plain structs) is
/// safe specifically BECAUSE they are never persisted; it lets `MonthlyPlanCalculator` — which
/// only knows how to consume these exact types — run completely unmodified.
///
/// "BUDGETED": the Dashboard's own `MonthlyOutlookCard` shows `BudgetSettings.monthlyGoal` under
/// that label — a raw per-device preference that was never part of Monthly Plan cloud sync
/// (migration 0012's own header explicitly excludes `BudgetSettings` fields) and is therefore
/// structurally unavailable here without a backend change this task doesn't authorize. This type
/// instead surfaces `Summary.flexibleSpendingAvailable` — the calculator's own "what's left after
/// income minus fixed bills minus savings goal minus buffer" figure — as the closest honestly
/// computable equivalent from data this Secondary is actually authorized to see.
///
/// PREFERENCE DEFAULTS: `weekStartsOnSunday`/`warningThreshold`/`includePending` are
/// `BudgetSettings` fields never included in Monthly Plan sharing at all (same exclusion as
/// above) — this type uses this app's own established defaults (`true`/`0.70`/`true`, matching
/// `BudgetSettings`'s own `init` defaults) rather than guessing the Primary's actual preferences.
/// Documented, not hidden: a Primary who has customized these three settings will see a Week-by-
/// Week boundary/status-color that doesn't exactly match their own device.
@Observable
final class SharedMonthlyOutlookViewModel {
    enum LoadState {
        case loading
        /// `nil` — Monthly Plan is no longer shared (or the Primary has no plan at all);
        /// indistinguishable by design, matching `get-monthly-plan-data`'s own anti-enumeration
        /// contract via `SharedMonthlyPlanViewModel`.
        case loaded(MonthlyPlanCalculator.Summary?)
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    /// True only while an explicit re-fetch is in flight after the screen already has data —
    /// same non-blanking convention as `SharedManualAccountViewModel.load()`.
    private(set) var isRefreshing = false

    let primaryUserId: UUID
    private let backend: HouseholdSharingService

    init(primaryUserId: UUID, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.primaryUserId = primaryUserId
        self.backend = backend
    }

    @MainActor
    func load(connectedAccounts: [SharedConnectedAccountDTO], manualAccounts: [SharedManualAccountDTO]) async {
        let isInitialLoad: Bool
        if case .loaded = state { isInitialLoad = false } else if case .failed = state { isInitialLoad = false } else { isInitialLoad = true }
        if isInitialLoad {
            state = .loading
        } else {
            isRefreshing = true
        }
        defer { isRefreshing = false }

        do {
            let planResponse = try await backend.getSharedMonthlyPlan(ownerUserId: primaryUserId)
            guard let plan = planResponse.plan else {
                state = .loaded(nil)
                return
            }

            var transactions: [FinanceTransaction] = []

            // OPTION A — only the caller-supplied, already-authorized shared accounts are ever
            // queried; no other Primary-owned account is ever asked for.
            for account in connectedAccounts {
                guard let response = try? await backend.getSharedConnectedAccountTransactions(plaidAccountId: account.plaidAccountId) else { continue }
                transactions.append(contentsOf: response.transactions.map { tx in
                    FinanceTransaction(
                        amount: tx.amount,
                        date: tx.transactionDate ?? tx.postedDate ?? tx.authorizedDate ?? .distantPast,
                        type: .expense,
                        source: .plaid,
                        isPending: tx.isPending
                    )
                })
            }
            for account in manualAccounts {
                guard let response = try? await backend.getSharedManualAccountData(manualAccountId: account.id),
                      let detail = response.account
                else { continue }
                transactions.append(contentsOf: detail.transactions.map { tx in
                    FinanceTransaction(
                        amount: tx.amount,
                        date: tx.transactionDate ?? .distantPast,
                        type: TransactionType(rawValue: tx.transactionType) ?? .expense,
                        source: .manual,
                        isPending: tx.isPending
                    )
                })
            }

            let incomeSources = plan.incomeSources.map { dto in
                IncomeSource(
                    name: dto.name,
                    amount: dto.amount,
                    frequency: PlanFrequency(rawValue: dto.frequency) ?? .monthly,
                    nextPayDate: dto.nextPayDate,
                    isActive: dto.isActive
                )
            }
            let recurringExpenses = plan.recurringExpenses.map { dto in
                RecurringExpense(
                    name: dto.name,
                    amount: dto.amount,
                    frequency: PlanFrequency(rawValue: dto.frequency) ?? .monthly,
                    dueDate: dto.dueDate,
                    isActive: dto.isActive
                )
            }
            let planSettings = MonthlyPlanSettings(
                monthlySavingsGoal: plan.monthlySavingsGoal,
                bufferAmount: plan.bufferAmount,
                autoUpdateWeeklyBudgetFromPlan: plan.autoUpdateWeeklyBudgetFromPlan
            )

            let month = DateRangeHelper.currentMonthRange()
            let week = DateRangeHelper.currentWeekRange(weekStartsOnSunday: true)
            let summary = MonthlyPlanCalculator.summary(
                month: month,
                incomeSources: incomeSources,
                recurringExpenses: recurringExpenses,
                planSettings: planSettings,
                weeklyBudgetLimit: 0,
                transactions: transactions,
                weekInterval: week,
                weekStartsOnSunday: true,
                includePending: true,
                warningThreshold: 0.70
            )
            state = .loaded(summary)
        } catch {
            if isInitialLoad {
                state = .failed(Self.describe(error))
            }
            // A silent refresh failure leaves `state` untouched — matches every other type here.
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Shared data is not available right now."
            case .unauthorized: return "You need to sign in again to view shared data."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}
