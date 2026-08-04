import Foundation
import Observation

/// Drives the PHASE 8D automatic pending-invitation discovery popup. A single instance is
/// created once at app root (mirroring `AccountRelatedOptionsViewModel`'s own lifecycle) and
/// injected via `.environment`.
///
/// ONE CHECK PER SESSION TRANSITION: `checkForPendingInvitation()` is a no-op once `state` has
/// left `.idle` — the caller (`RootView`'s own `.task`, which itself only re-runs when a NEW
/// session resolves) is what provides "once per sign-in/launch", not repeated polling from
/// within this type. `reset()` (called on sign-out, mirroring `AccountRelatedOptionsViewModel
/// .reset()`) returns `state` to `.idle` so the NEXT session gets its own fresh check.
///
/// TRUSTED STATE ONLY: `state` is derived exclusively from `get-my-pending-household-invitation`'s
/// response — never inferred locally. "Not Now" (`dismissLocally()`) never contacts the server —
/// the invitation remains genuinely pending and `shouldPresentPopup` will offer it again on the
/// next session transition where it's still valid, per this phase's own locked "Not Now" contract.
@Observable
final class PendingInvitationPopupViewModel {
    enum State {
        case idle
        case checking
        case found(MyPendingInvitationResponse)
        case none
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var isAccepting = false
    private(set) var acceptanceError: String?
    private(set) var didAccept = false
    private(set) var wasDismissedLocally = false
    /// PHASE 8D FOLLOW-UP — real server-side decline (distinct from `dismissLocally()`'s purely
    /// local "Not Now", which never touches the server and lets the invitation reappear next
    /// session). See `decline()`'s own doc comment.
    private(set) var isDeclining = false
    private(set) var declineError: String?
    private(set) var didDecline = false

    private let backend: HouseholdSharingService

    /// Bumped by `reset()` (called on sign-out) — same proven fix as `AccountRelatedOptionsViewModel
    /// .generation`/`AutoBackupManager.generation`. `RootView.task` fires
    /// `Task { await pendingInvitationPopupViewModel.checkForPendingInvitation() }` as a nested,
    /// unstructured `Task` that is NOT cancelled when `RootView` (and the signed-out user's
    /// session) goes away — without this check, a stale in-flight check could resume after
    /// `reset()` and overwrite the freshly-`.idle` state with the OUTGOING user's invitation data.
    private var generation = 0

    init(backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.backend = backend
    }

    /// True only when a genuinely valid (pending, unexpired) invitation was found, acceptance
    /// hasn't already succeeded, decline hasn't already succeeded, and the user hasn't dismissed
    /// it for this session.
    var shouldPresentPopup: Bool {
        guard case .found(let invitation) = state, !didAccept, !didDecline, !wasDismissedLocally else { return false }
        return invitation.status == "pending" && invitation.isExpired != true
    }

    @MainActor
    func checkForPendingInvitation() async {
        guard case .idle = state else { return }
        state = .checking
        let callGeneration = generation
        do {
            let response = try await backend.checkMyPendingInvitation()
            guard callGeneration == generation else { return }
            state = response.found ? .found(response) : .none
        } catch {
            guard callGeneration == generation else { return }
            state = .failed(Self.describe(error))
        }
    }

    /// PHASE 8D FOLLOW-UP — foreground-return discovery (locked Phase 5 requirement: "User B
    /// returns to the foreground after User A sent an invitation while User B's app was
    /// previously open/backgrounded"). Called from `scenePhase` transitioning to `.active` — NOT
    /// a timer, NOT polling: it only ever runs in response to a genuine app-lifecycle event, at
    /// most once per foreground transition.
    ///
    /// Deliberately narrower than `checkForPendingInvitation()`'s own single `.idle`-only guard:
    /// a check already in flight (`.checking`) or a still-valid discovered invitation already
    /// being shown/eligible to show (`shouldPresentPopup`) is left completely alone — re-fetching
    /// either would either race the in-flight request or pointlessly discard a popup the user may
    /// already be looking at. Every OTHER state (`.idle` first-ever run, `.none` from a prior
    /// check that found nothing, `.failed`, or `.found` but already resolved via accept/decline/
    /// dismiss) resets to `.idle` and re-checks — this is what actually surfaces an invitation
    /// that arrived while the app was backgrounded.
    @MainActor
    func recheckOnForegroundIfNeeded() async {
        switch state {
        case .checking:
            return
        case .found where shouldPresentPopup:
            return
        default:
            state = .idle
            await checkForPendingInvitation()
        }
    }

