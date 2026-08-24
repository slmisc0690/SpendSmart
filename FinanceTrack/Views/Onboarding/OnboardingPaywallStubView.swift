import SwiftUI

/// PLACEHOLDER — reserves the paywall's position in the first-run flow (right after account
/// creation, before the setup-path selection screen) so that slot doesn't need to be re-threaded
/// through the flow later once a real paywall is built. Every subscription/purchase decision is
/// entirely absent here on purpose — this screen makes no claim about pricing or entitlements,
/// it only advances the flow. Replace this view's body (not its call site in
/// `OnboardingFlowView`) when the real paywall is ready.
struct OnboardingPaywallStubView: View {
    var onContinue: () -> Void

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("SpendSmart Premium")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Paywall placeholder — pricing and plans go here.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.lg)
                Spacer()
                PremiumActionButton(title: "Continue") {
                    onContinue()
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    OnboardingPaywallStubView(onContinue: {})
}
