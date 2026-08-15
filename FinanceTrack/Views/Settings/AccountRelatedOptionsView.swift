import SwiftUI
import SwiftData

/// PHASE 7 — Account Related Options / Primary sharing controls. Primary-only: `SettingsView`
/// only ever presents this sheet once `AccountRelatedOptionsViewModel.visibility` has resolved to
/// `.entryPoint` or `.primary` from the SERVER's own `get-account-related-options` response (see
/// that view model's own header for why this is the trusted signal, not local state).
///
/// Sections, per this phase's own locked layout: 1) Household / Secondary User, 2) Connected
/// Account Sharing, 3) Manual Account Sharing, 4) Monthly Plan Sharing (global-only — no per-item
/// row exists for this category, matching migration 0008's own CHECK constraint).
struct AccountRelatedOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountRelatedOptionsViewModel.self) private var viewModel

    @State private var inviteEmail = ""

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.visibility {
                case .hidden:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .entryPoint:
                    entryPointView
                case .primary:
                    primaryContent
                case .secondary:
                    secondaryContent
                }
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(viewModel.visibility == .secondary ? "Share Connected Account" : "Account Related Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { await viewModel.refresh() }
    }

    // MARK: - Entry point (no household yet)

    private var entryPointView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "person.2.circle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("Household Sharing")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Text("Set up household sharing to invite one other person to view accounts and plans you choose to share.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)

            if let actionError = viewModel.actionError {
                Text(actionError)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.statusOver)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }

            Button {
                Task { await viewModel.createHousehold() }
            } label: {
                if viewModel.activeMutation == .createHousehold {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Set Up Household Sharing")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.activeMutation == .createHousehold)
            .padding(.horizontal, Theme.Spacing.xl)

            Spacer()
        }
    }

    // MARK: - Primary content

    private var primaryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if let actionError = viewModel.actionError {
                    Text(actionError)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.statusOver)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                HouseholdSharingSectionView(viewModel: viewModel, inviteEmail: $inviteEmail)
                ConnectedAccountSharingSectionView(viewModel: viewModel)
                ManualAccountSharingSectionView(viewModel: viewModel)
                MonthlyPlanSharingSectionView(viewModel: viewModel)
                MonthlySavingsSharingSectionView(viewModel: viewModel)
                SavedViaTransferSharingSectionView(viewModel: viewModel)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    // MARK: - Secondary content (PHASE 8D)

    /// Active-Secondary-only: exactly TWO controls, "Share Connected Account" and "Share Manual
    /// Account" — never any Primary household-administration, global-sharing, or invitation
    /// control, and never a Monthly Plan control (a Secondary has no sharing control for that
    /// category in this phase). See this phase's own architecture finding (migration 0015's
    /// header) for why this is safe: a Secondary shares their OWN accounts back to the Primary via
    /// the same directionless `sharing_permissions` model, through narrow trusted write paths
    /// scoped to exactly this, one per category.
    private var secondaryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if let actionError = viewModel.actionError {
                    Text(actionError)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.statusOver)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                SharedByPrimarySectionView(viewModel: viewModel)
                SecondaryShareConnectedAccountSectionView(viewModel: viewModel)
                SecondaryShareManualAccountSectionView(viewModel: viewModel)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
    }
}

// MARK: - 1. Household / Secondary User

