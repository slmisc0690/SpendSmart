import Foundation
import Observation
import Supabase

/// Wraps the official Supabase Swift SDK's Auth client for SpendSmart's shared-login model (see
/// the migration plan: one Supabase Auth user == one household's SpendSmart account, and the
/// same email/password may be used on multiple devices to see the same data).
///
/// SECURITY: never logs a password, access token, refresh token, or session — not even in
/// `#if DEBUG` builds. The only thing ever printed is whether an operation succeeded.
///
/// `@MainActor`: every one of this class's state mutations (`sessionState`,
/// `isPasswordRecoveryActive`, etc.) drives SwiftUI view state directly, and this class's async
/// methods all `await` further async SDK calls before mutating that state. Without this
/// annotation, the compiler does not guarantee those mutations happen back on the main thread
/// after such an `await` resumes — a real, timing-dependent bug (more likely to surface on a
/// physical device than the Simulator, which is exactly where it was reported) where a state
/// change like `isPasswordRecoveryActive = true` could be applied off the main thread and SwiftUI
/// would not reliably schedule a re-render for it. Pinning the whole class to `@MainActor`
/// guarantees every `await` inside it resumes back on the main actor.
@MainActor
@Observable
final class AuthenticationService {
    enum SessionState: Equatable {
        case unknown
        case signedOut
        case signedIn
    }

    /// One instance for the whole app — both the SwiftUI environment (for UI state) and
    /// `SupabasePlaidBackendService` (for attaching the current access token to backend calls)
    /// must observe the SAME session, or the UI could show "signed in" while backend calls read a
    /// stale/absent token from a different instance, or vice versa.
    static let shared = AuthenticationService()

    private let client: SupabaseClient

    private(set) var sessionState: SessionState = .unknown
    private(set) var currentUserId: UUID?
    private(set) var currentUserEmail: String?
    private(set) var isEmailVerified = false
    /// True from the moment a password-recovery deep link is handled until `updatePassword`
    /// succeeds (or the user is otherwise routed away — see `clearPasswordRecoveryState`). The
    /// app's top-level routing (`FinanceTrackApp`) checks this BEFORE `sessionState`, so a
    /// recovery callback always lands on `NewPasswordView` rather than the Forgot Password screen
    /// it may have been dispatched from, or the main app, even though `handle(url:)` also
    /// establishes a normal signed-in session as a side effect of completing the recovery flow.
    private(set) var isPasswordRecoveryActive = false

    private var authStateTask: Task<Void, Never>?

    init(client: SupabaseClient = SupabaseClient(
        supabaseURL: SupabaseConfig.projectURL,
        supabaseKey: SupabaseConfig.publishableKey
    )) {
        self.client = client
    }

