import Foundation

/// Where the SpendSmart Supabase project lives, and the key this app is allowed to hold.
///
/// SECURITY: `publishableKey` (the new `sb_publishable_...` format, replacing the legacy `anon`
/// JWT) is DESIGNED to be public — it identifies the project, nothing more. Row Level Security is
/// what actually protects data, not secrecy of this key. This app must NEVER hold, embed, or log:
/// - a `service_role` key or the new `sb_secret_...` format (server-side only, inside Edge
///   Functions — see `supabase/functions/_shared/plaid.ts`)
/// - a Plaid client secret or access token (see `PlaidBackendService.swift`)
enum SupabaseConfig {
    /// Always the live SpendSmart project — the value every Release build uses, and what a
    /// normal (non-Preview) Debug build uses too. Never read directly outside this file; every
    /// other call site goes through `projectURL`/`publishableKey` below.
    private static let productionProjectURL = URL(string: "https://dlqjgpgnaguhubftfpel.supabase.co")!
    private static let productionPublishableKey = "sb_publishable_pNfuwRI2N_br5vtzQ75krw_0MRlDrpj"

    #if DEBUG && SPENDSMART_PREVIEW_BACKEND
    // DEBUG-ONLY PREVIEW BACKEND SELECTION — reachable only from the "FinanceTrack Preview"
    // Xcode scheme (project.yml's "Debug Preview" configuration is the only place
    // SPENDSMART_PREVIEW_BACKEND is ever defined). The `DEBUG &&` half of this condition is
    // deliberate belt-and-suspenders: Release never defines DEBUG, so this branch is structurally
    // unreachable in a Release build even if SPENDSMART_PREVIEW_BACKEND were ever mistakenly set
    // there too — two independent reasons Release can never see Preview, not one.
    //
    // `phase2-sharing-test` (Preview branch of the SpendSmart project, ref kzyvkywpnfvxlgvrgkpm).
    // Its publishable key is the SAME kind of public, non-secret identifier as the Production one
    // above (see this enum's own header) — safe to commit.
    static let projectURL = URL(string: "https://kzyvkywpnfvxlgvrgkpm.supabase.co")!
    static let publishableKey = "sb_publishable_1Sz2NV3VXDFPuTCS960GcQ_9yJaL4cP"
    static let environmentLabel = "Preview — kzyvkywpnfvxlgvrgkpm"
    #else
    static let projectURL = productionProjectURL
    static let publishableKey = productionPublishableKey
    static let environmentLabel = "Production — dlqjgpgnaguhubftfpel"
    #endif

    /// This app's custom URL scheme callback, registered in `project.yml`'s `CFBundleURLTypes`
    /// and in Supabase's `additional_redirect_urls`. Passed EXPLICITLY to every Supabase Auth call
    /// that sends an email with a link (`signUp`, `resend`, `resetPasswordForEmail`) — none of
    /// them fall back to this on their own. Left unset, the SDK falls back to
    /// `SupabaseClientOptions.AuthOptions.redirectToURL` (also unset here), which then falls back
    /// to the project's dashboard-configured Site URL — `http://127.0.0.1:3000` for this project,
    /// a local dev placeholder that can never open the app. That mismatch is exactly what sent
    /// verification/reset links to `redirect_to=http://127.0.0.1:3000` instead of this scheme.
    static let authCallbackURL = URL(string: "spendsmart://auth-callback")!

    /// `resetPassword`'s `redirectTo` specifically — same scheme/host as `authCallbackURL`, plus
    /// our OWN `flow=recovery` query parameter.
    ///
    /// WHY a separate URL is required (not just reusing `authCallbackURL` and reading Supabase's
    /// `type` param, as an earlier version of this code did): this project's Supabase Auth calls
    /// use the PKCE flow (the SDK's default — confirmed by reading the installed supabase-swift
    /// source, `prepareForPKCE()` is called internally by `resetPasswordForEmail`). Reading
    /// GoTrue's own server source (`internal/api/verify.go`, `prepPKCERedirectURL`) confirms the
    /// PKCE code-exchange redirect is built with ONLY `code=<code>` — Supabase does NOT append
    /// `type=recovery` (or anything else) to a PKCE redirect the way it does for the older
    /// implicit-grant flow. So there is no signal from Supabase itself, in the fragment OR the
    /// query string, that a given PKCE callback is a password-reset rather than a normal sign-in —
    /// `AuthenticationService.handle(url:)` has to supply its own. `prepPKCERedirectURL` DOES
    /// preserve whatever query parameters were already on `redirectTo` (confirmed by reading its
    /// source: it parses `redirect_to`'s existing query, sets `code` alongside it, then
    /// re-encodes) and confirmed live against this project that a `redirectTo` with a query string
    /// is accepted by the redirect-URL allow-list unmodified — so appending our own `flow=recovery`
    /// here is a reliable, project-controlled substitute for the signal Supabase doesn't provide.
    static let passwordResetCallbackURL = URL(string: "spendsmart://auth-callback?flow=recovery")!
}
