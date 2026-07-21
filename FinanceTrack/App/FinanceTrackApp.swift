import SwiftUI
import SwiftData

@main
struct FinanceTrackApp: App {
    @State private var privacyMode = PrivacyModeManager()
    @State private var biometricAuth = BiometricAuthManager()
    @State private var autoBackupManager = AutoBackupManager()
    /// Phase 5 — Manual Account/Transaction cloud sync foundation. See its own doc comment for why
    /// it mirrors `AutoBackupManager`'s observe-`ModelContext.didSave` shape rather than
    /// instrumenting every add/edit/delete call site.
    @State private var manualDataCloudSyncManager = ManualDataCloudSyncManager()
    /// Phase 6 — Monthly Plan cloud sync foundation. A separate manager from
    /// `manualDataCloudSyncManager` — see its own doc comment for why.
    @State private var monthlyPlanCloudSyncManager = MonthlyPlanCloudSyncManager()
    /// Phase 7 — Account Related Options / Primary sharing controls. Drives both the sheet's own
    /// data and the Primary-only visibility gate for its Settings row — see its own doc comment
    /// for why role resolution must come only from the server, never local state.
    @State private var accountRelatedOptionsViewModel = AccountRelatedOptionsViewModel()
    /// Phase 8 — captures a `spendsmart://household-invitation` deep link, surviving a
    /// sign-out/sign-in round trip if the user wasn't already authenticated when they opened it.
    @State private var pendingInvitationRouter = PendingInvitationRouter()
    /// Owns the per-authenticated-user isolated SwiftData store and namespaced
    /// `PlaidConnectionManager` — replaces the old single app-wide `sharedModelContainer`/
    /// `plaidConnection` instances (see Phase 3 local user-data isolation). Never exposes a
    /// container/manager for any user other than whichever `resolve(for:)` most recently
    /// succeeded for.
    @State private var userDataStore = UserDataStoreManager()
    // `.shared`, not a fresh instance — see AuthenticationService's doc comment for why there
    // must be exactly one app-wide session (both the UI and SupabasePlaidBackendService's default
    // token provider read from this same instance).
    private let authService = AuthenticationService.shared

    @Environment(\.scenePhase) private var scenePhase

    /// DEBUG-only marker printed once at launch, before anything else, so that "is the build I
    /// just installed actually the build that's running" can be answered by reading the Xcode
    /// console rather than assumed — bump the suffix whenever this needs re-confirming after a
    /// physical-device install.
    init() {
        #if DEBUG
        print("[SpendSmartBuild] auth-recovery-ui-v2")
        print("[SpendSmartBuild] plaid-connection-restore-v2")
        print("[SpendSmartBuild] manual-spending-controls-v1")
        print("[SpendSmartBuild] manual-account-ux-v1")
        print("[SpendSmartBuild] currency-toolbar-polish-v1")
        print("[SpendSmartBuild] currency-accessory-removed-v1")
        print("[SpendSmartBuild] per-user-local-isolation-v1")
        #endif
    }