    /// Call once at launch, alongside `restoreSession()`. Listens for `AuthChangeEvent
    /// .passwordRecovery` as a SECOND, defense-in-depth signal alongside the `type=recovery` URL
    /// parameter `handle(url:)` reads directly — the installed supabase-swift version's PKCE flow
    /// (this project's flow type; every outgoing email-generating call here uses PKCE's
    /// `prepareForPKCE()`) does NOT emit this event from `exchangeCodeForSession` today, only the
    /// implicit-grant flow does. Reading the URL parameter is therefore the RELIABLE signal for
    /// this SDK version; this listener exists so a future SDK version that starts emitting it for
    /// PKCE too is picked up automatically without another code change.
    func startObservingAuthEvents() {
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in client.auth.authStateChanges {
                if event == .passwordRecovery {
                    isPasswordRecoveryActive = true
                    if let session {
                        apply(session: session)
                    }
                    #if DEBUG
                    print("[AuthenticationService] recovery state activated: true (SDK event)")
                    #endif
                }
            }
        }
    }

    /// Call once at launch — restores a previously persisted session (the SDK keeps it in the
    /// Keychain) without requiring the user to sign in again.
    func restoreSession() async {
        do {
            let session = try await client.auth.session
            apply(session: session)
            #if DEBUG
            print("[AuthenticationService] session restored: true")
            #endif
        } catch {
            clearLocalSession()
            #if DEBUG
            print("[AuthenticationService] session restored: false")
            #endif
        }
    }

    func signUp(email: String, password: String) async throws {
        let response = try await client.auth.signUp(
            email: email,
            password: password,
            redirectTo: SupabaseConfig.authCallbackURL
        )
        #if DEBUG
        print("[AuthenticationService] sign-up succeeded: true")
        #endif
        switch response {
        case .session(let session):
            // Email confirmation is disabled for this project, or already satisfied — signed in
            // immediately.
            apply(session: session)
        case .user:
            // Email confirmation is required — no session yet. sessionState stays whatever it
            // was (.signedOut for a fresh sign-up); the Verify Email screen drives the rest.
            break
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await client.auth.signIn(email: email, password: password)
        apply(session: session)
        #if DEBUG
        print("[AuthenticationService] sign-in succeeded: true")
        #endif
    }

    func signOut() async throws {
        try await client.auth.signOut()
        clearLocalSession()
        // An explicit sign-out is the "user explicitly cancels the recovery flow" case referenced
        // in `isPasswordRecoveryActive`'s doc comment — deliberately NOT part of
        // `clearLocalSession()` itself, since that helper also runs from `restoreSession()`'s
        // failure path, which must NOT clear an in-progress recovery (see that method).
        isPasswordRecoveryActive = false
        #if DEBUG
        print("[AuthenticationService] sign-out succeeded: true")
        #endif
    }

    /// `redirectTo` is `SupabaseConfig.passwordResetCallbackURL`, NOT the plain
    /// `authCallbackURL` used by sign-up/resend — see that constant's doc comment for why: PKCE
    /// (this project's flow) redirects carry no `type` signal from Supabase itself, so the
    /// `flow=recovery` marker baked into this URL is what `handle(url:)` actually detects.
    func resetPassword(email: String) async throws {
        try await client.auth.resetPasswordForEmail(
            email,
            redirectTo: SupabaseConfig.passwordResetCallbackURL
        )
        #if DEBUG
        print("[AuthenticationService] password reset email requested: true")
        print("[PasswordReset] request succeeded")
        #endif
    }

    /// The signed-in user's current access token, to attach as `Authorization: Bearer <token>` on
    /// every authenticated backend call (see `SupabasePlaidBackendService`). NEVER logged, NEVER
    /// printed — not even the fact that this was called, since the call sites themselves already
    /// log what they need.
    func currentAccessToken() async throws -> String {
        try await client.auth.session.accessToken
    }

    /// Resends the sign-up confirmation email — used by the Verify Email screen's "Resend
    /// Verification Email" button. Supabase deliberately succeeds even for an email that doesn't
    /// exist (avoids leaking which emails are registered), so this never reveals that either.
    func resendVerificationEmail(email: String) async throws {
        try await client.auth.resend(
            email: email,
            type: .signup,
            emailRedirectTo: SupabaseConfig.authCallbackURL
        )
        #if DEBUG
        print("[AuthenticationService] verification email resend requested: true")
        #endif
    }

    /// Re-checks whether the current user's email is now verified — used by Verify Email's
    /// "I've Verified My Email" button. Fetches the user afresh from Supabase Auth (not just the
    /// locally cached session) so a confirmation done via the emailed link is picked up.
    @discardableResult
    func refreshVerificationStatus() async throws -> Bool {
        let user = try await client.auth.user()
        currentUserId = user.id
        currentUserEmail = user.email
        isEmailVerified = user.emailConfirmedAt != nil
        // A fresh `user()` call implies a valid session exists; reflect that too in case this is
        // called right after a deep-link confirmation that this instance hasn't seen yet.
        sessionState = .signedIn
        #if DEBUG
        print("[AuthenticationService] verification status refreshed, verified:", isEmailVerified)
        #endif
        return isEmailVerified
    }

    /// Completes a session from an incoming deep link (password reset or email confirmation
    /// redirect) — call from the app's `.onOpenURL`. See `SupabaseConfig` / `resetPassword`'s
    /// `redirectTo` for the URL scheme this expects.
    ///
    /// CALLBACK TYPE DETECTION — this project uses the PKCE flow (the supabase-swift SDK's
    /// default; every outgoing email-generating call here uses `prepareForPKCE()` internally).
    /// Reading GoTrue's own server source (`internal/api/verify.go`, `prepPKCERedirectURL`)
    /// confirms that for PKCE, Supabase's redirect contains ONLY `code=<code>` — never a `type`
    /// parameter, in the query string OR a fragment, unlike the older implicit-grant flow. An
    /// earlier version of this method tried to read `type=recovery` from the callback URL, which
    /// worked against a server-side test built on `admin.generateLink` (implicit-flow-shaped, so
    /// it DOES carry `type`) but silently never fired for a REAL on-device PKCE reset, since that
    /// redirect never carries the parameter at all — confirmed live against this project by
    /// resetting a real password and observing the actual callback URL only ever contains `code`.
    ///
    /// The fix: `resetPassword(email:)` passes `SupabaseConfig.passwordResetCallbackURL`, which
    /// has our OWN `flow=recovery` query parameter baked in. `prepPKCERedirectURL` preserves
    /// whatever query parameters were already present on `redirectTo` (confirmed by reading its
    /// source) and Supabase's redirect-URL allow list accepts a `redirectTo` with a query string
    /// unmodified (confirmed live), so `flow=recovery` survives all the way to the callback this
    /// method receives — checked here as the PRIMARY signal. Supabase's own `type` parameter is
    /// still checked too (both fragment and query) as defense-in-depth for any callback shape that
    /// isn't this project's own PKCE reset flow (e.g. a future SDK version, or an admin-generated
    /// link used for support).
    func handle(url: URL) async {
        let isRecovery = Self.isRecoveryCallback(url)

        // Structural fields only — scheme/host/classification, never the path/query/fragment,
        // which is exactly where the confirmation code or tokens live.
        #if DEBUG
        print("[AuthenticationService] callback received: true")
        print("[AuthenticationService] callback scheme:", url.scheme ?? "nil")
        print("[AuthenticationService] callback host:", url.host ?? "nil")
        print("[AuthCallback] type=\(isRecovery ? "recovery" : "other")")
        #endif

        do {
            let session = try await client.auth.session(from: url)
            apply(session: session)
            #if DEBUG
            print("[AuthCallback] session established=true")
            #endif
            if isRecovery {
                // Set AFTER apply(session:) and never touched by it — see this property's own doc
                // comment and `clearPasswordRecoveryState` for the only two places this is ever
                // cleared. This line does not clear it; there is intentionally no `else` branch
                // that would reset it for a non-recovery callback.
                isPasswordRecoveryActive = true
            }
            #if DEBUG
            print("[AuthenticationService] auth callback handled successfully: true")
            print("[AuthCallback] passwordRecoveryActive=\(isPasswordRecoveryActive)")
            #endif
        } catch {
            #if DEBUG
            print("[AuthenticationService] auth callback handled successfully: false")
            print("[AuthCallback] session established=false")
            print("[AuthCallback] passwordRecoveryActive=\(isPasswordRecoveryActive)")
            #endif
        }
    }

    /// True if this project's own `flow=recovery` marker (see `SupabaseConfig
    /// .passwordResetCallbackURL`) is present, OR — defense-in-depth only, see `handle(url:)`'s
    /// doc comment — Supabase's own `type=recovery` parameter is present in either the fragment or
    /// the query string.
    private static func isRecoveryCallback(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        if components.queryItems?.first(where: { $0.name == "flow" })?.value == "recovery" {
            return true
        }
        return extractTypeParam(from: components) == "recovery"
    }

    /// Reads `type` from a deep-link callback URL, checking the FRAGMENT first, then the query
    /// string — the same order and the same two locations the installed supabase-swift SDK's own
    /// `extractParams(from:)` checks internally.
    private static func extractTypeParam(from components: URLComponents) -> String? {
        if let fragment = components.fragment, !fragment.isEmpty,
           let fragmentComponents = URLComponents(string: "?\(fragment)"),
           let type = fragmentComponents.queryItems?.first(where: { $0.name == "type" })?.value {
            return type
        }
        return components.queryItems?.first(where: { $0.name == "type" })?.value
    }

    /// Updates the signed-in (recovery-session) user's password — call from `NewPasswordView`
    /// after `handle(url:)` has established a session from the recovery link. Requires an active
    /// session, which the recovery link's `session(from:)` call already provides.
    func updatePassword(_ newPassword: String) async throws {
        do {
            try await client.auth.update(user: UserAttributes(password: newPassword))
            #if DEBUG
            print("[AuthenticationService] password update success: true")
            #endif
            clearPasswordRecoveryState()
        } catch {
            #if DEBUG
            print("[AuthenticationService] password update success: false")
            #endif
            throw error
        }
    }

    /// Ends the password-recovery routing override — called after a successful password update,
    /// or if the user backs out of `NewPasswordView` some other way. Does NOT sign the user out:
    /// the recovery link already established a real session, and `FinanceTrackApp`'s routing
    /// falls through to the normal signed-in/unverified/verified tiers once this is false.
    func clearPasswordRecoveryState() {
        isPasswordRecoveryActive = false
    }

    /// Calls the `delete-account` Edge Function (which deletes every owned row plus the
    /// `auth.users` record itself via the Admin API — service-role only, server-side), then signs
    /// out locally. Irreversible — the UI must get a strong, typed confirmation before calling
    /// this (see `AccountView`'s "DELETE" confirmation).
    func deleteAccount() async throws {
        let accessToken = try await currentAccessToken()
        var request = URLRequest(url: SupabaseConfig.projectURL.appendingPathComponent("functions/v1/delete-account"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, urlResponse) = try await URLSession.shared.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw AccountDeletionError.serverError
        }
        #if DEBUG
        print("[AuthenticationService] account deletion succeeded: true")
        #endif

        try await client.auth.signOut()
        clearLocalSession()
        // Same reasoning as `signOut()` — deletion is another explicit, user-initiated exit from
        // whatever state the app was in, recovery included.
        isPasswordRecoveryActive = false
    }

    private func apply(session: Session) {
        currentUserId = session.user.id
        currentUserEmail = session.user.email
        isEmailVerified = session.user.emailConfirmedAt != nil
        sessionState = .signedIn
    }

    /// Deliberately does NOT touch `isPasswordRecoveryActive` — this runs from
    /// `restoreSession()`'s failure path (no persisted session found/valid at launch), which must
    /// never clear an in-progress recovery a concurrent `handle(url:)` call may have just
    /// activated. The only places that ever clear it are `clearPasswordRecoveryState()` (recovery
    /// succeeded) and the explicit `signOut()`/`deleteAccount()` call sites above.
    private func clearLocalSession() {
        sessionState = .signedOut
        currentUserId = nil
        currentUserEmail = nil
        isEmailVerified = false
    }
}

