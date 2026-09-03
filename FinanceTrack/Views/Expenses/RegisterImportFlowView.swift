import SwiftUI
import SwiftData

/// ACTIVITY REGISTER IMPORT — the multi-step "Add to..." wizard: entry type → (Transfer direction
/// + note, only for Transfer) → destination Manual Account register → review → create. The
/// SOURCE connected transactions passed in are never mutated anywhere in this flow — only new
/// `source: .manual` rows are created, via `RegisterImportService` (which itself reuses
/// `AccountBalanceManager`, never new balance math).
struct RegisterImportFlowView: View {
    let sourceTransactions: [FinanceTransaction]
    let alreadyImportedSourceIds: Set<UUID>
    /// Called after a successful batch write so the presenting screen can clear its own selection
    /// state — this view never reaches back into `ExpenseListView`'s state directly.
    var onSuccess: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var allAccounts: [Account]

    private enum Step {
        case chooseType
        case transferDirection
        case chooseRegister
        case review
        case success(createdCount: Int, accountName: String)
    }

    @State private var step: Step = .chooseType
    @State private var choice: RegisterImportEntryChoice?
    @State private var transferDirection: RegisterImportTransferDirection?
    @State private var transferToNote: String = ""
    @State private var selectedAccount: Account?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isPresentingMixedDirectionWarning = false