    /// Only ever non-nil once the user is fully signed in and email-verified — a link opened
    /// while signed out (or mid-verification) stays captured in `pendingInvitationRouter` but the
    /// cover does not appear until the normal sign-in flow completes on its own, at which point
    /// this binding starts surfacing it (Phase 8's own "logged-out invitation context survives
    /// sign-in" / "after successful sign-in, continue to invitation validation" requirements).
    /// Setting this to `nil` (the cover's own dismiss gesture) clears the router the same way
    /// `InvitationAcceptanceView`'s own `onFinished` does.
    private var pendingInvitationBinding: Binding<PendingHouseholdInvitation?> {
        Binding(
            get: {
                guard authService.sessionState == .signedIn, authService.isEmailVerified else { return nil }
                return pendingInvitationRouter.invitation
            },
            set: { newValue in
                if newValue == nil {
                    pendingInvitationRouter.clear()
                }
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Routing priority, top to bottom — a password-recovery callback overrides
                // whatever the app was showing before it (including the main app, if the link
                // was tapped while already signed in), which is exactly the bug this ordering
                // fixes: recovery used to fall through to whatever screen was already on top
                // (e.g. Forgot Password) because nothing checked for it ahead of sessionState.
                Group {
                    if authService.sessionState == .unknown {
                        // Restoring a persisted session (Keychain-backed by the SDK) — shown only
                        // for the brief moment before restoreSession() resolves one way or the
                        // other, so a signed-in user never sees a flash of the sign-in screen.
                        AuthLoadingView()
                    } else if authService.isPasswordRecoveryActive {
                        NewPasswordView()
                    } else if authService.sessionState == .signedOut {
                        AuthFlowView()
                    } else if !authService.isEmailVerified {
                        VerifyEmailView(
                            email: authService.currentUserEmail ?? "",
                            // No password is available on a fresh launch into this state (only
                            // CreateAccountView's in-memory hand-off carries one) — harmless here,
                            // since sessionState is already .signedIn by construction whenever
                            // this branch renders, so VerifyEmailView's own sessionState check
                            // never takes the password-dependent retry-sign-in path.
                            password: "",
                            onBackToSignIn: { Task { try? await authService.signOut() } }
                        )
                    } else if let userId = authService.currentUserId,
                              userDataStore.resolvedUserId == userId,
                              let container = userDataStore.modelContainer,
                              let plaidConnection = userDataStore.plaidConnectionManager {
                        RootView()
                            .modelContainer(container)
                            .environment(privacyMode)
                            .environment(biometricAuth)
                            .environment(plaidConnection)
                            .environment(autoBackupManager)
                            .environment(manualDataCloudSyncManager)
                            .environment(monthlyPlanCloudSyncManager)
                            .environment(accountRelatedOptionsViewModel)
                    } else if let userId = authService.currentUserId, let error = userDataStore.lastResolutionError {
                        // resolve(for:) failed for the currently-authenticated user — surfaced
                        // here so this can never regress into a permanent blank/loading screen
                        // with no way out. "Try Again" re-runs resolve(for:) directly (safe to
                        // call repeatedly; it re-checks/clears its own error state each attempt).
                        LocalStoreResolutionErrorView(message: error) {
                            Task { await userDataStore.resolve(for: userId) }
                        }
                    } else {
                        // Signed in and email-verified, but this authenticated user's isolated
                        // local store (and namespaced Plaid state) hasn't finished resolving yet
                        // — see `UserDataStoreManager.resolve(for:)` below. Never falls through to
                        // RootView here: that would risk rendering @Query screens against no
                        // container, a stale container, or (if this ever regressed) another user's
                        // container.
                        AuthLoadingView()
                    }
                }
                .environment(authService)
                // Available to every branch (including CreateAccountView, pre-sign-in) — not
                // just RootView's own explicit re-application below, which stays for clarity/
                // explicitness there but is otherwise redundant with this one.
                .environment(biometricAuth)
                .task {
                    authService.startObservingAuthEvents()
                    await authService.restoreSession()
                }
                .task(id: authService.currentUserId) {
                    guard authService.sessionState == .signedIn,
                          authService.isEmailVerified,
                          let userId = authService.currentUserId
                    else { return }
                    await userDataStore.resolve(for: userId)
                }
                .onChange(of: authService.sessionState) { _, newValue in
                    if newValue == .signedOut {
                        // Stop AutoBackupManager FIRST — it holds its own NotificationCenter
                        // observer and debounced Task directly referencing the outgoing user's
                        // ModelContext, entirely independent of userDataStore's own bookkeeping.
                        // Only the next user's RootView.task re-arms it for a new context; nothing
                        // else ever stops it, so leaving this out lets a debounced backup fire
                        // against a context whose owning container is being released below.
                        autoBackupManager.stopObserving()
                        // Same reasoning as AutoBackupManager immediately above — must stop before
                        // userDataStore.detach() below releases the outgoing user's container.
                        manualDataCloudSyncManager.stopObserving()
                        monthlyPlanCloudSyncManager.stopObserving()
                        // Detach only — never deletes this user's on-disk store or UserDefaults
                        // namespace, so signing back in (as this user or anyone else) finds
                        // everything exactly as it was left.
                        userDataStore.detach()
                        // Reset the in-memory Face ID gate too — without this, a brief window
                        // exists (between this sign-out and the next user's RootView re-setting
                        // both from THEIR OWN settings.requireFaceID) where the outgoing user's
                        // stale isFaceIDRequired/isUnlocked values could otherwise linger. This
                        // makes "User A's Face ID must never affect User B" true by construction
                        // rather than by incidental timing.
                        biometricAuth.isFaceIDRequired = false
                        biometricAuth.isUnlocked = false
                        // Phase 7 — clears cached role state (see its own reset() doc comment).
                        accountRelatedOptionsViewModel.reset()
                        // Phase 8 — clears any pending invitation so it can never resurface for a
                        // different user who signs in next.
                        pendingInvitationRouter.clear()
                    }
                }
                .onOpenURL { url in
                    // Single dispatch point for every URL this app can be opened with. Checked
                    // FIRST of all: a household-invitation link must never reach
                    // AuthenticationService.handle(url:) (which unconditionally attempts to
                    // establish a Supabase session from whatever URL it receives) — both share the
                    // `spendsmart://` scheme, distinguished only by host.
                    if pendingInvitationRouter.handle(url: url) {
                        return
                    }

                    // A Plaid OAuth return must never be handed to AuthenticationService.handle(url:)
                    // either, for the same reason.
                    if PlaidOAuthReturn.matches(url) {
                        // Never log the full URL — Plaid's OAuth return can carry state/query
                        // parameters. Only confirms recognition, matching this project's existing
                        // safe-logging convention (see AuthenticationService.handle(url:)'s own
                        // structural-fields-only logging).
                        #if DEBUG
                        print("[PlaidOAuthReturn] recognized Plaid OAuth callback: true")
                        #endif
                        userDataStore.plaidConnectionManager?.handlePlaidOAuthReturn()
                        return
                    }

                    // Password-reset / email-confirmation deep link callback — see
                    // AuthenticationService.resetPassword's redirectTo and SupabaseConfig. Fires
                    // whether the app was already running (foreground or background) or launched
                    // fresh by tapping the link — `.onOpenURL` covers both.
                    Task { await authService.handle(url: url) }
                }
                .fullScreenCover(item: pendingInvitationBinding) { invitation in
                    InvitationAcceptanceView(token: invitation.token) {
                        pendingInvitationRouter.clear()
                    }
                    .environment(accountRelatedOptionsViewModel)
                }

                // Only over the actual main app — not the recovery, verify-email, or auth
                // screens, none of which are gated by device Face ID in the first place.
                if authService.sessionState == .signedIn,
                   !authService.isPasswordRecoveryActive,
                   authService.isEmailVerified,
                   biometricAuth.isFaceIDRequired,
                   !biometricAuth.isUnlocked {
                    AppLockView()
                        .environment(biometricAuth)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: biometricAuth.isUnlocked)
            .animation(.easeInOut(duration: 0.25), value: authService.sessionState)
            .animation(.easeInOut(duration: 0.25), value: authService.isPasswordRecoveryActive)
            .animation(.easeInOut(duration: 0.25), value: authService.isEmailVerified)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background, biometricAuth.isFaceIDRequired {
                biometricAuth.lock()
            }
        }
    }
}

/// Shown only while `AuthenticationService.restoreSession()` is resolving at launch.
private struct AuthLoadingView: View {
    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            ProgressView()
                .tint(Theme.accent)
                .scaleEffect(1.2)
        }
        .preferredColorScheme(.dark)
    }
}

