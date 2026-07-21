import Foundation
import Observation

/// A pending household-invitation deep link, captured before the user has necessarily finished
/// signing in. `Identifiable` via the token itself so `PendingInvitationRouter.invitation` can
/// drive a `.fullScreenCover(item:)` directly.
struct PendingHouseholdInvitation: Identifiable, Equatable {
    let token: String
    var id: String { token }
}

/// Recognizes and captures SpendSmart's household-invitation deep link —
/// `spendsmart://household-invitation?token=...` (see `_shared/household.ts`'s
/// `HOUSEHOLD_INVITATION_URL_SCHEME`/`HOUSEHOLD_INVITATION_URL_HOST`, which this must match
/// byte-for-byte). A single instance lives at app root (mirroring every other Phase 5-8 manager's
/// own lifecycle) so the token survives whatever screen was showing when the link was opened —
/// including a sign-out/sign-in round trip if the user wasn't already authenticated (Phase 8's own
/// "logged-out invitation context survives sign-in" requirement). `FinanceTrackApp` only actually
/// presents the invitation screen once `AuthenticationService.sessionState == .signedIn` — see its
/// own `.fullScreenCover` wiring — this type's only job is recognizing the URL and holding the
/// token until that's true.
///
/// NEVER LOGS THE TOKEN — only whether a URL matched this route at all, matching every Edge
/// Function's own no-token-logging discipline.
@Observable
final class PendingInvitationRouter {
    private(set) var invitation: PendingHouseholdInvitation?

    /// Returns `true` if `url` was recognized as (an attempt at) this app's invitation route —
    /// including a malformed one (missing/empty `token`), which is swallowed here rather than
    /// falling through to `AuthenticationService.handle(url:)` (which would otherwise try, and
    /// harmlessly fail, to establish a session from a URL that was never an auth callback).
    /// `false` means "not ours — let the caller's own routing continue."
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "spendsmart",
              url.host?.lowercased() == "household-invitation"
        else { return false }

        #if DEBUG
        print("[PendingInvitationRouter] recognized household-invitation callback: true")
        #endif

        guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "token" })?
            .value,
            !token.isEmpty
        else {
            #if DEBUG
            print("[PendingInvitationRouter] malformed invitation link: missing/empty token")
            #endif
            return true
        }

        invitation = PendingHouseholdInvitation(token: token)
        return true
    }

    /// Called once the invitation screen is dismissed (accepted or "Not Now") and on sign-out —
    /// see `FinanceTrackApp`'s own sign-out block.
    func clear() {
        invitation = nil
    }
}
