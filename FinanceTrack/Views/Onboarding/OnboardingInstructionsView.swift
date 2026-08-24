import SwiftUI

/// Shown after `OnboardingPathSelectionView` for any path except `.none` — explains exactly what
/// to set up for the chosen path, and what Dashboard/Weekly/Activity will (and won't) show once
/// it's done. All content lives on `OnboardingSetupPath` itself; this view only lays it out.
struct OnboardingInstructionsView: View {
    let path: OnboardingSetupPath
    var onGetStarted: () -> Void

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Image(systemName: path.systemImageName)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(path.title)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text(path.subtitle)
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        DashboardSectionHeader(title: "Setup")
                        CardBackground {
                            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                ForEach(Array(path.setupSteps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                                        Text("\(index + 1)")
                                            .font(Theme.captionFont.bold())
                                            .foregroundStyle(.white)
                                            .frame(width: 22, height: 22)
                                            .background(Circle().fill(Theme.accent))
                                        Text(step)
                                            .font(Theme.bodyFont)
                                            .foregroundStyle(Theme.textPrimary)
                                    }
                                    if index < path.setupSteps.count - 1 {
                                        Divider().overlay(Theme.cardStroke)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        DashboardSectionHeader(title: "What to Expect")
                        CardBackground {
                            Text(path.whatToExpect)
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }

                    PremiumActionButton(title: "Get Started") {
                        onGetStarted()
                    }
                    .padding(.top, Theme.Spacing.sm)
                    .padding(.bottom, Theme.Spacing.xl)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.lg)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    OnboardingInstructionsView(path: .connectedAndMonthlyPlan, onGetStarted: {})
}
