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
@Observable
final class AccountRelatedOptionsViewModel {
    enum LoadState {
        case idle
        case loading
        case loaded(AccountRelatedOptionsResponse)
        case failed(String)
    }

    enum Visibility: Equatable {
        /// Role not yet resolved, or resolved to Secondary — the row/screen must not appear.
        case hidden
        /// Resolved: no household yet — show only the "set up household sharing" entry point.
        case entryPoint
        /// Resolved: active Primary — show the full Account Related Options screen.
        case primary
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

    /// Convenience for call sites that only need "is anything in flight right now" (e.g. the
    /// entry-point button, which has no other control competing for attention).
    var isPerformingAction: Bool { activeMutation != nil }

    private let backend: HouseholdSharingService

    init(backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.backend = backend
    }

    var visibility: Visibility {
        guard case .loaded(let response) = state else { return .hidden }
        switch response.role {
        case .primary: return .primary
        case .secondary: return .hidden
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
    }

    /// Shows the loading placeholder only on the very first call (while `state` is not yet
    /// `.loaded`) — every later call (sheet re-presented, or the silent re-fetch after a
    /// mutation) fetches in the background and never blanks already-loaded content. See this
    /// type's own header for the full reasoning.
    @MainActor
    func refresh() async {
        guard case .loaded = state else {
            state = .loading
            do {
                let response = try await backend.getAccountRelatedOptions()
                state = .loaded(response)
                if response.pendingInvitation == nil { lastInvitationUrl = nil }
            } catch {
                state = .failed(Self.describe(error))
            }
            return
        }
        do {
            let response = try await backend.getAccountRelatedOptions()
            state = .loaded(response)
            // The invitation was accepted/revoked/expired (elsewhere, or by this same refresh
            // following a mutation) — a share link pointing at it would now be dead. Phase 12's
            // own "pending invitation disappears/updates after acceptance" requirement.
            if response.pendingInvitation == nil { lastInvitationUrl = nil }
        } catch {
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

    @MainActor
    func setGlobalSharing(category: String, isShared: Bool) async {
        let mutation: Mutation = switch category {
        case "connectedAccounts": .connectedGlobal
        case "manualAccounts": .manualGlobal
        default: .monthlyPlan
        }
        await performAction(mutation) {
            _ = try await backend.updateSharingPermission(
                SharingPermissionUpdateRequest(category: category, itemId: nil, isShared: isShared)
            )
        }
    }

    @MainActor
    func setItemSharing(category: String, itemId: UUID, isShared: Bool) async {
        let mutation: Mutation = category == "connectedAccounts" ? .connectedItem(itemId) : .manualItem(itemId)
        await performAction(mutation) {
            _ = try await backend.updateSharingPermission(
                SharingPermissionUpdateRequest(category: category, itemId: itemId.uuidString, isShared: isShared)
            )
        }
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
