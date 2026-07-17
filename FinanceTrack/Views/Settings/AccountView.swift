import SwiftUI

/// Shows the signed-in user's email and verification status, and lets them sign out or
/// permanently delete their SpendSmart account. Reachable from Settings.
struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthenticationService.self) private var authService

    @State private var isPresentingSignOutConfirmation = false
    @State private var isPresentingDeleteSheet = false
    @State private var isSigningOut = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    accountSection
                    if let errorMessage {
                        inlineMessage(icon: "exclamationmark.circle.fill", text: errorMessage, color: Theme.statusOver)
                    }
                    dangerZoneSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.textSecondary)
                }
            }
            .confirmationDialog(
                "Sign Out?",
                isPresented: $isPresentingSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task { await signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can sign back in anytime with the same email and password. Your data stays exactly where it is.")
            }
            .sheet(isPresented: $isPresentingDeleteSheet) {
                DeleteAccountConfirmationView()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Account")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack {
                        Text("Email")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(authService.currentUserEmail ?? "—")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                    }

                    Divider().overlay(Theme.cardStroke)

                    HStack {
                        Text("Verification")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        verificationBadge
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var verificationBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: authService.isEmailVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(authService.isEmailVerified ? "Verified" : "Not Verified")
        }
        .font(Theme.captionFont)
        .foregroundStyle(authService.isEmailVerified ? Theme.statusGood : Theme.statusWarning)
    }

    // MARK: - Danger zone

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Manage")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Button {
                        isPresentingSignOutConfirmation = true
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Theme.textTertiary.opacity(0.12)))
                            Text(isSigningOut ? "Signing Out…" : "Sign Out")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSigningOut)

                    Divider().overlay(Theme.cardStroke)

                    Button {
                        isPresentingDeleteSheet = true
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.statusOver)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Theme.statusOver.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delete Account")
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.statusOver)
                                Text("Permanently deletes your SpendSmart account")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func inlineMessage(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(Theme.captionFont)
        }
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signOut() async {
        errorMessage = nil
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await authService.signOut()
            dismiss()
            // RootView switches to the auth flow automatically once sessionState flips to
            // .signedOut — nothing further to do here.
        } catch {
            errorMessage = error.friendlyAuthMessage
        }
    }
}

/// Requires typing the literal word "DELETE" before the destructive action becomes reachable —
/// deliberately more friction than a plain confirmation dialog, since this is irreversible and
/// deletes the shared account both devices use.
private struct DeleteAccountConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaidConnectionManager.self) private var plaidConnection

    @State private var confirmationText = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var canDelete: Bool {
        confirmationText == "DELETE" && !isDeleting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    VStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(Theme.statusOver)

                        Text("This permanently deletes your SpendSmart account and every connected financial institution. This cannot be undone, and affects every device signed into this account.")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    CardBackground {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Type DELETE to confirm")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            TextField("DELETE", text: $confirmationText)
                                .textFieldStyle(.plain)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .padding(Theme.Spacing.sm)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(errorMessage)
                                .font(Theme.captionFont)
                        }
                        .foregroundStyle(Theme.statusOver)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await delete() }
                    } label: {
                        Text(isDeleting ? "Deleting Account…" : "Permanently Delete Account")
                            .font(Theme.headlineFont)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.sm + 2)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.statusOver))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDelete)
                    .opacity(canDelete ? 1 : 0.5)
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Local cleanup ONLY runs after `authService.deleteAccount()` has already succeeded — the
    /// server-side account is unrecoverable at that point, so there's no scenario where deleting
    /// local data first and having the server call fail could leave the user in a worse spot.
    /// Never reversed: if `deleteAccount()` throws, execution never reaches the cleanup below,
    /// and the user's local data is untouched.
    private func delete() async {
        errorMessage = nil
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await authService.deleteAccount()
            PlaidLocalDataCleanupService.deleteAllLocalData(context: modelContext)
            plaidConnection.clearAllConnections()
            dismiss()
            // RootView switches to the auth flow automatically once sessionState flips to
            // .signedOut — nothing further to do here.
        } catch {
            errorMessage = error.friendlyAuthMessage
        }
    }
}

#Preview {
    AccountView()
        .environment(AuthenticationService.shared)
}
