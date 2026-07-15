import SwiftUI
import SwiftData

@main
struct FinanceTrackApp: App {
    @State private var privacyMode = PrivacyModeManager()
    @State private var biometricAuth = BiometricAuthManager()
    @State private var plaidConnection = PlaidConnectionManager()
    @State private var autoBackupManager = AutoBackupManager()
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
        #endif
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Account.self,
            FinanceTransaction.self,
            BudgetSettings.self,
            Category.self,
            IncomeSource.self,
            RecurringExpense.self,
            MonthlyPlanSettings.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create local SwiftData store: \(error)")
        }
    }()

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
                    } else {
                        RootView()
                            .environment(privacyMode)
                            .environment(biometricAuth)
                            .environment(plaidConnection)
                            .environment(autoBackupManager)
                    }
                }
                .environment(authService)
                .task {
                    authService.startObservingAuthEvents()
                    await authService.restoreSession()
                }
                .onOpenURL { url in
                    // Single dispatch point for every URL this app can be opened with. Checked
                    // FIRST and exclusively: a Plaid OAuth return must never be handed to
                    // AuthenticationService.handle(url:), which unconditionally attempts to
                    // establish a Supabase session from whatever URL it receives.
                    if PlaidOAuthReturn.matches(url) {
                        // Never log the full URL — Plaid's OAuth return can carry state/query
                        // parameters. Only confirms recognition, matching this project's existing
                        // safe-logging convention (see AuthenticationService.handle(url:)'s own
                        // structural-fields-only logging).
                        #if DEBUG
                        print("[PlaidOAuthReturn] recognized Plaid OAuth callback: true")
                        #endif
                        plaidConnection.handlePlaidOAuthReturn()
                        return
                    }

                    // Password-reset / email-confirmation deep link callback — see
                    // AuthenticationService.resetPassword's redirectTo and SupabaseConfig. Fires
                    // whether the app was already running (foreground or background) or launched
                    // fresh by tapping the link — `.onOpenURL` covers both.
                    Task { await authService.handle(url: url) }
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
        .modelContainer(sharedModelContainer)
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

/// Root tab container for the app's primary screens. Also owns first-run bootstrapping:
/// a default `BudgetSettings` record and the standard `Category` set are created once if none
/// exist, so the dashboard never shows a $0 budget and expense entry always has categories to
/// pick from. No sample/demo transactions are ever inserted here — only settings and taxonomy.
private struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [BudgetSettings]
    @Query private var categories: [Category]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]
    @Environment(PrivacyModeManager.self) private var privacyMode
    @Environment(BiometricAuthManager.self) private var biometricAuth
    @Environment(AutoBackupManager.self) private var autoBackupManager

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
            bootstrapDefaultSettingsIfNeeded()
            bootstrapDefaultCategoriesIfNeeded()
            bootstrapDefaultMonthlyPlanSettingsIfNeeded()
            autoBackupManager.startObserving(context: modelContext)
        }
    }

    private func bootstrapDefaultSettingsIfNeeded() {
        let settings: BudgetSettings
        if let existing = settingsList.first {
            settings = existing
        } else {
            settings = BudgetSettings(
                weeklySpendingLimit: 300,
                weekStartsOnSunday: true,
                includePendingTransactions: true,
                hideBalancesByDefault: false,
                requireFaceID: false,
                monthlyGoal: nil
            )
            modelContext.insert(settings)
        }
        privacyMode.isEnabled = settings.hideBalancesByDefault
        biometricAuth.isFaceIDRequired = settings.requireFaceID
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
