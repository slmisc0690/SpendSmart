import SwiftUI

/// TWO-LINE FAVORITES PHASE — shown the first time the "Checking Register" Favorite is tapped with
/// no target configured yet (`DashboardView.handleFavoriteSelection(_:)`), or reopened from
/// Favorites configuration (`FavoritesConfigurationView`) to change an already-configured mapping.
/// A thin selection list only — never a second copy of `ManualAccountDetailView`'s own register UI;
/// once an account is chosen, the caller presents that canonical, unmodified screen itself.
struct CheckingRegisterAccountPickerView: View {
    let accounts: [Account]
    var onSelect: (Account) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(accounts) { account in
                            Button {
                                onSelect(account)
                            } label: {
                                row(for: account)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.cardSurface)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Choose Checking Register")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(for account: Account) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: account.type.systemIconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Text(account.type.label)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accentGradient)

            Text("No Manual Accounts Yet")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)

            Text("Add a Manual Account first (Manual Accounts ▸ +), then choose it here for the Checking Register Favorite.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    CheckingRegisterAccountPickerView(accounts: [], onSelect: { _ in })
}
