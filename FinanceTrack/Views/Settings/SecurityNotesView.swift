import SwiftUI

/// Plain-language explanation of what SpendSmart does and doesn't do with your data. Reachable
/// from Settings — nothing here is interactive, it's purely informational.
struct SecurityNotesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(spacing: Theme.Spacing.sm) {
                        Image("SpendSmartLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text("Security Notes")
                            .font(Theme.titleFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text("What SpendSmart does — and doesn't — do with your data")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.md)

                    noteCard(
                        icon: "lock.iphone",
                        title: "Manual-First",
                        body: "Every account, balance, and transaction can be entered by you and stored only on this device. Connecting a financial institution through Plaid is entirely optional."
                    )
                    noteCard(
                        icon: "key.slash",
                        title: "No Bank Credentials Stored",
                        body: "SpendSmart never asks for your bank or credit card username or password. There is nothing to steal, because nothing like that is ever collected."
                    )
                    noteCard(
                        icon: "network.slash",
                        title: "No Bank Connection Until You Choose One",
                        body: "No financial institution is connected until you complete the connect flow yourself in Connected Accounts. All of your manually entered accounts, balances, and transactions never leave this device regardless — only a connected institution's data ever talks to a server, and only once you connect it."
                    )
                    noteCard(
                        icon: "faceid",
                        title: "Face ID Can Be Enabled",
                        body: "Turn on Face ID Lock in Settings to require Face ID, Touch ID, or your device passcode every time SpendSmart opens."
                    )
                    noteCard(
                        icon: "eye.slash.fill",
                        title: "Privacy Mode",
                        body: "Privacy Mode hides every dollar amount on screen behind dots, so you can open the app around others without showing your balances."
                    )
                    noteCard(
                        icon: "checkmark.shield.fill",
                        title: "Connected Institutions Sync Through Plaid",
                        body: "Any institution you connect syncs through Plaid via a secure backend — this app never talks to Plaid directly and never holds a Plaid access token or client secret. Your bank username and password are entered only into Plaid Link's own hosted screen, never into SpendSmart."
                    )
                    noteCard(
                        icon: "eye.fill",
                        title: "Imported Transactions Are Read-Only",
                        body: "Synced transactions never count toward your weekly or monthly totals automatically. They stay in a separate review list until you explicitly approve or match each one — nothing is added to your budget without you looking at it first."
                    )
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Security Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func noteCard(icon: String, title: String, body: String) -> some View {
        CardBackground {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.accent.opacity(0.16)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text(body)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

#Preview {
    SecurityNotesView()
}
