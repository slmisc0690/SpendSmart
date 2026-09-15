import SwiftUI
import SwiftData

/// TRANSFER PARTY — either side of a `ScheduledTransfer`: a real local Manual Account, or a
/// Connected/Plaid account (reference tag only — no local balance to mutate), mirroring
/// `AddExpenseView`'s own private `TransferAccountSelection` for a single manual transfer entry.
/// A separate, file-local type rather than reusing that one directly (it's `private` to
/// `AddExpenseView` and this feature's edit/create lifecycle differs enough — see
/// `AddEditScheduledTransferView`'s own header — to not force a shared abstraction across files
/// for two call sites).
private enum TransferParty: Hashable {
    case none
    case manual(Account)
    case connected(id: String, label: String)

    var displayLabel: String? {
        switch self {
        case .none: return nil
        case .manual(let account): return account.name
        case .connected(_, let label): return label
        }
    }
}

/// SCHEDULED TRANSFERS — lets the user set up a recurring transfer once (e.g. "$25, Checking to
/// Savings, every Mid-Month") instead of re-entering it by hand every cycle. Either side may be a
/// Manual Account or a Connected/Plaid account (Scott's own real setup pairs a Manual Checking
/// register with his real, Plaid-synced Savings account) — see `ScheduledTransfer`'s own header
/// for the exact "at least one side must be Manual" rule. See `ScheduledTransfer`/
/// `ScheduledTransferPostingService` for the persisted model and the actual posting logic — this
/// file is presentation only.
struct ScheduledTransfersView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaidConnectionManager.self) private var plaidConnection
    @Query(sort: \ScheduledTransfer.createdAt) private var schedules: [ScheduledTransfer]

    @State private var isPresentingAdd = false
    @State private var editingSchedule: ScheduledTransfer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    if schedules.isEmpty {
                        emptyState
                    } else {
                        CardBackground {
                            VStack(spacing: 0) {
                                ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                                    scheduleRow(schedule)
                                    if index < schedules.count - 1 {
                                        Divider().overlay(Theme.cardStroke)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Scheduled Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Scheduled Transfer")
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isPresentingAdd) {
            AddEditScheduledTransferView()
        }
        .sheet(item: $editingSchedule) { schedule in
            AddEditScheduledTransferView(schedule: schedule)
        }
    }

    private var emptyState: some View {
        EmptyStateCard(
            systemIconName: "arrow.left.arrow.right.circle",
            message: "No scheduled transfers yet. Set one up to automatically move money between your Account Registers every month — e.g. $25 from Checking to Savings on the 15th."
        )
    }

    private func scheduleRow(_ schedule: ScheduledTransfer) -> some View {
        Button {
            editingSchedule = schedule
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scheduleTitle(schedule))
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(schedule.timing.label) \u{00B7} \(CurrencyFormat.string(from: schedule.amount))")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    if !schedule.isActive {
                        Text("Paused")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.textTertiary.opacity(0.15)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scheduleTitle(_ schedule: ScheduledTransfer) -> String {
        let from = partyLabel(account: schedule.sourceAccount, connectedId: schedule.sourceConnectedAccountId)
        let to = partyLabel(account: schedule.destinationAccount, connectedId: schedule.destinationConnectedAccountId)
        return "\(from) \u{2192} \(to)"
    }

    private func partyLabel(account: Account?, connectedId: String?) -> String {
        if let account { return account.name }
        if let connectedId {
            return ConnectedAccountOptionPresenter.label(forAccountId: connectedId, in: plaidConnection.connections) ?? "Connected Account"
        }
        return "\u{2014}"
    }
}

/// Add or edit a `ScheduledTransfer`. Passing `schedule` switches this into edit mode, mirroring
/// `AddAccountView`/`AddEditRecurringExpenseView`'s add/edit pattern — no autosave (unlike
/// `AddEditRecurringExpenseView`), since a schedule is a short, low-friction form with no reason
/// to persist a half-finished draft. Either side may be Manual or Connected/Plaid (see
/// `TransferParty`'s own header) — `@Environment(PlaidConnectionManager.self)` isn't available
/// inside `init`, so a Connected party is seeded with a placeholder label in `init` and resolved
/// to its real, current label in `.task` once the environment IS available (never persisted here
/// either way — only the id is stored on `ScheduledTransfer`).
struct AddEditScheduledTransferView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaidConnectionManager.self) private var plaidConnection

    @Query(sort: \Account.createdAt) private var allAccounts: [Account]

    private let editingSchedule: ScheduledTransfer?

    @State private var amount: Decimal?
    @State private var timing: PlanTiming
    @State private var sourceParty: TransferParty
    @State private var destinationParty: TransferParty
    @State private var isActive: Bool
    @State private var note: String
    @State private var hasAttemptedSave = false
    @State private var isPresentingDeleteConfirmation = false

    /// Only Beginning/Mid/End of Month make sense for a scheduled transfer — `.weekly`/
    /// `.customDate` exist on the shared `PlanTiming` enum purely for `RecurringExpense`'s own use.
    private static let availableTimings: [PlanTiming] = [.beginningMonth, .midMonth, .endMonth]

    init(schedule: ScheduledTransfer? = nil) {
        self.editingSchedule = schedule
        _amount = State(initialValue: schedule?.amount)
        _timing = State(initialValue: schedule?.timing ?? .beginningMonth)
        _sourceParty = State(initialValue: Self.initialParty(account: schedule?.sourceAccount, connectedId: schedule?.sourceConnectedAccountId))
        _destinationParty = State(initialValue: Self.initialParty(account: schedule?.destinationAccount, connectedId: schedule?.destinationConnectedAccountId))
        _isActive = State(initialValue: schedule?.isActive ?? true)
        _note = State(initialValue: schedule?.note ?? "")
    }

    private static func initialParty(account: Account?, connectedId: String?) -> TransferParty {
        if let account { return .manual(account) }
        if let connectedId { return .connected(id: connectedId, label: "") }
        return .none
    }

    private var isEditing: Bool { editingSchedule != nil }

    /// Every Manual Account plus every Connected/Plaid account, offered as selectable From/To
    /// parties — mirrors `AddExpenseView.transferAccountOptions` exactly (a Connected account is
    /// a reference tag only; its balance is never locally mutated).
    private var activeAccounts: [Account] {
        allAccounts.filter { !$0.isArchived }
    }

    private var connectedAccountOptions: [ConnectedAccountOption] {
        ConnectedAccountOptionPresenter.options(for: plaidConnection.connections)
    }

    private var partyOptions: [TransferParty] {
        activeAccounts.map { .manual($0) } + connectedAccountOptions.map { .connected(id: $0.id, label: $0.label) }
    }

    /// Resolves a placeholder Connected party (seeded in `init` with an empty label, before the
    /// environment was available) to its real current label — a no-op for `.manual`/`.none` or a
    /// Connected party whose label is already resolved.
    private func resolvedParty(_ party: TransferParty) -> TransferParty {
        guard case .connected(let id, let label) = party, label.isEmpty else { return party }
        let resolvedLabel = ConnectedAccountOptionPresenter.label(forAccountId: id, in: plaidConnection.connections) ?? "Connected Account"
        return .connected(id: id, label: resolvedLabel)
    }

    private var validationMessages: [String] {
        var messages: [String] = []
        if (amount ?? 0) <= 0 { messages.append("Enter an amount greater than $0.") }
        if sourceParty == .none { messages.append("Choose a \"From\" account.") }
        if destinationParty == .none { messages.append("Choose a \"To\" account.") }
        if sourceParty != .none, sourceParty == destinationParty {
            messages.append("\"From\" and \"To\" must be different accounts.")
        }
        // AT LEAST ONE side must be a real local Manual Account — there is no local `Account`
        // object at all for a Connected account, so a Connected-to-Connected schedule would have
        // nothing to post a transaction against or mutate (see `ScheduledTransfer`'s own header).
        if case .connected = sourceParty, case .connected = destinationParty {
            messages.append("At least one account must be an Account Register you track in this app.")
        }
        return messages
    }

    private var isValid: Bool { validationMessages.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    amountSection
                    detailsSection
                    if hasAttemptedSave, !validationMessages.isEmpty {
                        validationCard
                    }
                    if isEditing {
                        deleteButton
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? "Edit Scheduled Transfer" : "New Scheduled Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PremiumActionButton(title: isEditing ? "Save Changes" : "Add Scheduled Transfer", systemIconName: "checkmark") {
                    save()
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xs)
                .background(.ultraThinMaterial)
            }
            .confirmationDialog(
                "Delete this scheduled transfer?",
                isPresented: $isPresentingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Future transfers will no longer post. Transactions already created stay in your registers.")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            sourceParty = resolvedParty(sourceParty)
            destinationParty = resolvedParty(destinationParty)
        }
    }

    private var amountSection: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                Text("Amount")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                CurrencyAmountField(
                    amount: $amount,
                    style: .hero,
                    isInvalid: hasAttemptedSave && (amount ?? 0) <= 0,
                    accessibilityLabel: "Transfer amount"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var detailsSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Details")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                LabeledPickerRow(title: "From", selection: $sourceParty) {
                    Text("Choose an Account").tag(TransferParty.none)
                    ForEach(Array(partyOptions.enumerated()), id: \.offset) { _, party in
                        Text(party.displayLabel ?? "").tag(party)
                    }
                }

                LabeledPickerRow(title: "To", selection: $destinationParty) {
                    Text("Choose an Account").tag(TransferParty.none)
                    ForEach(Array(partyOptions.enumerated()), id: \.offset) { _, party in
                        Text(party.displayLabel ?? "").tag(party)
                    }
                }

                LabeledPickerRow(title: "Timing", selection: $timing) {
                    ForEach(Self.availableTimings) { option in
                        Text(option.label).tag(option)
                    }
                }

                TransactionToggleRow(
                    title: "Active",
                    subtitle: "Turn off to pause without deleting this schedule",
                    isOn: $isActive
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note (optional)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    TextField("e.g. Monthly savings transfer", text: $note)
                        .textFieldStyle(.plain)
                        .padding(Theme.Spacing.sm)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private var validationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(validationMessages, id: \.self) { message in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.statusOver)
                    Text(message)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.statusOver)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.statusOver.opacity(0.12)))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            isPresentingDeleteConfirmation = true
        } label: {
            Text("Delete Scheduled Transfer")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.statusOver)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.sm)
    }

    /// Splits a `TransferParty` back into the `(Account?, connectedAccountId: String?)` pair
    /// `ScheduledTransfer` actually stores — the exact inverse of `initialParty(account:connectedId:)`.
    private func split(_ party: TransferParty) -> (account: Account?, connectedId: String?) {
        switch party {
        case .none: return (nil, nil)
        case .manual(let account): return (account, nil)
        case .connected(let id, _): return (nil, id)
        }
    }

    private func save() {
        hasAttemptedSave = true
        guard isValid, let amount else { return }
        let source = split(sourceParty)
        let destination = split(destinationParty)
        // At least one side is guaranteed Manual by `validationMessages` above.
        let ownerUserID = source.account?.ownerUserID ?? destination.account?.ownerUserID

        if let editingSchedule {
            editingSchedule.amount = amount
            editingSchedule.timing = timing
            editingSchedule.sourceAccount = source.account
            editingSchedule.sourceConnectedAccountId = source.connectedId
            editingSchedule.destinationAccount = destination.account
            editingSchedule.destinationConnectedAccountId = destination.connectedId
            editingSchedule.isActive = isActive
            editingSchedule.note = note
            editingSchedule.updatedAt = .now
        } else {
            let schedule = ScheduledTransfer(
                amount: amount,
                timing: timing,
                sourceAccount: source.account,
                sourceConnectedAccountId: source.connectedId,
                destinationAccount: destination.account,
                destinationConnectedAccountId: destination.connectedId,
                isActive: isActive,
                note: note,
                ownerUserID: ownerUserID
            )
            modelContext.insert(schedule)
        }
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        guard let editingSchedule else { return }
        modelContext.delete(editingSchedule)
        try? modelContext.save()
        dismiss()
    }
}

#Preview("List") {
    ScheduledTransfersView()
        .modelContainer(SampleData.previewContainer)
}

#Preview("Add") {
    AddEditScheduledTransferView()
        .modelContainer(SampleData.previewContainer)
}
