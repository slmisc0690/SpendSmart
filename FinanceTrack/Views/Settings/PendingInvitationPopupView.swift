import SwiftUI

/// PHASE 8D — automatically presented once per session when `PendingInvitationPopupViewModel
/// .shouldPresentPopup` is true (a genuinely valid pending invitation was discovered for the
/// signed-in user's own verified email — see that view model's own header). Shows only the same
/// safe information `InvitationAcceptanceView`'s manual-link flow already shows — never household
/// internals, `sharing_permissions`, Plaid data, Manual Account data, or Monthly Plan data.
struct PendingInvitationPopupView: View {
    @Environment(PendingInvitationPopupViewModel.self) private var viewModel
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel

    var body: some View {
        NavigationStack {
            content
                .background(Theme.backgroundGradient.ignoresSafeArea())
                .navigationTitle("Household Invitation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // PHASE 8F FOLLOW-UP — "Not Now" removed: the invitation now requires an
                    // explicit Accept or Decline. "Done" is not a replacement skip button — it
                    // only ever appears once one of those has already succeeded, and by then
                    // `shouldPresentPopup` has already gone false on its own (see
                    // `PendingInvitationPopupViewModel`'s own header), so this is purely an
                    // acknowledgment of an already-resolved outcome.
                    if viewModel.didAccept || viewModel.didDecline {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {}
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.didAccept {
            confirmationView
        } else if viewModel.didDecline {
            declinedView
        } else if case .found(let invitation) = viewModel.state {
            invitationView(invitation)
        } else {
            // shouldPresentPopup already gates presentation to the `.found` case — this branch
            // is only reachable for the brief instant between a successful accept/decline
            // clearing `.found` semantics and the confirmation view above taking over.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// PHASE 8D FOLLOW-UP — shown after a successful real decline (not "Not Now", which simply
    /// dismisses this whole popup without ever reaching this branch).
    private var declinedView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "xmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textSecondary)
            Text("Invitation Declined")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Text("You won't be asked about this invitation again.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
        }
    }

    private func invitationView(_ invitation: MyPendingInvitationResponse) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "person.2.circle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("SpendSmart Household Invitation")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(bodyText(invitation))
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
            if let declineError = viewModel.declineError {
                Text(declineError)
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
            .disabled(viewModel.isAccepting || viewModel.isDeclining)
            .padding(.horizontal, Theme.Spacing.xl)

            // PHASE 8D FOLLOW-UP — real server-side decline. See
            // `PendingInvitationPopupViewModel.decline()`'s own doc comment.
            Button {
                Task { await viewModel.decline() }
            } label: {
                if viewModel.isDeclining {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(Theme.statusOver)
            .disabled(viewModel.isAccepting || viewModel.isDeclining)
            .padding(.horizontal, Theme.Spacing.xl)

            Spacer()
        }
    }

    private func bodyText(_ invitation: MyPendingInvitationResponse) -> String {
        if let displayName = invitation.primaryDisplayName, !displayName.isEmpty {
            return "\(displayName) invited you to join their household on SpendSmart."
        }
        return "You've been invited to join a household on SpendSmart."
    }
}
