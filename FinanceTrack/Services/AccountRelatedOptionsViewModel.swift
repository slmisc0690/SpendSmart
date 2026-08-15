import Foundation
import Observation

/// Drives the PHASE 7 "Account Related Options" screen AND the Primary-only visibility gate for
/// its Settings row. A single instance is created once at app root (mirroring
/// `ManualDataCloudSyncManager`/`MonthlyPlanCloudSyncManager`'s own lifecycle) and injected via
/// `.environment`, so the row-visibility check and the screen's own data share one network round
/// trip's result rather than each independently re-fetching.
///
/// TRUSTED ROLE RESOLUTION (Phase 4/16's own requirement): `role`/`visibility` are derived
/// EXCLUSIVELY from the server's `get-account-related-options` response — never inferred from any
/// local SwiftData state or cached value. Until that call has succeeded at least once,
/// `visibility` is `.hidden` — a Secondary (or a user whose role is still unknown) never sees the
/// row, even transiently. This is a client-side UX convenience only: every server write endpoint
/// this view model calls independently re-verifies Primary status itself (see each Edge
/// Function's own header) — hiding the row here is defense-in-depth, not the actual security
/// boundary.
///
/// WRITE CONFIRMATION (Phase 17): every mutating action re-fetches the full server state after a
/// successful write, rather than optimistically mutating local state — so the UI can never show a
/// toggle as ON when the server write actually failed partway through.
///
/// NO FULL-SCREEN FLASH AFTER INITIAL LOAD (Phase 7D): `refresh()` only shows the loading
/// placeholder (transitions `state` through `.loading`) the FIRST time it runs, i.e. while `state`
/// is not yet `.loaded`. Every subsequent call — including the silent re-fetch `performAction`
/// triggers after a successful mutation — fetches in the background and only ever *replaces*
/// `state` with a new `.loaded(...)` value on success; it never transitions through `.loading` or
/// `.failed` first, so `visibility` (and therefore the screen's content) never drops back to
/// `.hidden` mid-mutation. A background refresh that itself fails leaves `state` exactly as it
/// was (still `.loaded` with the last-known-good data) and only surfaces `actionError` — the
/// screen is never blanked by a failed silent refresh either.
///
/// IMMEDIATE TOGGLE RESPONSE (Phase 8D): a sharing toggle's write (`update-sharing-permission`)
/// PLUS its confirming `refresh()` together take a real network round trip or two — waiting for
/// both before moving the switch reads as an unacceptable 1-2s stall. `optimisticSharingOverrides`
/// holds the just-requested value for the specific (category, itemId) the user touched; `isShared`
/// checks it FIRST, so the switch flips the instant the user taps, while the actual write/refresh
/// happen in the background. The override is cleared once the write either succeeds (the
/// subsequent `refresh()` now reports server-confirmed data identical to what was already showing
/// — no visible change) or fails (the override is simply removed, so display falls straight back
/// to the last server-confirmed value, i.e. a rollback with no separate "previous value" bookkeeping
/// needed since the failed write never touched server state in the first place). This is a display
/// convenience only — `response`/`state` remain the sole source of truth for every other read
/// (visibility, security), never influenced by `optimisticSharingOverrides`.
@Observable
final class AccountRelatedOptionsViewModel {
    enum LoadState {
        case idle
        case loading
        case loaded(AccountRelatedOptionsResponse)
        case failed(String)
    }

    enum Visibility: Equatable {
        /// Role not yet resolved — the row/screen must not appear.
        case hidden
        /// Resolved: no household yet — show only the "set up household sharing" entry point.
        case entryPoint
        /// Resolved: active Primary — show the full Account Related Options screen.
        case primary
        /// Resolved: active Secondary (PHASE 8D) — show ONLY "Share Connected Account". Never the
        /// Primary's household administration / global sharing / invitation controls.
        case secondary
    }

