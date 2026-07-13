import SwiftUI

/// Requests a password-reset email. The confirmation message is deliberately the same whether or
/// not the address is actually registered — avoids leaking which emails have SpendSmart accounts.
/// After a successful send, the form is replaced by a "Check Your Email" state with a 60-second
/// resend cooldown; the actual New Password screen is a separate top-level route
/// (`NewPasswordView`, shown by `FinanceTrackApp` whenever `AuthenticationService
/// .isPasswordRecoveryActive` is true) reached by tapping the emailed link, not from here.
struct ForgotPasswordView: View {
    @Environment(AuthenticationService.self) private var authService

    var onBack: () -> Void

    @State private var email = ""
    @State private var isSending = false
    @State private var didSend = false
    @State private var errorMessage: String?
    @State private var cooldownRemaining = 0
    @State private var cooldownTask: Task<Void, Never>?

    private var canSubmit: Bool {
        AuthValidation.isValidEmail(email) && !isSending
    }

    private var canResend: Bool {
        !isSending && cooldownRemaining == 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    if didSend {
                        successState
                    } else {
                        requestForm
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Forgot Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: onBack).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { cooldownTask?.cancel() }
    }

    // MARK: - Request form (before send)

    private var requestForm: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Text("Enter your account email and we'll send a link to reset your password.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.lg)

            CardBackground {
                AuthTextField(
                    title: "Email",
                    placeholder: "you@example.com",
                    text: $email,
                    keyboardType: .emailAddress,
                    textContentType: .username
                )
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if let errorMessage {
                inlineMessage(icon: "exclamationmark.circle.fill", text: errorMessage, color: Theme.statusOver)
            }

            PremiumActionButton(title: isSending ? "Sending…" : "Send Reset Email") {
                Task { await send() }
            }
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Success state (after send) — email field hidden, email retained internally

    private var successState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Check Your Email")
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text("We sent a password reset link to your email address.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Text("Open the email on this iPhone and tap the link to return to SpendSmart and choose a new password.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Theme.Spacing.lg)

            if let errorMessage {
                inlineMessage(icon: "exclamationmark.circle.fill", text: errorMessage, color: Theme.statusOver)
            }

            VStack(spacing: Theme.Spacing.md) {
                Button {
                    Task { await send() }
                } label: {
                    Text(resendButtonTitle)
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.sm + 2)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                }
                .buttonStyle(.plain)
                .disabled(!canResend)
                .opacity(canResend ? 1 : 0.5)

                Button("Return to Sign In", action: onBack)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var resendButtonTitle: String {
        if isSending { return "Sending…" }
        if cooldownRemaining > 0 { return "Resend Email (\(cooldownRemaining)s)" }
        return "Resend Email"
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

    /// Handles both the initial send and every resend. `isSending` alone prevents a double-tap
    /// duplicate request; once `didSend` is true, the cooldown additionally prevents a resend
    /// before it expires. Never fires automatically — always a direct result of a button tap.
    private func send() async {
        guard !isSending else { return }
        guard !didSend || cooldownRemaining == 0 else { return }
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            try await authService.resetPassword(email: email)
            // `authService` is `@MainActor`-isolated (see its doc comment), so this `await`
            // resumes back on the main actor and this mutation lands on the same run loop tick
            // SwiftUI is already observing — no separate MainActor hop needed here.
            didSend = true
            #if DEBUG
            print("[PasswordReset] success state active=\(didSend)")
            #endif
            startCooldown()
        } catch {
            errorMessage = error.friendlyAuthMessage
        }
    }

    private func startCooldown() {
        cooldownTask?.cancel()
        cooldownRemaining = 60
        cooldownTask = Task {
            while cooldownRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                cooldownRemaining -= 1
            }
        }
    }
}

#Preview {
    ForgotPasswordView(onBack: {})
        .environment(AuthenticationService.shared)
        .preferredColorScheme(.dark)
}
