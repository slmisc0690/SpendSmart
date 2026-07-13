import SwiftUI

/// Shown right after account creation while email confirmation is pending. Two independent paths
/// can complete verification: tapping the emailed link (handled by `AuthenticationService.handle
/// (url:)` via the app's `.onOpenURL`, which flips `sessionState` on its own and lets `RootView`
/// swap away from this screen automatically), or tapping "I've Verified My Email" here, which
/// retries sign-in with the credentials just used to create the account — a fallback for cases
/// where the deep link doesn't fire (e.g. the email was opened on a different device).
struct VerifyEmailView: View {
    @Environment(AuthenticationService.self) private var authService

    let email: String
    let password: String
    var onBackToSignIn: () -> Void

    @State private var isChecking = false
    @State private var isResending = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.xl) {
                Spacer()

                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Theme.accent)

                    Text("Check your email to verify your SpendSmart account.")
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)

                    if !email.isEmpty {
                        Text(email)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)

                if let statusMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: statusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(statusMessage)
                            .font(Theme.captionFont)
                    }
                    .foregroundStyle(statusIsError ? Theme.statusOver : Theme.statusGood)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, Theme.Spacing.lg)
                }

                Spacer()

                VStack(spacing: Theme.Spacing.md) {
                    PremiumActionButton(title: isChecking ? "Checking…" : "I've Verified My Email") {
                        Task { await checkVerification() }
                    }
                    .disabled(isChecking)
                    .opacity(isChecking ? 0.6 : 1)

                    Button {
                        Task { await resend() }
                    } label: {
                        Text(isResending ? "Sending…" : "Resend Verification Email")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isResending)

                    Button("Back to Sign In", action: onBackToSignIn)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
    }

    private func checkVerification() async {
        isChecking = true
        defer { isChecking = false }
        statusMessage = nil
        do {
            if authService.sessionState != .signedIn {
                try await authService.signIn(email: email, password: password)
            }
            let verified = try await authService.refreshVerificationStatus()
            if !verified {
                statusIsError = true
                statusMessage = "Still not verified. Check your email and tap the confirmation link, then try again."
            }
            // If verified, sessionState is now .signedIn and RootView switches to the main app on
            // its own — nothing further to do here.
        } catch {
            statusIsError = true
            statusMessage = error.friendlyAuthMessage
        }
    }

    private func resend() async {
        isResending = true
        defer { isResending = false }
        statusMessage = nil
        do {
            try await authService.resendVerificationEmail(email: email)
            statusIsError = false
            statusMessage = "Verification email sent."
        } catch {
            statusIsError = true
            statusMessage = error.friendlyAuthMessage
        }
    }
}

#Preview {
    VerifyEmailView(email: "you@example.com", password: "", onBackToSignIn: {})
        .environment(AuthenticationService.shared)
        .preferredColorScheme(.dark)
}
