import SwiftUI

/// Email/password account creation. On success, sends a verification email and hands the entered
/// credentials to `onAccountCreated` — `AuthFlowView` uses these to move to `VerifyEmailView`
/// (and, if the user taps "I've Verified My Email" there before a deep link fires, to retry
/// sign-in with them). Never persisted or logged beyond that in-memory hand-off.
struct CreateAccountView: View {
    @Environment(AuthenticationService.self) private var authService

    var onBack: () -> Void
    var onAccountCreated: (String, String) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var emailError: String? {
        guard !email.isEmpty else { return nil }
        return AuthValidation.isValidEmail(email) ? nil : "Enter a valid email address."
    }

    private var passwordMessages: [String] {
        AuthValidation.passwordValidationMessages(password)
    }

    private var confirmError: String? {
        guard !confirmPassword.isEmpty else { return nil }
        return AuthValidation.passwordsMatch(password, confirmPassword) ? nil : "Passwords don't match."
    }

    private var canSubmit: Bool {
        AuthValidation.isValidEmail(email)
            && AuthValidation.isPasswordValid(password)
            && AuthValidation.passwordsMatch(password, confirmPassword)
            && !isCreating
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header
                    form

                    if let successMessage {
                        inlineMessage(icon: "checkmark.circle.fill", text: successMessage, color: Theme.statusGood)
                    }
                    if let errorMessage {
                        inlineMessage(icon: "exclamationmark.circle.fill", text: errorMessage, color: Theme.statusOver)
                    }

                    PremiumActionButton(title: isCreating ? "Creating Account…" : "Create Account") {
                        Task { await createAccount() }
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Create Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: onBack).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        Text("Create your SpendSmart account. Two people can use the same email and password to share one household's data across both phones.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
    }

    private var form: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                AuthTextField(
                    title: "Email",
                    placeholder: "you@example.com",
                    text: $email,
                    keyboardType: .emailAddress,
                    textContentType: .username
                )
                if let emailError { fieldError(emailError) }

                AuthTextField(
                    title: "Password",
                    placeholder: "At least 8 characters",
                    text: $password,
                    isSecure: true,
                    textContentType: .newPassword
                )
                if !password.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(passwordMessages, id: \.self) { fieldError($0) }
                    }
                }

                AuthTextField(
                    title: "Confirm Password",
                    placeholder: "Re-enter your password",
                    text: $confirmPassword,
                    isSecure: true,
                    textContentType: .newPassword
                )
                if let confirmError { fieldError(confirmError) }
            }
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

    private func createAccount() async {
        errorMessage = nil
        successMessage = nil
        isCreating = true
        defer { isCreating = false }
        do {
            try await authService.signUp(email: email, password: password)
            successMessage = "Account created! Check your email to verify SpendSmart."
            // Let the success message register on screen before moving on.
            try? await Task.sleep(nanoseconds: 700_000_000)
            onAccountCreated(email, password)
        } catch {
            errorMessage = error.friendlyAuthMessage
        }
    }
}

#Preview {
    CreateAccountView(onBack: {}, onAccountCreated: { _, _ in })
        .environment(AuthenticationService.shared)
        .preferredColorScheme(.dark)
}
