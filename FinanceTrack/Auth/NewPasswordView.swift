import SwiftUI

/// Shown when `AuthenticationService.isPasswordRecoveryActive` is true — i.e. the user tapped a
/// password-reset email link and the app completed a recovery session from it (see
/// `AuthenticationService.handle(url:)`). `FinanceTrackApp`'s top-level routing shows this ABOVE
/// every other screen (including the main app and Forgot Password) whenever recovery is active,
/// so this is reachable regardless of what the app was showing when the link was tapped.
struct NewPasswordView: View {
    @Environment(AuthenticationService.self) private var authService

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isUpdating = false
    @State private var didSucceed = false
    @State private var errorMessage: String?

    private var passwordMessages: [String] {
        AuthValidation.passwordValidationMessages(newPassword)
    }

    private var confirmError: String? {
        guard !confirmPassword.isEmpty else { return nil }
        return AuthValidation.passwordsMatch(newPassword, confirmPassword) ? nil : "Passwords don't match."
    }

    private var canSubmit: Bool {
        AuthValidation.isPasswordValid(newPassword)
            && AuthValidation.passwordsMatch(newPassword, confirmPassword)
            && !isUpdating
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header

                    if didSucceed {
                        successState
                    } else {
                        form

                        if let errorMessage {
                            inlineMessage(icon: "exclamationmark.circle.fill", text: errorMessage, color: Theme.statusOver)
                        }

                        PremiumActionButton(title: isUpdating ? "Updating…" : "Update Password") {
                            Task { await updatePassword() }
                        }
                        // `isUpdating` alone (not just `canSubmit`) guards this so a second tap
                        // mid-request can never fire a duplicate update call.
                        .disabled(!canSubmit || isUpdating)
                        .opacity(canSubmit ? 1 : 0.5)
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("New Password")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        Text("Choose a new password for your SpendSmart account.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
    }

    private var form: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                AuthTextField(
                    title: "New Password",
                    placeholder: "At least 8 characters",
                    text: $newPassword,
                    isSecure: true,
                    textContentType: .newPassword
                )
                if !newPassword.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(passwordMessages, id: \.self) { fieldError($0) }
                    }
                }

                AuthTextField(
                    title: "Confirm New Password",
                    placeholder: "Re-enter your new password",
                    text: $confirmPassword,
                    isSecure: true,
                    textContentType: .newPassword
                )
                if let confirmError { fieldError(confirmError) }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var successState: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Theme.statusGood)
                Text("Password Updated")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Text("Your SpendSmart password has been changed.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                ProgressView()
                    .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private func fieldError(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.statusOver)
    }

    @ViewBuilder
    private func inlineMessage(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(Theme.captionFont)
        }
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updatePassword() async {
        guard !isUpdating else { return }
        errorMessage = nil
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await authService.updatePassword(newPassword)
            didSucceed = true
            // Let "Password Updated" register on screen, then hand routing back to
            // FinanceTrackApp — it re-evaluates sessionState/isEmailVerified once
            // isPasswordRecoveryActive drops, landing on Sign In (if the recovery session
            // somehow didn't stick), Verify Email, or the main app as appropriate.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            authService.clearPasswordRecoveryState()
        } catch {
            errorMessage = error.friendlyAuthMessage
        }
    }
}

#Preview {
    NewPasswordView()
        .environment(AuthenticationService.shared)
}
