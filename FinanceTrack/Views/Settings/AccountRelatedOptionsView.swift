import SwiftUI

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
                }
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Account Related Options")
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

// MARK: - 2. Connected Account Sharing

private struct ConnectedAccountSharingSectionView: View {
    let viewModel: AccountRelatedOptionsViewModel

    private static let category = "connectedAccounts"

    var body: some View {
        let response = viewModel.response
        let permissions = response?.sharingPermissions ?? []
        let globalShared = permissions.first(where: { $0.category == Self.category && $0.itemId == nil })?.isShared ?? false

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
                                isShared: accountRelatedOptionsEffectiveIsShared(permissions: permissions, category: Self.category, itemId: account.plaidAccountId),
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
        let permissions = response?.sharingPermissions ?? []
        let globalShared = permissions.first(where: { $0.category == Self.category && $0.itemId == nil })?.isShared ?? false

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
                                isShared: accountRelatedOptionsEffectiveIsShared(permissions: permissions, category: Self.category, itemId: account.id),
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
        let permissions = viewModel.response?.sharingPermissions ?? []
        let globalShared = permissions.first(where: { $0.category == Self.category && $0.itemId == nil })?.isShared ?? false

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