enum AccountDeletionError: FriendlyError {
    case serverError

    var errorDescription: String? {
        "We couldn't delete your account right now. Please try again."
    }
}

/// Marks an error type whose `errorDescription` is ALREADY a short, friendly, user-facing message
/// — `friendlyAuthMessage` below returns it verbatim instead of pattern-matching it as if it were
/// raw SDK/network text (which could otherwise mangle an already-good message).
protocol FriendlyError: LocalizedError {}

/// Maps a thrown auth error to a short, friendly message — never the raw SDK/network error text,
/// which can be technical (and, for some failure modes, echo back request details).
extension Error {
    var friendlyAuthMessage: String {
        if let friendly = self as? FriendlyError {
            return friendly.errorDescription ?? "Something went wrong. Please try again."
        }
        let description = (self as? LocalizedError)?.errorDescription ?? localizedDescription
        let lowercased = description.lowercased()
        if lowercased.contains("invalid login credentials") {
            return "Incorrect email or password."
        }
        if lowercased.contains("user already registered") || lowercased.contains("already registered") {
            return "An account with this email already exists."
        }
        if lowercased.contains("email not confirmed") {
            return "Please verify your email before signing in."
        }
        if lowercased.contains("rate limit") {
            return "Too many attempts. Please wait a moment and try again."
        }
        if lowercased.contains("network") || lowercased.contains("offline") || lowercased.contains("connection") {
            return "No connection. Check your internet and try again."
        }
        return "Something went wrong. Please try again."
    }
}
