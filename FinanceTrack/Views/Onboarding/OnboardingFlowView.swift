import SwiftUI

/// First-run flow shown between account creation and the real Dashboard, for a genuinely
/// brand-new user only (see `OnboardingSettings`'s own header for the existing-user safety
/// guarantee). Order: paywall stub → path selection → path-specific instructions (skipped
/// entirely for `.none`) → `onComplete()`, which `RootView` uses to mark
/// `OnboardingSettings.hasCompletedOnboarding` and swap in the normal `TabView`.
///
/// Deliberately its own tiny local state machine (`Step`) rather than a `NavigationStack` push
/// sequence — every step is a full-screen replacement of the last, never something the user
/// should be able to swipe-back through mid-setup (there's nothing destructive to undo, but
/// "back" during onboarding has no obvious correct target once a path's already been chosen).
struct OnboardingFlowView: View {
    var onComplete: (OnboardingSetupPath) -> Void

    private enum Step: Equatable {
        case paywall
        case pathSelection
        case instructions(OnboardingSetupPath)
    }

    @State private var step: Step = .paywall

    var body: some View {
        Group {
            switch step {
            case .paywall:
                OnboardingPaywallStubView {
                    step = .pathSelection
                }
            case .pathSelection:
                OnboardingPathSelectionView { path in
                    if path == .none {
                        onComplete(path)
                    } else {
                        step = .instructions(path)
                    }
                }
            case .instructions(let path):
                OnboardingInstructionsView(path: path) {
                    onComplete(path)
                }
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: step)
    }
}

#Preview {
    OnboardingFlowView(onComplete: { _ in })
}
