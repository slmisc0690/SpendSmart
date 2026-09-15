import SwiftUI
import SwiftData

/// ACCOUNT REGISTER AUTO DEPOSIT — REVIEW STEP. Presented from `DashboardView` whenever
/// `AccountRegisterAutoDepositService.pendingDeposits` is non-empty. See that service's own header
/// for why this can never be fully automatic: a deposit the user already recorded by hand (e.g. a
/// Savings-to-Checking transfer he made himself) looks identical, once Plaid syncs it, to a genuine
/// external deposit — only he can tell them apart. Every deposit shown here is marked reviewed the
/// moment "Done" is tapped, whether checked or not, so nothing is ever asked about twice.
struct AccountRegisterDepositReviewView: View {
    let deposits: [FinanceTransaction]
    let destinations: [Account]
    let settings: BudgetSettings

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode

    @State private var includedIds: Set<UUID>
    @State private var errorMessage: String?

    init(deposits: [FinanceTransaction], destinations: [Account], settings: BudgetSettings) {
        self.deposits = deposits
        self.destinations = destinations
        self.settings = settings
        _includedIds = State(initialValue: Set(deposits.map(\.id)))
    }

    private var destinationLabel: String {
        destinations.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text("These deposits showed up in your Connected accounts. Uncheck any you've already entered yourself — for example, a transfer you made by hand that will also appear here once it posts.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Spacing.lg)

                    CardBackground {
                        VStack(spacing: Theme.Spacing.md) {
                            ForEach(Array(deposits.enumerated()), id: \.element.id) { index, deposit in
                                selectableRow(for: deposit)
                                if index < deposits.count - 1 {
                                    Divider().overlay(Theme.cardStroke)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    Text("Checked deposits will be added to: \(destinationLabel).")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Review Deposits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { confirm() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func selectableRow(for deposit: FinanceTransaction) -> some View {
        Button {
            toggle(deposit)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: includedIds.contains(deposit.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(includedIds.contains(deposit.id) ? Theme.accent : Theme.textTertiary)
                ConnectedTransactionRow(transaction: deposit, isPrivacyModeEnabled: privacyMode.isEnabled)
            }
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ deposit: FinanceTransaction) {
        if includedIds.contains(deposit.id) {
            includedIds.remove(deposit.id)
        } else {
            includedIds.insert(deposit.id)
        }
    }

    private func confirm() {
        let included = deposits.filter { includedIds.contains($0.id) }
        do {
            try AccountRegisterAutoDepositService.confirmDeposits(
                shown: deposits,
                included: included,
                destinations: destinations,
                settings: settings,
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = "Some deposits couldn't be added. Nothing was changed — try again."
        }
    }
}
