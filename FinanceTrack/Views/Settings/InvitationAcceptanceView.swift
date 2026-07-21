import SwiftUI

/// PHASE 8 — Secondary invitation acceptance flow. Presented as a full-screen cover from
/// `FinanceTrackApp` once `PendingInvitationRouter` has captured a
/// `spendsmart://household-invitation` link AND the user is signed in. Only ever shows safe
/// pre-acceptance information (Primary display name if available, expiration status) — never
/// household internals, `sharing_permissions`, Plaid data, Manual Account data, or Monthly Plan
/// data, all of which remain out of scope until a future Secondary shared-data browsing phase.
struct InvitationAcceptanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel

    @State private var viewModel: InvitationAcceptanceViewModel

    /// Called once acceptance succeeds — `FinanceTrackApp` uses this to clear the pending
    /// invitation from `PendingInvitationRouter` after the confirmation is dismissed, rather than
    /// this view reaching back into app-root state directly.
    var onFinished: () -> Void = {}

    init(token: String, onFinished: @escaping () -> Void = {}) {
        _viewModel = State(initialValue: InvitationAcceptanceViewModel(token: token))
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    errorView(message)
                case .loaded(let preview):
                    if viewModel.didAccept {
                        confirmationView
                    } else if !preview.found {
                        invalidView
                    } else if preview.isExpired == true {
                        expiredView(preview)
                    } else if preview.status != "pending" {
                        invalidView
                    } else {
                        validInvitationView(preview)
                    }
                }
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Household Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.didAccept ? "Done" : "Not Now") {
                        dismiss()
                        onFinished()
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { await viewModel.loadPreview() }
    }

    // MARK: - States

    private func errorView(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.statusOver)
            Text(message)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
        }
    }

    private var invalidView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "xmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("This invitation is invalid or no longer available.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
        }
    }

    private func expiredView(_ preview: InvitationPreviewResponse) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 48))
                .foregroundStyle(Theme.statusWarning)
            Text("This invitation has expired.")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            if let displayName = preview.primaryDisplayName {
                Text("Ask \(displayName) to send a new invitation.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
            Spacer()
        }
    }

    private var confirmationView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.statusGood)
            Text("You're linked!")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Text("Household linking is complete. Whatever the Primary chooses to share will appear here in a future update.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
        }
    }

    private func validInvitationView(_ preview: InvitationPreviewResponse) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "person.2.circle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("SpendSmart Household Invitation")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(invitationBodyText(preview))
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)

            if let acceptanceError = viewModel.acceptanceError {
                Text(acceptanceError)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.statusOver)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }

            Button {
                Task {
                    await viewModel.accept()
                    if viewModel.didAccept {
                        await accountRelatedOptionsViewModel.refresh()
                    }
                }
            } label: {
                if viewModel.isAccepting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Accept Invitation")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isAccepting)
            .padding(.horizontal, Theme.Spacing.xl)

            Button("Not Now") {
                dismiss()
                onFinished()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .disabled(viewModel.isAccepting)

            Spacer()
        }
    }

    private func invitationBodyText(_ preview: InvitationPreviewResponse) -> String {
        if let displayName = preview.primaryDisplayName, !displayName.isEmpty {
            return "\(displayName) invited you to join their household on SpendSmart."
        }
        return "You've been invited to join a household on SpendSmart."
    }
}