private struct HouseholdSharingSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel
    @Binding var inviteEmail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Household / Secondary User")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if let secondary = viewModel.response?.secondaryMember {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(secondary.email ?? "Secondary member")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Active Secondary")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.statusGood)
                        }
                    } else if let invitation = viewModel.response?.pendingInvitation {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invitation.invitedEmail)
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Invitation pending · expires \(invitation.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }

                        HStack(spacing: Theme.Spacing.sm) {
                            Button {
                                Task { await viewModel.resendInvitation() }
                            } label: {
                                if viewModel.activeMutation == .resendInvitation {
                                    ProgressView()
                                } else {
                                    Text("Resend")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.activeMutation == .resendInvitation || viewModel.activeMutation == .revokeInvitation)

                            Button(role: .destructive) {
                                Task { await viewModel.revokeInvitation() }
                            } label: {
                                if viewModel.activeMutation == .revokeInvitation {
                                    ProgressView()
                                } else {
                                    Text("Revoke")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.activeMutation == .resendInvitation || viewModel.activeMutation == .revokeInvitation)
                        }

                        // No automated email delivery exists yet (see
                        // manage-household-invitation's own header) — the Primary shares this
                        // link manually via the OS share sheet. Only offered right after a
                        // successful invite/resend in this same session; cleared on revoke.
                        if let invitationUrl = viewModel.lastInvitationUrl, let url = URL(string: invitationUrl) {
                            ShareLink(item: url) {
                                Label("Share Invitation Link", systemImage: "square.and.arrow.up")
                                    .font(Theme.captionFont)
                            }
                        }
                    } else {
                        Text("Invite one other person to your household. They'll be able to view whatever you choose to share.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)

                        TextField("Email address", text: $inviteEmail)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)

                        Button {
                            let email = inviteEmail
                            Task {
                                await viewModel.invite(email: email)
                                // Only clears the field on confirmed success — a failed send
                                // leaves the entered email in place so it isn't lost.
                                if viewModel.actionError == nil {
                                    inviteEmail = ""
                                }
                            }
                        } label: {
                            if viewModel.activeMutation == .sendInvitation {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Send Invitation")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.activeMutation == .sendInvitation || inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

// MARK: - Shared global/per-item toggle row

private struct SharingGlobalToggleRow: View {
    let title: String
    let isShared: Bool
    let isDisabled: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isShared }, set: { onChange($0) })) {
            Text(title)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
        }
        .disabled(isDisabled)
    }
}

private struct SharingItemToggleRow: View {
    let title: String
    let subtitle: String?
    let isShared: Bool
    let isDisabled: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isShared }, set: { onChange($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .disabled(isDisabled)
    }
}

/// Effective-sharing lookup shared by every category — matches migration 0008's
/// `is_effectively_shared_for_user` semantics exactly for local display purposes only (the server
/// remains authoritative; this is display convenience, not a second evaluator).
func accountRelatedOptionsEffectiveIsShared(
    permissions: [SharingPermissionDTO],
    category: String,
    itemId: UUID?
) -> Bool {
    guard let global = permissions.first(where: { $0.category == category && $0.itemId == nil }) else {
        return false
    }
    guard global.isShared else { return false }
    guard let itemId else { return true }
    guard let item = permissions.first(where: { $0.category == category && $0.itemId == itemId }) else {
        return true
    }
    return item.isShared
}

/// PHASE 8D — how many of the given account ids (of the given category) are NOT currently shared
/// (per `accountRelatedOptionsEffectiveIsShared`'s own semantics). Drives both "Share Connected
/// Account" and "Share Manual Account"'s own enabled/grayed state: >0 means at least one own
/// account of that category remains eligible to share.
func accountRelatedOptionsUnsharedAccountCount(
    accountIds: [UUID],
    category: String,
    permissions: [SharingPermissionDTO]
) -> Int {
    accountIds.filter { !accountRelatedOptionsEffectiveIsShared(permissions: permissions, category: category, itemId: $0) }.count
}

/// Backward-compatible convenience for the Connected-Account-only call site — see the
/// category-parameterized `accountRelatedOptionsUnsharedAccountCount` this now delegates to.
func accountRelatedOptionsUnsharedConnectedAccountCount(
    accountIds: [UUID],
    permissions: [SharingPermissionDTO]
) -> Int {
    accountRelatedOptionsUnsharedAccountCount(accountIds: accountIds, category: "connectedAccounts", permissions: permissions)
}

/// PHASE 9 — whether the "Shared with You" section has anything at all to show for the given
/// Secondary's own `AccountRelatedOptionsResponse`. A `nil` response (not yet loaded) or a
/// response where the Primary has shared nothing in any category both mean false — the section
/// then shows its own quiet empty-state message rather than an empty card.
func accountRelatedOptionsHasAnyPrimarySharedData(_ response: AccountRelatedOptionsResponse?) -> Bool {
    guard let response else { return false }
    return !response.primarySharedConnectedAccounts.isEmpty
        || !response.primarySharedManualAccounts.isEmpty
        || response.primaryMonthlyPlanShared
}

// MARK: - 2. Connected Account Sharing

