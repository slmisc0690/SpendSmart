import SwiftUI

/// Email/password sign-in — the same credentials work on any device, since one Supabase Auth
/// user is one shared SpendSmart household account.
struct SignInView: View {
    @Environment(AuthenticationService.self) private var authService

    var onBack: () -> Void
    var onForgotPassword: () -> Void
    var onCreateAccount: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        AuthValidation.isValidEmail(email) && !password.isEmpty && !isSigningIn
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header

                    CardBackground {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            AuthTextField(
                                title: "Email",
                                placeholder: "you@example.com",
                                text: $email,
                                keyboardType: .emailAddress,
                                textContentType: .username
                            )
                            AuthTextField(
                                title: "Password",
                                placeholder: "Your password",
                                text: $password,
                                isSecure: true,
                                textContentType: .password
                            )
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    Button("Forgot Password?", action: onForgotPassword)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, Theme.Spacing.lg)

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(errorMessage)
                                .font(Theme.captionFont)
                        }
                        .foregroundStyle(Theme.statusOver)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    PremiumActionButton(title: isSigningIn ? "Signing In…" : "Sign In") {
                        Task { await signIn() }
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)
                    .padding(.horizontal, Theme.Spacing.lg)

                    if isSigningIn {
                        ProgressView()
                            .tint(Theme.accent)
                    }

                    HStack(spacing: 4) {
                        Text("New user?")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                        Button("Create Account", action: onCreateAccount)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Sign In")
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
        Text("Sign in with the same email and password on any device to see the same SpendSmart data.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
    }

    private func signIn() async {
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await authService.signIn(email: email, password: password)
            // RootView switches to the main app automatically once sessionState flips to
            // .signedIn — nothing further to do here.
        } catch {
            errorMessage = error.friendlyAuthMessage
        }
    }
}

#Preview {
    SignInView(onBack: {}, onForgotPassword: {}, onCreateAccount: {})
        .environment(AuthenticationService.shared)
        .preferredColorScheme(.dark)
}