    @MainActor
    func accept() async {
        guard case .found(let invitation) = state, let invitationId = invitation.invitationId, !isAccepting else { return }
        isAccepting = true
        acceptanceError = nil
        do {
            _ = try await backend.acceptInvitation(invitationId: invitationId)
            didAccept = true
        } catch {
            // Never touches `didAccept` on failure — the popup the user was already looking at
            // stays exactly as it was, plus a readable error. `state` itself may still be
            // refreshed below — see that method's own header for why this does not violate that
            // contract.
            acceptanceError = Self.describe(error)
            await refreshIfInvitationMayHaveChanged()
        }
        isAccepting = false
    }

    /// "Not Now" — purely local, never revokes or otherwise touches the invitation server-side.
    @MainActor
    func dismissLocally() {
        wasDismissedLocally = true
    }

    /// Real server-side decline (PHASE 8D FOLLOW-UP) — distinct from `dismissLocally()`'s local
    /// "Not Now". A failed decline never touches `state`/`didDecline` — the popup the user was
    /// already looking at stays exactly as it was, plus a readable error (matching `accept()`'s
    /// own failure-handling discipline, and the locked "a failed Accept or Decline must NOT
    /// silently dismiss the invitation" requirement).
    @MainActor
    func decline() async {
        guard case .found(let invitation) = state, let invitationId = invitation.invitationId, !isDeclining else { return }
        isDeclining = true
        declineError = nil
        do {
            _ = try await backend.declineInvitation(invitationId: invitationId)
            didDecline = true
        } catch {
            declineError = Self.describe(error)
            await refreshIfInvitationMayHaveChanged()
        }
        isDeclining = false
    }

    /// PHASE 8F FOLLOW-UP — after a failed Accept/Decline, the invitation this popup is showing
    /// may have been superseded server-side in the meantime: e.g. the Primary tapped Resend (or
    /// Revoke then re-Invite), which revokes the currently-pending invitation and creates a
    /// brand-new one with a DIFFERENT id (see migration 0008's `resend_invitation` header). `state`
    /// never re-fetches on its own once `.found` (see this type's own header), and
    /// `recheckOnForegroundIfNeeded()` also leaves a stale-but-still-locally-`"pending"` invitation
    /// alone (its `shouldPresentPopup` check only looks at the CACHED response, which still says
    /// "pending" even after the server has moved on) — so before this fix, a stale invitation id
    /// could never self-correct, and "Not Now" was the only way out. Now that "Not Now" is gone,
    /// this is what replaces it: re-run discovery, and ONLY if it finds a genuinely different,
    /// still-valid pending invitation, swap `state` to it so the next Accept/Decline attempt
    /// targets a fresh id. If discovery instead finds nothing, the same invitation, or a failure of
    /// its own, `state` is left completely untouched — preserving the locked "a failed Accept or
    /// Decline must NOT silently dismiss the invitation" contract from PHASE 8D (this never causes
    /// `shouldPresentPopup` to flip to false on its own).
    @MainActor
    private func refreshIfInvitationMayHaveChanged() async {
        guard case .found(let current) = state,
              let response = try? await backend.checkMyPendingInvitation(),
              response.found,
              response.status == "pending",
              response.isExpired != true,
              response.invitationId != current.invitationId
        else { return }
        state = .found(response)
    }

    /// Called on sign-out — see `FinanceTrackApp`'s own sign-out block.
    @MainActor
    func reset() {
        state = .idle
        isAccepting = false
        acceptanceError = nil
        didAccept = false
        wasDismissedLocally = false
        isDeclining = false
        declineError = nil
        didDecline = false
        // Invalidates any `checkForPendingInvitation()` call already in flight before this ran —
        // see `generation`'s own doc comment.
        generation += 1
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HouseholdSharingError {
            switch error {
            case .notConfigured: return "Invitations are not available right now."
            case .unauthorized: return "You need to sign in again to view this invitation."
            case .invalidResponse: return "Unexpected response from the server."
            case .server(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}