private struct ConnectedAccountSharingSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    private static let category = "connectedAccounts"

    var body: some View {
        let response = viewModel.response
        let globalShared = viewModel.isShared(category: Self.category, itemId: nil)

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Connected Account Sharing")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    SharingGlobalToggleRow(
                        title: "Share Connected Accounts",
                        isShared: globalShared,
                        isDisabled: viewModel.activeMutation == .connectedGlobal
                    ) { newValue in
                        Task { await viewModel.setGlobalSharing(category: Self.category, isShared: newValue) }
                    }

                    if globalShared, let accounts = response?.connectedAccounts, !accounts.isEmpty {
                        Divider().overlay(Theme.cardStroke)
                        ForEach(accounts) { account in
                            SharingItemToggleRow(
                                title: account.name ?? "Connected Account",
                                subtitle: account.mask.map { "•••• \($0)" },
                                isShared: viewModel.isShared(category: Self.category, itemId: account.plaidAccountId),
                                isDisabled: viewModel.activeMutation == .connectedItem(account.plaidAccountId)
                            ) { newValue in
                                Task {
                                    await viewModel.setItemSharing(category: Self.category, itemId: account.plaidAccountId, isShared: newValue)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

// MARK: - 3. Manual Account Sharing

private struct ManualAccountSharingSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    private static let category = "manualAccounts"

    var body: some View {
        let response = viewModel.response
        let globalShared = viewModel.isShared(category: Self.category, itemId: nil)

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Manual Account Sharing")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    SharingGlobalToggleRow(
                        title: "Share Manual Accounts",
                        isShared: globalShared,
                        isDisabled: viewModel.activeMutation == .manualGlobal
                    ) { newValue in
                        Task { await viewModel.setGlobalSharing(category: Self.category, isShared: newValue) }
                    }

                    if globalShared, let accounts = response?.manualAccounts, !accounts.isEmpty {
                        Divider().overlay(Theme.cardStroke)
                        ForEach(accounts) { account in
                            SharingItemToggleRow(
                                title: account.name,
                                subtitle: nil,
                                isShared: viewModel.isShared(category: Self.category, itemId: account.id),
                                isDisabled: viewModel.activeMutation == .manualItem(account.id)
                            ) { newValue in
                                Task {
                                    await viewModel.setItemSharing(category: Self.category, itemId: account.id, isShared: newValue)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

// MARK: - 4. Monthly Plan Sharing (global-only, no per-item UI)

private struct MonthlyPlanSharingSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    private static let category = "monthlyPlan"

    var body: some View {
        let globalShared = viewModel.isShared(category: Self.category, itemId: nil)

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Monthly Plan Sharing")

            CardBackground {
                SharingGlobalToggleRow(
                    title: "Share Monthly Plan",
                    isShared: globalShared,
                    isDisabled: viewModel.activeMutation == .monthlyPlan
                ) { newValue in
                    Task { await viewModel.setGlobalSharing(category: Self.category, isShared: newValue) }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

// MARK: - 4b. Monthly Savings Sharing (global-only, no per-item UI — CLIENT UI PHASE)

/// `monthlySavings` is a NEW, INDEPENDENT sharing category (migration 0018) — explicitly NOT
/// coupled to `monthlyPlan` above; toggling one never affects the other, both client-side (see
/// `AccountRelatedOptionsViewModel.setGlobalSharing`'s explicit `"monthlySavings"` case) and
/// server-side (`set_sharing_permission`'s own independent allowlist entry). When ON, an
/// authorized Secondary may see exactly two aggregate totals — Saved This Month and Total Savings
/// to Date — never individual `SavingsEntry` history or the Savings Goal (see
/// `get_shared_monthly_savings_summary`'s own header).
private struct MonthlySavingsSharingSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    /// CLIENT CORRECTION — real-device fix: turning this toggle ON must itself reconcile the
    /// Primary's CURRENT aggregate to the server, not merely wait for the next unrelated Dashboard/
    /// Monthly Plan lifecycle trigger (which could be minutes away, or never, if the Primary
    /// doesn't happen to revisit either screen). `AccountRelatedOptionsViewModel` intentionally has
    /// no SwiftData dependency of its own (see its own header) — this `@Query` lives here, in the
    /// one Primary-only view that already needs it, and is passed down only as a plain closure via
    /// `setGlobalSharing`'s `onSuccessfullyEnabled` hook.
    @Query private var savingsEntries: [SavingsEntry]

    private static let category = "monthlySavings"

    var body: some View {
        let globalShared = viewModel.isShared(category: Self.category, itemId: nil)

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Monthly Savings Sharing")

            CardBackground {
                SharingGlobalToggleRow(
                    title: "Share Monthly Savings",
                    isShared: globalShared,
                    isDisabled: viewModel.activeMutation == .monthlySavings
                ) { newValue in
                    Task {
                        await viewModel.setGlobalSharing(category: Self.category, isShared: newValue) {
                            await SavingsSummarySyncService.sync(entries: savingsEntries)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

// MARK: - 4c. Saved via Transfer Sharing (global-only, no per-item UI — SAVED VIA TRANSFER SHARING)

/// `savedViaTransfer` is a NEW, INDEPENDENT sharing category (migration 0023) — explicitly NOT
/// coupled to `monthlyPlan`/`monthlySavings` above; toggling one never affects the others, both
/// client-side (see `AccountRelatedOptionsViewModel.setGlobalSharing`'s explicit
/// `"savedViaTransfer"` case) and server-side (`set_sharing_permission`'s own independent
/// allowlist entry). When ON, an authorized Secondary may see exactly one aggregate total — Saved
/// via Transfer This Month — never individual Manual Account register transactions (see
/// `get_shared_saved_via_transfer_summary`'s own header).
private struct SavedViaTransferSharingSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    /// Mirrors `MonthlySavingsSharingSectionView`'s own "reconcile on enable" fix — turning this
    /// toggle ON must itself push the Primary's CURRENT aggregate, not wait for the next unrelated
    /// Dashboard lifecycle trigger.
    @Query private var transactions: [FinanceTransaction]

    private static let category = "savedViaTransfer"

    var body: some View {
        let globalShared = viewModel.isShared(category: Self.category, itemId: nil)

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Saved via Transfer Sharing")

            CardBackground {
                SharingGlobalToggleRow(
                    title: "Share Saved (Transfers)",
                    isShared: globalShared,
                    isDisabled: viewModel.activeMutation == .savedViaTransfer
                ) { newValue in
                    Task {
                        await viewModel.setGlobalSharing(category: Self.category, isShared: newValue) {
                            await SavedViaTransferSummarySyncService.sync(transactions: transactions)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

// MARK: - Secondary: data shared BY the Primary (PHASE 9)

/// Active-Secondary-only — the counterpart to `SecondaryShareConnectedAccountSectionView`/
/// `SecondaryShareManualAccountSectionView` below: those show what THIS Secondary shares back to
/// the Primary; this shows what the Primary currently, effectively shares WITH this Secondary
/// (from `AccountRelatedOptionsResponse`'s own `primary*` fields — migration 0016's
/// `get_secondary_shared_data`, already scoped server-side to only effectively-shared items). Row
/// taps navigate to a dedicated read-only detail screen (`SharedConnectedAccountDetailView`/
/// `SharedManualAccountDetailView`/`SharedMonthlyPlanView`) — none of which ever touches
/// SwiftData, so Primary-owned data can never be confused with or written into this Secondary's
/// own owned records. Every re-open of this screen re-fetches (`viewModel.refresh()`, this view's
/// own `.task`), which is also how revoked sharing disappears here on its own.
private struct SharedByPrimarySectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    private var response: AccountRelatedOptionsResponse? { viewModel.response }

    private var hasAnythingShared: Bool {
        accountRelatedOptionsHasAnyPrimarySharedData(response)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Shared with You")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if !hasAnythingShared {
                        Text("Your household Primary hasn't shared anything with you yet.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        if let response {
                            ForEach(Array(response.primarySharedConnectedAccounts.enumerated()), id: \.element.id) { index, account in
                                if index > 0 { Divider().overlay(Theme.cardStroke) }
                                NavigationLink {
                                    SharedConnectedAccountDetailView(account: account)
                                } label: {
                                    SharedAccountRow(title: account.name ?? "Connected Account", subtitle: account.mask.map { "•••• \($0)" })
                                }
                            }
                            ForEach(Array(response.primarySharedManualAccounts.enumerated()), id: \.element.id) { index, account in
                                if index > 0 || !response.primarySharedConnectedAccounts.isEmpty { Divider().overlay(Theme.cardStroke) }
                                NavigationLink {
                                    SharedManualAccountDetailView(account: account)
                                } label: {
                                    SharedAccountRow(title: account.name, subtitle: nil)
                                }
                            }
                            if response.primaryMonthlyPlanShared, let primaryUserId = response.primaryUserId {
                                if !response.primarySharedConnectedAccounts.isEmpty || !response.primarySharedManualAccounts.isEmpty {
                                    Divider().overlay(Theme.cardStroke)
                                }
                                NavigationLink {
                                    SharedMonthlyPlanView(primaryUserId: primaryUserId)
                                } label: {
                                    SharedAccountRow(title: "Monthly Plan", subtitle: nil)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

private struct SharedAccountRow: View {
    let title: String
    let subtitle: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            SharedBadge()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 5. Secondary: Share Connected Account (PHASE 8D)

/// Shown ONLY for an active Secondary. Lists the Secondary's own Connected Accounts as toggle
/// rows — each one directly IS the "Share Connected Account" control for that account. The
/// section-level summary line reflects this phase's own locked availability rule ("enabled if
/// the Secondary has at least one own account not yet shared; grayed once every owned account is
/// already shared") without needing a separate picker sheet, reusing the exact same
/// `SharingItemToggleRow` component (and its already-correct optimistic/rollback/busy behavior)
/// the Primary's own per-item sections use.
private struct SecondaryShareConnectedAccountSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    private static let category = "connectedAccounts"

    private var accounts: [ConnectedAccountShareDTO] {
        viewModel.response?.connectedAccounts ?? []
    }

    private var unsharedCount: Int {
        accountRelatedOptionsUnsharedConnectedAccountCount(
            accountIds: accounts.map(\.plaidAccountId),
            permissions: viewModel.response?.sharingPermissions ?? []
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Share Connected Account")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if accounts.isEmpty {
                        Text("You have no Connected Accounts of your own to share yet.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    } else if unsharedCount == 0 {
                        Text("All of your Connected Accounts are already shared with your household Primary.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("Choose which of your own Connected Accounts to share with your household Primary.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    if !accounts.isEmpty {
                        Divider().overlay(Theme.cardStroke)
                        ForEach(accounts) { account in
                            SharingItemToggleRow(
                                title: account.name ?? "Connected Account",
                                subtitle: account.mask.map { "•••• \($0)" },
                                isShared: viewModel.isShared(category: Self.category, itemId: account.plaidAccountId),
                                isDisabled: viewModel.activeMutation == .connectedItem(account.plaidAccountId)
                            ) { newValue in
                                Task {
                                    await viewModel.setItemSharing(category: Self.category, itemId: account.plaidAccountId, isShared: newValue)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

// MARK: - 6. Secondary: Share Manual Account (PHASE 8D follow-up)

/// Exact structural mirror of `SecondaryShareConnectedAccountSectionView` above — same
/// enabled/grayed rule, same reuse of `SharingItemToggleRow`'s already-correct
/// optimistic/rollback/busy behavior. `accounts` is scoped server-side to
/// `manual_accounts.owner_user_id = caller` only (see get-account-related-options's own Phase 8D
/// header) — a Manual Account the Primary owns and has merely shared WITH this Secondary can never
/// appear here, so it can never be selected and can never be re-shared back to its actual owner.
private struct SecondaryShareManualAccountSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    private static let category = "manualAccounts"

    private var accounts: [ManualAccountShareDTO] {
        viewModel.response?.manualAccounts ?? []
    }

    private var unsharedCount: Int {
        accountRelatedOptionsUnsharedAccountCount(
            accountIds: accounts.map(\.id),
            category: Self.category,
            permissions: viewModel.response?.sharingPermissions ?? []
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Share Manual Account")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if accounts.isEmpty {
                        Text("You have no Manual Accounts of your own to share yet.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    } else if unsharedCount == 0 {
                        Text("All of your Manual Accounts are already shared with your household Primary.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("Choose which of your own Manual Accounts to share with your household Primary.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    if !accounts.isEmpty {
                        Divider().overlay(Theme.cardStroke)
                        ForEach(accounts) { account in
                            SharingItemToggleRow(
                                title: account.name,
                                subtitle: nil,
                                isShared: viewModel.isShared(category: Self.category, itemId: account.id),
                                isDisabled: viewModel.activeMutation == .manualItem(account.id)
                            ) { newValue in
                                Task {
                                    await viewModel.setItemSharing(category: Self.category, itemId: account.id, isShared: newValue)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}