    /// Identifies which single control a mutation is in flight for, so the UI can disable/show a
    /// busy indicator on ONLY that control rather than the whole screen or every toggle at once.
    enum Mutation: Equatable {
        case createHousehold
        case connectedGlobal
        case connectedItem(UUID)
        case manualGlobal
        case manualItem(UUID)
        case monthlyPlan
        /// CLIENT UI PHASE — `monthlySavings` is an independent global-only category, never
        /// sharing this case with `.monthlyPlan` (see `setGlobalSharing`'s own explicit mapping).
        case monthlySavings
        /// SAVED VIA TRANSFER SHARING — `savedViaTransfer` is an independent global-only category
        /// (migration 0023), never sharing this case with `.monthlyPlan`/`.monthlySavings` (see
        /// `setGlobalSharing`'s own explicit mapping).
        case savedViaTransfer
        case sendInvitation
        case resendInvitation
        case revokeInvitation
    }

    private(set) var state: LoadState = .idle
    private(set) var activeMutation: Mutation?
    private(set) var actionError: String?
    /// Phase 8 — the `spendsmart://household-invitation` link from the most recent successful
    /// invite/resend, so the UI can offer to share it (this project has no automated email
    /// delivery yet — see `manage-household-invitation`'s own header). Cleared on every
    /// `refresh()`/`reset()` so a stale link is never offered after the invitation state has
    /// moved on (e.g. the invitation was since accepted or revoked elsewhere).
    private(set) var lastInvitationUrl: String?

    /// Phase 8D — see this type's own "IMMEDIATE TOGGLE RESPONSE" header. Keyed by
    /// `overrideKey(category:itemId:)`.
    private var optimisticSharingOverrides: [String: Bool] = [:]

    /// Bumped by `reset()` (called on sign-out) — same proven fix as `AutoBackupManager
    /// .generation`, applied to an unstructured async call instead of a `NotificationCenter`
    /// observer. `RootView.task` fires `Task { await accountRelatedOptionsViewModel.refresh() }`
    /// as a nested, unstructured `Task` — it is NOT cancelled when `RootView` (and the signed-out
    /// user's session) goes away. Without this check, that stale in-flight `refresh()` could
    /// resume after `reset()` and overwrite the freshly-`.idle` state with the OUTGOING user's
    /// role/sharing data for whichever session (same or different user) comes next. Captured at
    /// the start of `refresh()`, re-checked immediately before every `state`/`actionError`
    /// mutation.
    private var generation = 0

    /// CLIENT CORRECTION — coalesces concurrent `refresh()` callers (e.g. `RootView.task` and the
    /// `scenePhase == .active` handler can both fire near sign-in) onto a single in-flight network
    /// request, rather than racing two independent fetches to completion where the later-arriving
    /// response silently wins regardless of which one is actually current. A caller that arrives
    /// while a request is already in flight simply awaits that SAME request instead of starting a
    /// second one. Cleared by `reset()` (never awaited/cancelled there — the orphaned task's own
    /// `generation`-guarded writes below become no-ops, exactly like every other in-flight write in
    /// this type) so a `refresh()` call for the NEXT user always starts a fresh fetch rather than
    /// awaiting a stale task that belongs to the outgoing user.
    private var inFlightRefresh: Task<Void, Never>?

    /// Convenience for call sites that only need "is anything in flight right now" (e.g. the
    /// entry-point button, which has no other control competing for attention).
    var isPerformingAction: Bool { activeMutation != nil }

    private static func overrideKey(category: String, itemId: UUID?) -> String {
        itemId.map { "\(category):\($0.uuidString)" } ?? category
    }

    /// The value a sharing toggle should display right now — an in-flight optimistic value if one
    /// exists for this exact (category, itemId), otherwise the last server-confirmed value (same
    /// semantics as `accountRelatedOptionsEffectiveIsShared`, which this falls back to).
    func isShared(category: String, itemId: UUID?) -> Bool {
        if let override = optimisticSharingOverrides[Self.overrideKey(category: category, itemId: itemId)] {
            return override
        }
        return accountRelatedOptionsEffectiveIsShared(permissions: response?.sharingPermissions ?? [], category: category, itemId: itemId)
    }

    private let backend: HouseholdSharingService

    init(backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.backend = backend
    }

    var visibility: Visibility {
        guard case .loaded(let response) = state else { return .hidden }
        switch response.role {
        case .primary: return .primary
        case .secondary: return .secondary
        case nil: return .entryPoint
        }
    }

