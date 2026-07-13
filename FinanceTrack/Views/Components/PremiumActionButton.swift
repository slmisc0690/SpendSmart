import SwiftUI

/// The app's standard full-width call-to-action button (gradient fill, soft glow shadow).
/// Used for primary actions like "Add Expense", "Add Account", and "Set Weekly Budget".
struct PremiumActionButton: View {
    let title: String
    var systemIconName: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let systemIconName {
                    Image(systemName: systemIconName)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(Theme.headlineFont)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.accentGradient)
            )
            .shadow(color: Theme.accent.opacity(0.35), radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 12) {
        PremiumActionButton(title: "Add Expense", systemIconName: "plus") {}
        PremiumActionButton(title: "Add Account") {}
    }
    .padding()
    .background(Theme.backgroundGradient)
}
