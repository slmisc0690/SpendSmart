import Foundation
import Observation

/// Drives the Phase 8 Secondary invitation acceptance screen. One instance per presentation
/// (unlike `AccountRelatedOptionsViewModel`, this is never shared app-wide — a new invitation
/// screen always starts from a fresh, unambiguous token).
///
/// TRUSTED STATE ONLY: `state`/`didAccept` are derived exclusively from
/// `get-household-invitation-preview`/`accept-household-invitation` responses — this view model
/// never infers validity, expiry, or acceptance locally. Both calls are authenticated (the same
/// `currentAccessToken()` bearer pattern as every other backend call in this app); the token
/// itself is the ONLY invitation-identifying value ever sent — no household id, no email.
@Observable
final class InvitationAcceptanceViewModel {
    enum LoadState {
        case loading
        case loaded(InvitationPreviewResponse)
        case failed(String)
    }

    let token: String

    private(set) var state: LoadState = .loading
    private(set) var isAccepting = false
    private(set) var acceptanceError: String?
    private(set) var didAccept = false

    private let backend: HouseholdSharingService

    init(token: String, backend: HouseholdSharingService = SupabaseHouseholdSharingService()) {
        self.token = token
        self.backend = backend
    }

    /// True only when the preview loaded successfully, the invitation was found (i.e. addressed
    /// to the caller's own verified email — see `preview_household_invitation`'s own header for
    /// why an unrelated caller's token always looks like `found: false`), is still `pending`, and
    /// has not expired. Accept is only ever offered when this is true.
    var canAccept: Bool {
        guard case .loaded(let preview) = state else { return false }
        return preview.found && preview.status == "pending" && preview.isExpired != true
    }

    @MainActor
    func loadPreview() async {
        state = .loading
        do {
            let response = try await backend.previewInvitation(token: token)
            state = .loaded(response)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    @MainActor
    func accept() async {
        guard canAccept, !isAccepting else { return }
        isAccepting = true
        acceptanceError = nil
        do {
            _ = try await backend.acceptInvitation(token: token)
            didAccept = true
        } catch {
            // Never touches `state`/`didAccept` on failure — the preview screen the user was
            // already looking at stays exactly as it was, plus a readable error.
            acceptanceError = Self.describe(error)
        }
        isAccepting = false
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