/// Shown when `UserDataStoreManager.resolve(for:)` has failed for the currently-authenticated
/// user — the recoverable alternative to letting the app fall through to a silent, permanent
/// `AuthLoadingView()` with no way out. `onRetry` re-invokes `resolve(for:)` directly.
private struct LocalStoreResolutionErrorView: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.statusOver)

                Text("Couldn't load your data")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                Text(message)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.lg)

                PremiumActionButton(title: "Try Again", action: onRetry)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.sm)
            }
            .padding(Theme.Spacing.lg)
        }
        .preferredColorScheme(.dark)
    }
}

/// Root tab container for the app's primary screens. Also owns first-run bootstrapping:
/// a default `BudgetSettings` record and the standard `Category` set are created once if none
/// exist, so expense entry always has categories to pick from. No sample/demo transactions are
/// ever inserted here — only settings and taxonomy. A brand-new user's `BudgetSettings` starts
/// with a $0 weekly limit (see `bootstrapDefaultSettingsIfNeeded`) — deliberately not a nonzero
/// default, so a fresh account never shows spending room it was never actually given.
private struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [BudgetSettings]
    @Query private var categories: [Category]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(BiometricAuthManager.self) private var biometricAuth
    @Environment(AutoBackupManager.self) private var autoBackupManager
    @Environment(ManualDataCloudSyncManager.self) private var manualDataCloudSyncManager
    @Environment(MonthlyPlanCloudSyncManager.self) private var monthlyPlanCloudSyncManager
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel
    @Environment(AuthenticationService.self) private var authService

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2.fill") }

            WeeklyBudgetView()
                .tabItem { Label("Weekly", systemImage: "calendar") }

            ExpenseListView()
                .tabItem { Label("Activity", systemImage: "list.bullet") }

            AccountListView()
                .tabItem { Label("Manual Accounts", systemImage: "creditcard.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
        .task {
            let freshlyCreatedSettings = bootstrapDefaultSettingsIfNeeded()
            bootstrapDefaultCategoriesIfNeeded()
            bootstrapDefaultMonthlyPlanSettingsIfNeeded()
            autoBackupManager.startObserving(context: modelContext)
            // RootView only ever renders once userDataStore.resolvedUserId == authService
            // .currentUserId (see this file's own gating above) — currentUserId is guaranteed
            // non-nil here in practice; the `if let` is a graceful skip, not a workaround for an
            // expected nil.
            if let userId = authService.currentUserId {
                manualDataCloudSyncManager.startObserving(context: modelContext, userId: userId)
                monthlyPlanCloudSyncManager.startObserving(context: modelContext, userId: userId)
            }
            // Fire-and-forget — resolves the Settings row's Primary-only visibility gate without
            // blocking the rest of this task's own bootstrap work above.
            Task { await accountRelatedOptionsViewModel.refresh() }
            await enablePendingFaceIDOptInIfNeeded(for: freshlyCreatedSettings)
        }
    }

    /// Returns the newly-created `BudgetSettings` row when this is a genuinely fresh user (no
    /// existing row) — `nil` when reusing an already-existing row — so callers (specifically the
    /// pending Face ID opt-in below) can distinguish "first time this user's store was ever
    /// bootstrapped" from every subsequent launch.
    @discardableResult
    private func bootstrapDefaultSettingsIfNeeded() -> BudgetSettings? {
        let settings: BudgetSettings
        let isFreshlyCreated: Bool
        if let existing = settingsList.first {
            settings = existing
            isFreshlyCreated = false
        } else {
            settings = BudgetSettings(
                weeklySpendingLimit: 0,
                weekStartsOnSunday: true,
                includePendingTransactions: true,
                hideBalancesByDefault: false,
                requireFaceID: false,
                monthlyGoal: nil
            )
            modelContext.insert(settings)
            isFreshlyCreated = true
        }
        privacyMode.isEnabled = settings.hideBalancesByDefault
        biometricAuth.isFaceIDRequired = settings.requireFaceID
        return isFreshlyCreated ? settings : nil
    }

    /// Applies `CreateAccountView`'s "Use Face ID for future sign-in" opt-in — only for a
    /// genuinely fresh user (`freshlyCreatedSettings != nil`), and only if a real biometric check
    /// succeeds right now, at the one point a valid authenticated session AND this user's
    /// isolated container both already exist. One-shot: `PendingFaceIDOptIn.consume` removes the
    /// marker regardless of outcome, so this can never run again for this account.
    private func enablePendingFaceIDOptInIfNeeded(for freshlyCreatedSettings: BudgetSettings?) async {
        guard let settings = freshlyCreatedSettings,
              let email = authService.currentUserEmail,
              PendingFaceIDOptIn.consume(email: email)
        else { return }

        await biometricAuth.authenticate(reason: "Enable Face ID for SpendSmart", surfaceErrors: false)
        if biometricAuth.isUnlocked {
            settings.requireFaceID = true
            biometricAuth.isFaceIDRequired = true
        }
    }

    /// Runs on every launch (not just first-run): seeds the full default set for brand-new
    /// installs, and backfills any default categories added since — e.g. an existing install
    /// that only has the original 10 categories gets the newer ones (Home, Security, Car, ...)
    /// added alongside them. Never touches an existing category, default or user-created.
    private func bootstrapDefaultCategoriesIfNeeded() {
        Category.missingDefaultCategories(existing: categories).forEach { modelContext.insert($0) }
    }

    private func bootstrapDefaultMonthlyPlanSettingsIfNeeded() {
        guard monthlyPlanSettingsList.isEmpty else { return }
        modelContext.insert(MonthlyPlanSettings())
    }
}
