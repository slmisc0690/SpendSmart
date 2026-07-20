import SwiftUI

/// Shown by `FinanceTrackApp`'s `RootView` gate whenever `AuthenticationService.shared` isn't
/// signed in. Owns simple local navigation between the five signed-out screens — a plain
/// `Screen` switch rather than a shared `NavigationStack` path, since each screen already has its
/// own back button wired to an explicit `on...` closure (matching the spec's named buttons)
/// rather than relying on system back-swipe/stack semantics.
struct AuthFlowView: View {
    private enum Screen: Equatable {
        case landing
        case createAccount
        case signIn
        case forgotPassword
        case verifyEmail
    }

    @State private var screen: Screen = .landing
    /// Held only in memory for the signup → Verify Email hand-off (see `VerifyEmailView`'s doc
    /// comment) — never persisted, never logged.
    @State private var pendingEmail = ""
    @State private var pendingPassword = ""

    var body: some View {
        Group {
            switch screen {
            case .landing:
                AuthLandingView(
                    onCreateAccount: { screen = .createAccount },
                    onSignIn: { screen = .signIn }
                )
            case .createAccount:
                CreateAccountView(
                    onBack: { screen = .landing },
                    onAccountCreated: { email, password in
                        pendingEmail = email
                        pendingPassword = password
                        screen = .verifyEmail
                    }
                )
            case .signIn:
                SignInView(
                    onBack: { screen = .landing },
                    onForgotPassword: { screen = .forgotPassword },
                    onCreateAccount: { screen = .createAccount }
                )
            case .forgotPassword:
                ForgotPasswordView(onBack: { screen = .signIn })
            case .verifyEmail:
                VerifyEmailView(
                    email: pendingEmail,
                    password: pendingPassword,
                    onBackToSignIn: {
                        pendingPassword = ""
                        screen = .signIn
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: screen)
    }
}

#Preview {
    AuthFlowView()
        .environment(AuthenticationService.shared)
}
