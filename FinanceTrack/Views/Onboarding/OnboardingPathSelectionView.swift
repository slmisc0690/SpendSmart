import SwiftUI

/// First-run "how do you want to get started?" screen — one selectable card per
/// `OnboardingSetupPath`. Picking anything but `.none` hands the choice to `onSelect`, which
/// `OnboardingFlowView` uses to advance to that path's instructions; `.none` is handled the exact
/// same way (still goes through `onSelect`) — `OnboardingFlowView` is the one place that decides
/// `.none` skips instructions and completes immediately, so this screen has no special-casing of
/// its own.
struct OnboardingPathSelectionView: View {
    var onSelect: (OnboardingSetupPath) -> Void

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    VStack(spacing: Theme.Spacing.sm) {
                        Text("How do you want to get started?")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                        Text("Pick whichever matches what you actually want to track — you can always change this later.")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, Theme.Spacing.xl)
                    .padding(.horizontal, Theme.Spacing.lg)

                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(OnboardingSetupPath.allCases) { path in
                            Button {
                                onSelect(path)
                            } label: {
                                CardBackground {
                                    HStack(spacing: Theme.Spacing.md) {
                                        Image(systemName: path.systemImageName)
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(Theme.accent)
                                            .frame(width: 36, height: 36)
                                            .background(Circle().fill(Theme.accent.opacity(0.16)))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(path.title)
                                                .font(Theme.bodyFont)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(path.subtitle)
                                                .font(Theme.captionFont)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.xl)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    OnboardingPathSelectionView(onSelect: { _ in })
}
