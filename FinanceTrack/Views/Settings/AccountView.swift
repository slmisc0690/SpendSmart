import SwiftUI

/// SETTINGS ORGANIZATION PHASE — this is the canonical "Profile" destination (`Settings ▸
/// Profile`, and the `.profile` Dashboard Favorite). The Swift type name `AccountView` is
/// deliberately UNCHANGED (only its `navigationTitle` and Settings-facing row label became
/// "Profile") — renaming the type itself would have touched ~15 pre-existing, still-accurate
/// regression tests that scan this exact file/property names (sign-out crash-fix history, sticky-
/// mirror display tests, etc.), for zero behavioral benefit. Shows the signed-in user's email and
/// verification status, a future-Subscription placeholder, and lets them sign out or permanently
/// delete their SpendSmart account. Reachable from Settings. Favorites lives on the main Settings
/// screen, not here — see `SettingsView`.
struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthenticationService.self) private var authService

    @State private var isPresentingSignOutConfirmation = false
    @State private var isPresentingDeleteSheet = false
    @State private var isSigningOut = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        accountSection
                        subscriptionSection
                        if let errorMessage {
                            inlineMessage(icon: "exclamationmark.circle.fill", text: errorMessage, color: Theme.statusOver)
                        }
                        signOutSection
                    }
                    .padding(.vertical, Theme.Spacing.lg)
                }
                Spacer(minLength: 0)
                // Deliberately pinned OUTSIDE the ScrollView via the Spacer above, so it always
                // sits at the very bottom of the screen — not just the bottom of the scrollable
                // content — regardless of how much other content is above it.
                deleteAccountSection
                    .padding(.bottom, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Profile")
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
            DashboardSectionHeader(title: "Profile")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack {
                        Text("Email")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(authService.lastDisplayedUserEmail ?? "—")
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

    // MARK: - Subscription (future placeholder — no StoreKit/billing yet)

    /// Placeholder only — no purchase flow, no StoreKit, no fabricated subscription status. Exists
    /// so a real subscription section has a stable, already-reviewed slot to land in later without
    /// another Profile-layout change. Not tappable.
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Subscription")

            CardBackground {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Subscription")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Coming soon")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var verificationBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: authService.lastDisplayedIsEmailVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(authService.lastDisplayedIsEmailVerified ? "Verified" : "Not Verified")
        }
        .font(Theme.captionFont)
        .foregroundStyle(authService.lastDisplayedIsEmailVerified ? Theme.statusGood : Theme.statusWarning)
    }

    // MARK: - Sign out

    /// CORRECTION (2026-08-18, Scott's explicit request) — sized down from the original full-width
    /// headline-styled pill: smaller font, smaller padding, intrinsic (not full-width) size,
    /// still centered. Red background/white text destructive styling unchanged.
    private var signOutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Manage")

            HStack {
                Spacer()
                Button {
                    isPresentingSignOutConfirmation = true
                } label: {
                    Text(isSigningOut ? "Signing Out…" : "Sign Out")
                        .font(Theme.bodyFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs + 2)
                        .background(Capsule().fill(Theme.statusOver))
                }
                .buttonStyle(.plain)
                .disabled(isSigningOut)
                .opacity(isSigningOut ? 0.6 : 1)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Delete account

    /// CORRECTION (2026-08-18, Scott's explicit request) — sized down the same way as Sign Out
    /// (smaller font/padding, intrinsic width, centered). Still deliberately the LAST section
    /// rendered on this screen (see `body`'s own comment) per the locked "move Delete Account all
    /// the way to the bottom" requirement — only the size changed here, not the placement, which
    /// was already correct. Tapping still opens the same `DeleteAccountConfirmationView`
    /// type-DELETE-to-confirm sheet, unchanged.
    private var deleteAccountSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack {
                Spacer()
                Button {
                    isPresentingDeleteSheet = true
                } label: {
                    Text("Delete Account")
                        .font(Theme.captionFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Capsule().fill(Theme.statusOver))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.lg)

            Text("Permanently deletes your SpendSmart account")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
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
            // Deliberately no `dismiss()` here. `sessionState` flipping to `.signedOut` is what
            // drives `FinanceTrackApp`'s root swap from the authenticated subtree to `AuthFlowView`
            // — this view (and everything presenting it, up through `SettingsView`) is torn down
            // as part of that same swap. An explicit `dismiss()` here is a SEPARATE, independently
            // animated sheet-dismissal that races that session-driven teardown: `SettingsView` can
            // render one more frame while its own sheet is closing and touch its still-live
            // `BudgetSettings`/`@Query` state after the outgoing user's `ModelContext`/container has
            // already been reset/detached elsewhere — the proven cause of a real device crash
            // ("This model instance was destroyed by calling ModelContext.reset... BudgetSettings/p1")
            // immediately after a successful sign-out. `sessionState`/`RootView` must be the ONLY
            // thing that ever replaces this UI on a successful sign-out.
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
            // Deliberately no `dismiss()` here — same reasoning as `AccountView.signOut()`'s own
            // doc comment: `sessionState` flipping to `.signedOut` is what drives `RootView`'s
            // replacement, and a separate explicit `dismiss()` races that session-driven teardown
            // (the proven cause of a real "ModelContext.reset... BudgetSettings" crash immediately
            // after a successful sign-out/account-exit).
        } catch {
            errorMessage = error.friendlyAuthMessage
        }
    }
}

#Preview {
    AccountView()
        .environment(AuthenticationService.shared)
}
