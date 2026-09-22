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

    /// INCIDENT FIX (2026-09-17) — this used to default every deposit to checked, so a single
    /// "Done" tap (the natural confirm action) added everything shown, whether the user meant to
    /// review each one or not. Combined with a since-fixed missing date floor that could surface
    /// months of history at once, that's how a single tap added $50,000 that was never intended.
    /// Now starts with NOTHING selected — each deposit must be deliberately tapped in, never
    /// tapped out, before it counts toward "Done."
    init(deposits: [FinanceTransaction], destinations: [Account], settings: BudgetSettings) {
        self.deposits = deposits
        self.destinations = destinations
        self.settings = settings
        _includedIds = State(initialValue: [])
    }

    private var destinationLabel: String {
        destinations.map(\.name).joined(separator: ", ")
    }

    /// See this view's own init header — shown prominently so it's never ambiguous what tapping
    /// "Done" is about to do.
    private var includedTotal: Decimal {
        deposits.filter { includedIds.contains($0.id) }.reduce(Decimal(0)) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text("These deposits showed up in your Connected accounts. Check any you'd like to add to your register — for example, NOT a transfer you already made by hand, which will also appear here once it posts.")
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

                    // INCIDENT FIX (2026-09-17) — shown prominently, right above the destination
                    // note, so tapping "Done" never has an ambiguous effect: exactly this many
                    // deposits, exactly this total, exactly these registers, or nothing at all.
                    Text(includedIds.isEmpty
                        ? "Nothing selected — tapping Done will add nothing."
                        : "Adding \(includedIds.count) deposit\(includedIds.count == 1 ? "" : "s") totaling \(CurrencyFormat.string(from: includedTotal)).")
                        .font(Theme.captionFont)
                        .fontWeight(.semibold)
                        .foregroundStyle(includedIds.isEmpty ? Theme.textTertiary : Theme.accent)
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
