import SwiftUI

/// Full-screen lock shown when Face ID/Touch ID is enabled and the app is locked. Fully opaque
/// over the rest of the app, so no balance, transaction, or account data is visible while locked.
/// Purely local via `BiometricAuthManager` — no network, no credentials.
struct AppLockView: View {
    @Environment(BiometricAuthManager.self) private var biometricAuth
    @State private var isBiometricsAvailable = true

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.lg) {
                Image("SpendSmartLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                VStack(spacing: 6) {
                    Text("SpendSmart Locked")
                        .font(Theme.titleFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Face ID protects your accounts, balances, and spending from anyone else who picks up this device.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.xl)
                }

                if isBiometricsAvailable {
                    Button {
                        Task { await biometricAuth.authenticate(surfaceErrors: true) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "faceid")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Unlock with Face ID")
                                .font(Theme.headlineFont)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Capsule().fill(Theme.accentGradient))
                    }
                    .padding(.top, Theme.Spacing.md)

                    if let message = biometricAuth.lastErrorMessage {
                        Text(message)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.statusOver)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.Spacing.xl)
                    }
                } else {
                    VStack(spacing: Theme.Spacing.md) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text(biometricAuth.lastErrorMessage ?? "Face ID and passcode aren't set up on this device.")
                                .font(Theme.bodyFont)
                        }
                        .foregroundStyle(Theme.statusWarning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.xl)

                        PremiumActionButton(title: "Continue") {
                            Task { await biometricAuth.authenticate(surfaceErrors: true) }
                        }
                        .padding(.horizontal, Theme.Spacing.xl)
                    }
                    .padding(.top, Theme.Spacing.md)
                }
            }
            .padding()
        }
        .task {
            // Automatic prompt on lock-screen appearance, matching normal Face ID app-lock
            // behavior — but its failure is never shown (`surfaceErrors: false`): on a real
            // device this only fails silently for edge cases (interrupted scan, etc.) that the
            // OS's own Face ID animation already communicated; in the Simulator, it fails
            // instantly unless you've manually triggered Features > Face ID > Matching/Non-matching
            // Face, which would otherwise show a scary error the user never actually caused.
            switch biometricAuth.availability() {
            case .available:
                isBiometricsAvailable = true
                await biometricAuth.authenticate(surfaceErrors: false)
            case .unavailable(let reason):
                isBiometricsAvailable = false
                biometricAuth.lastErrorMessage = reason
            }
        }
    }
}

#Preview("Face ID Available") {
    AppLockView()
        .environment(BiometricAuthManager())
}