    var response: AccountRelatedOptionsResponse? {
        if case .loaded(let response) = state { return response }
        return nil
    }

    /// Called on sign-out — see `FinanceTrackApp`'s own sign-out block for why this must run
    /// before the next user's session is established.
    @MainActor
    func reset() {
        state = .idle
        activeMutation = nil
        actionError = nil
        lastInvitationUrl = nil
        optimisticSharingOverrides = [:]
        // Invalidates any `refresh()` call already in flight before this ran — see `generation`'s
        // own doc comment. Dropping the reference (not awaiting/cancelling the task itself) means
        // the NEXT `refresh()` call — for whichever user signs in next — starts a fresh fetch
        // instead of coalescing onto a task that belongs to the outgoing user.
        generation += 1
        inFlightRefresh = nil
    }

    /// Shows the loading placeholder only on the very first call (while `state` is not yet
    /// `.loaded`) — every later call (sheet re-presented, or the silent re-fetch after a
    /// mutation) fetches in the background and never blanks already-loaded content. See this
    /// type's own header for the full reasoning. Concurrent callers within the same session
    /// coalesce onto one in-flight request — see `inFlightRefresh`'s own doc comment.
    @MainActor
    func refresh() async {
        if let inFlightRefresh {
            await inFlightRefresh.value
            return
        }
        let callGeneration = generation
        let task = Task { @MainActor in
            await self.performRefresh(callGeneration: callGeneration)
        }
        inFlightRefresh = task
        await task.value
        // Only clear the slot if it's still ours — a `reset()` (or a newer call that itself
        // already found `inFlightRefresh == nil` after a reset) may have moved on to a different
        // generation/task in the meantime, and must not have its own bookkeeping clobbered here.
        if callGeneration == generation {
            inFlightRefresh = nil
        }
    }

    @MainActor
    private func performRefresh(callGeneration: Int) async {
        guard case .loaded = state else {
            state = .loading
            do {
                let response = try await backend.getAccountRelatedOptions()
                guard callGeneration == generation else { return }
                state = .loaded(response)
                Self.logDebugState(response)
                if response.pendingInvitation == nil { lastInvitationUrl = nil }
            } catch {
                guard callGeneration == generation else { return }
                state = .failed(Self.describe(error))
            }
            return
        }
        do {
            let response = try await backend.getAccountRelatedOptions()
            guard callGeneration == generation else { return }
            state = .loaded(response)
            Self.logDebugState(response)
            // The invitation was accepted/revoked/expired (elsewhere, or by this same refresh
            // following a mutation) — a share link pointing at it would now be dead. Phase 12's
            // own "pending invitation disappears/updates after acceptance" requirement.
            if response.pendingInvitation == nil { lastInvitationUrl = nil }
        } catch {
            guard callGeneration == generation else { return }
            // Never reverts `state` — the last-known-good `.loaded` content stays on screen;
            // only the error is surfaced.
            actionError = Self.describe(error)
        }
    }

    @MainActor
    func createHousehold() async {
        await performAction(.createHousehold) {
            _ = try await backend.initializeHousehold()
        }
    }

    @MainActor
    func invite(email: String) async {
        guard let householdId = response?.householdId else { return }
        await performAction(.sendInvitation) {
            let result = try await backend.manageInvitation(.invite(householdId: householdId, email: email))
            self.lastInvitationUrl = result.invitationUrl
        }
    }

    @MainActor
    func resendInvitation() async {
        guard let invitationId = response?.pendingInvitation?.id else { return }
        await performAction(.resendInvitation) {
            let result = try await backend.manageInvitation(.resend(invitationId: invitationId))
            self.lastInvitationUrl = result.invitationUrl
        }
    }

    @MainActor
    func revokeInvitation() async {
        guard let invitationId = response?.pendingInvitation?.id else { return }
        lastInvitationUrl = nil
        await performAction(.revokeInvitation) {
            _ = try await backend.manageInvitation(.revoke(invitationId: invitationId))
        }
    }

