#if DEBUG
import SwiftUI

/// DEBUG-ONLY, read-only diagnostic screen — lets a developer inspect the same shared-state
/// information already surfaced by `AccountRelatedOptionsViewModel`'s own DEBUG console log
/// (`primarySharedConnectedAccountsCount` etc.) directly on-device, without needing an attached
/// Xcode console. Intended for a Secondary/User B build; a Primary sees an explanatory message
/// instead of the shared figures, since none of this applies to them.
///
/// READ-ONLY BY CONSTRUCTION: reads only the already-loaded `AccountRelatedOptionsViewModel`
/// environment instance — never issues its own network request, never calls `refresh()`, never
/// mutates state, never writes to Supabase. Never shows account names, masks, Plaid IDs, account
/// IDs, balances, user IDs, or contact address details — only counts and booleans, mirroring
/// exactly what the existing DEBUG console log already exposes.
struct SharedDataDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel

    private var role: HouseholdRole? {
        accountRelatedOptionsViewModel.response?.role
    }

    private var isSecondary: Bool {
        role == .secondary
    }

    private var roleDisplayText: String {
        switch role {
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        case nil: return "Unknown"
        }
    }

    /// Mirrors `AccountRelatedOptionsViewModel.LoadState` verbatim — never a second, parallel
    /// state machine.
    private var loadStatusText: String {
        switch accountRelatedOptionsViewModel.state {
        case .idle: return "Not Loaded"
        case .loading: return "Loading"
        case .loaded: return "Success"
        case .failed: return "Failed"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    row(label: "Role", value: roleDisplayText)
                    row(label: "Last Shared Data Load", value: loadStatusText)

                    if isSecondary {
                        row(label: "Shared Connected Accounts", value: "\(accountRelatedOptionsViewModel.response?.primarySharedConnectedAccounts.count ?? 0)")
                        row(label: "Monthly Plan Shared", value: (accountRelatedOptionsViewModel.response?.primaryMonthlyPlanShared ?? false) ? "Yes" : "No")
                        row(label: "Monthly Savings Shared", value: (accountRelatedOptionsViewModel.response?.primaryMonthlySavingsShared ?? false) ? "Yes" : "No")
                    } else {
                        Text("Shared-primary diagnostics are not applicable — this device is not currently an active Secondary.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Shared Data Diagnostics")
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

    private func row(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.cardSurface)
        )
    }
}

#Preview {
    SharedDataDiagnosticsView()
        .environment(AccountRelatedOptionsViewModel())
}
#endif