    /// Alphabetized by displayed name — every `Account` row IS a Manual Account/register (Plaid
    /// connections are never represented as an `Account`), so no further filtering is needed.
    private var sortedAccounts: [Account] {
        allAccounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var resolvedType: RegisterImportResolvedType? {
        guard let choice else { return nil }
        return RegisterImportResolvedType(choice: choice, transferDirection: transferDirection)
    }

    /// A connected batch mixing `.expense` (money leaving) and `.creditCardPayment` (a credit
    /// posted to the card, conceptually the opposite direction) sources — the only two types
    /// `PlaidTransactionImportService` ever produces, per its own `classifyPlaidAmount`.
    private var hasMixedDirections: Bool {
        let types = Set(sourceTransactions.map(\.type))
        return types.contains(.expense) && types.contains(.creditCardPayment)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .chooseType: chooseTypeStep
                case .transferDirection: transferDirectionStep
                case .chooseRegister: chooseRegisterStep
                case .review: reviewStep
                case .success(let createdCount, let accountName): successStep(createdCount: createdCount, accountName: accountName)
                }
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Mixed Transaction Directions", isPresented: $isPresentingMixedDirectionWarning) {
            Button("Continue", role: .none) { advancePastTypeChoice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your selected transactions include both incoming and outgoing amounts. Continue using \(choice?.label ?? "this type") for all selected items?")
        }
        .alert("Couldn't Add to Register", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    // MARK: - Step 1: Entry type

    private var chooseTypeStep: some View {
        List {
            Section {
                ForEach(RegisterImportEntryChoice.allCases) { entryChoice in
                    Button {
                        choice = entryChoice
                        if entryChoice == .transfer {
                            step = .transferDirection
                        } else if hasMixedDirections {
                            isPresentingMixedDirectionWarning = true
                        } else {
                            step = .chooseRegister
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entryChoice.label).font(Theme.bodyFont).foregroundStyle(Theme.textPrimary)
                            Text(entryChoice.subtitle).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            } header: {
                Text("Add to:")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Add to Register")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func advancePastTypeChoice() {
        step = .chooseRegister
    }

    // MARK: - Step 2: Transfer direction (Transfer only)

    private var transferDirectionStep: some View {
        Form {
            Section {
                ForEach(RegisterImportTransferDirection.allCases) { direction in
                    Button {
                        transferDirection = direction
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(direction.label).font(Theme.bodyFont).foregroundStyle(Theme.textPrimary)
                                Text(direction.subtitle).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            if transferDirection == direction {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("Transfer Direction")
            }

            Section {
                TextField("e.g. Savings", text: $transferToNote)
            } header: {
                Text("Transfer to:")
            } footer: {
                Text("A short note identifying the other side of the transfer.")
            }
        }
        .navigationTitle("Transfer")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") {
                    if hasMixedDirections {
                        isPresentingMixedDirectionWarning = true
                    } else {
                        step = .chooseRegister
                    }
                }
                .disabled(transferDirection == nil)
            }
        }
    }

    // MARK: - Step 3: Choose Manual Account register

    private var chooseRegisterStep: some View {
        List(sortedAccounts) { account in
            Button {
                selectedAccount = account
                step = .review
            } label: {
                HStack {
                    Text(account.name).font(Theme.bodyFont).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if selectedAccount?.id == account.id {
                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Add to Register:")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    // MARK: - Step 4: Review

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if let resolvedType {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Add to:").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        Text(choice?.label ?? "").font(Theme.headlineFont).foregroundStyle(Theme.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Register:").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        Text(selectedAccount?.name ?? "").font(Theme.headlineFont).foregroundStyle(Theme.textPrimary)
                    }

                    if choice == .transfer, !transferToNote.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Transfer to:").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            Text(transferToNote).font(Theme.bodyFont).foregroundStyle(Theme.textPrimary)
                        }
                    }

                    Text("Transactions (\(sourceTransactions.count))")
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)

                    CardBackground {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            ForEach(Array(sourceTransactions.enumerated()), id: \.element.id) { index, transaction in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transaction.displayName).font(Theme.bodyFont).foregroundStyle(Theme.textPrimary)
                                    Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(Theme.captionFont)
                                        .foregroundStyle(Theme.textTertiary)
                                    Text((resolvedType.increasesBalance ? "+" : "-") + transaction.amount.formatted(.currency(code: "USD")))
                                        .font(Theme.bodyFont)
                                        .foregroundStyle(resolvedType.increasesBalance ? Theme.statusGood : Theme.textPrimary)
                                }
                                if index < sourceTransactions.count - 1 {
                                    Divider().overlay(Theme.cardStroke)
                                }
                            }
                        }
                    }

                    let total = RegisterImportService.reviewTotal(for: sourceTransactions, resolvedType: resolvedType)
                    HStack {
                        Text("Total").font(Theme.headlineFont).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text((total >= 0 ? "+" : "-") + abs(total).formatted(.currency(code: "USD")))
                            .font(Theme.headlineFont)
                            .foregroundStyle(total >= 0 ? Theme.statusGood : Theme.textPrimary)
                    }

                    Button {
                        submit(resolvedType: resolvedType)
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Add \(sourceTransactions.count) to Register")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || selectedAccount == nil)

                    Button("Cancel", role: .cancel) { dismiss() }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle("Review & Add")
    }

    private func submit(resolvedType: RegisterImportResolvedType) {
        guard let selectedAccount else { return }
        isSubmitting = true
        do {
            let created = try RegisterImportService.createEntries(
                for: sourceTransactions,
                resolvedType: resolvedType,
                destinationAccount: selectedAccount,
                transferToNote: choice == .transfer ? transferToNote : nil,
                alreadyImportedSourceIds: alreadyImportedSourceIds,
                context: modelContext
            )
            isSubmitting = false
            step = .success(createdCount: created.count, accountName: selectedAccount.name)
        } catch RegisterImportService.ImportError.containsAlreadyImportedTransaction {
            isSubmitting = false
            errorMessage = "One or more selected transactions have already been added to a register. Please deselect them and try again."
        } catch {
            isSubmitting = false
            errorMessage = "Something went wrong saving these entries. Nothing was added — please try again."
        }
    }

    // MARK: - Step 5: Success

    private func successStep(createdCount: Int, accountName: String) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.statusGood)
            Text("Added to \(accountName)")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.textPrimary)
            Text("\(createdCount) \(createdCount == 1 ? "transaction has" : "transactions have") been added to your register.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Done") {
                onSuccess()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Spacing.lg)
    }
}