    /// `onSuccessfullyEnabled` — CLIENT CORRECTION: an optional caller-supplied hook, invoked once
    /// the write genuinely succeeds (`actionError == nil`) AND the caller turned the toggle ON
    /// (never on OFF, never on failure). Exists so the "Share Monthly Savings" toggle can
    /// reconcile the Primary's current aggregate immediately (see
    /// `MonthlySavingsSharingSectionView`'s own call site) WITHOUT this view model itself gaining
    /// any SwiftData/`SavingsEntry` dependency — it stays a plain closure the caller (which
    /// already has `@Query` access) provides; every other category simply never passes one.
    @MainActor
    func setGlobalSharing(category: String, isShared: Bool, onSuccessfullyEnabled: (() async -> Void)? = nil) async {
        let mutation: Mutation = switch category {
        case "connectedAccounts": .connectedGlobal
        case "manualAccounts": .manualGlobal
        case "monthlySavings": .monthlySavings
        case "savedViaTransfer": .savedViaTransfer
        default: .monthlyPlan
        }
        await setSharing(mutation: mutation, category: category, itemId: nil, isShared: isShared)
        if isShared, actionError == nil {
            await onSuccessfullyEnabled?()
        }
    }

    @MainActor
    func setItemSharing(category: String, itemId: UUID, isShared: Bool) async {
        let mutation: Mutation = category == "connectedAccounts" ? .connectedItem(itemId) : .manualItem(itemId)
        await setSharing(mutation: mutation, category: category, itemId: itemId, isShared: isShared)
    }

    /// See this type's own "IMMEDIATE TOGGLE RESPONSE" header — sets the optimistic override
    /// before the network call even starts, so the visible switch moves immediately, then clears
    /// it once the write's outcome (success or failure) is known.
    @MainActor
    private func setSharing(mutation: Mutation, category: String, itemId: UUID?, isShared: Bool) async {
        let key = Self.overrideKey(category: category, itemId: itemId)
        optimisticSharingOverrides[key] = isShared
        activeMutation = mutation
        actionError = nil
        do {
            _ = try await backend.updateSharingPermission(
                SharingPermissionUpdateRequest(category: category, itemId: itemId?.uuidString, isShared: isShared)
            )
            // `state` is already `.loaded` here (a toggle is only reachable once the screen
            // itself is showing loaded content), so this always takes refresh()'s silent
            // background path — never re-shows the loading placeholder (Phase 7D).
            await refresh()
            // The server now agrees with what's already on screen — drop the override so future
            // reads go back through the single authoritative `response` path.
            optimisticSharingOverrides[key] = nil
        } catch {
            // Rollback: the write never reached the server (or the server rejected it), so
            // `response`'s own last-confirmed value is still correct — simply stop overriding it.
            optimisticSharingOverrides[key] = nil
            actionError = Self.describe(error)
        }
        activeMutation = nil
    }

    @MainActor
    private func performAction(_ mutation: Mutation, _ operation: () async throws -> Void) async {
        activeMutation = mutation
        actionError = nil
        do {
            try await operation()
            // `state` is already `.loaded` here (every mutation is only reachable once the
            // screen itself is showing loaded content), so this always takes refresh()'s silent
            // background path — never re-shows the loading placeholder.
            await refresh()
        } catch {
            actionError = Self.describe(error)
        }
        activeMutation = nil
    }

    /// CLIENT CORRECTION — real-device diagnostic only, per this task's own "no silent failure"
    /// requirement. No dollar amounts, no secrets, no identifiers beyond role/booleans — just
    /// enough to prove, on a physical device, whether the server-reported role/sharing state
    /// itself is what's missing (vs. a client-side rendering defect further downstream).
    #if DEBUG
    private static func logDebugState(_ response: AccountRelatedOptionsResponse) {
        print("[AccountRelatedOptionsViewModel] loaded — role: \(response.role.map(String.init(describing:)) ?? "nil"), primaryMonthlySavingsShared: \(response.primaryMonthlySavingsShared), primaryMonthlyPlanShared: \(response.primaryMonthlyPlanShared), primarySharedConnectedAccountsCount: \(response.primarySharedConnectedAccounts.count)")
    }
    #else
    private static func logDebugState(_ response: AccountRelatedOptionsResponse) {}
    #endif

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Sharing is not available right now."
            case .unauthorized: return "You need to sign in again to manage sharing."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}
