import SwiftUI

/// First screen shown to a signed-out user — SpendSmart branding plus the two entry points into
/// the rest of the auth flow. Shown by `AuthFlowView` whenever `AuthenticationService.shared`
/// isn't signed in.
struct AuthLandingView: View {
    var onCreateAccount: () -> Void
    var onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: Theme.Spacing.md) {
                Image("SpendSmartLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                Text("SpendSmart")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Text("Plan. Track. Save.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            VStack(spacing: Theme.Spacing.md) {
                PremiumActionButton(title: "Create Account", systemIconName: "person.badge.plus", action: onCreateAccount)

                Button(action: onSignIn) {
                    Text("Sign In")
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.sm + 2)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.xl)

            VStack(spacing: 2) {
                Text("SpendSmart")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                Text("Version 1.0.0")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundGradient.ignoresSafeArea())
    }
}

#Preview {
    AuthLandingView(onCreateAccount: {}, onSignIn: {})
        .preferredColorScheme(.dark)
}
