import SwiftUI

/// Shared icon + message + call-to-action card for first-run/empty states.
struct EmptyStateCard: View {
    let systemIconName: String
    let message: String
    /// Both nil together renders a plain informational card with no button — used where an
    /// empty state shouldn't offer an action this screen isn't responsible for (e.g. Dashboard
    /// pointing to the Accounts tab instead of managing accounts itself).
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: systemIconName)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.accentGradient)

                Text(message)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                if let actionTitle, let action {
                    PremiumActionButton(title: actionTitle, action: action)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    EmptyStateCard(
        systemIconName: "creditcard.fill",
        message: "Add an account to start tracking your balances and expenses.",
        actionTitle: "Add Account"
    ) {}
    .padding()
    .background(Theme.backgroundGradient)
}
