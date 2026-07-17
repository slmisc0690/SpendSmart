import SwiftUI
import SwiftData
import LinkKit
import os

/// Plaid Link conversion/diagnostic logging ("Implement Link conversion logging" onboarding
/// item) — Apple Unified Logging (`os.Logger`), which (unlike `#if DEBUG print`) is compiled into
/// every build configuration and remains inspectable in Release/TestFlight/App Store builds via
/// Console.app or `log stream`/`log show --predicate '...'`, filtered to this dedicated
/// `"PlaidLink"` category.
///
/// SAFETY: `SafeLinkLogEvent` is a closed allowlist, never a passthrough of LinkKit's own
/// `EventMetadata`/`SuccessMetadata`/`ExitMetadata` types — those also carry
/// `accountNumberMask`, `routingNumber`, and a raw `metadataJSON` blob, none of which this type
/// has a field for. Every call site extracts only the specific fields listed here; there is no
/// path through this type that can carry a token, account number, or raw metadata dictionary,
/// because it structurally has nowhere to put one. `name` is always a short, fixed event/step
/// identifier (e.g. `"open"`, `"public_token_exchange_success"`) — never free text drawn from
/// Plaid's own error/display messages, which aren't guaranteed to stay free of institution-
/// specific detail.
enum PlaidLinkLogging {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scott.financetrack",
        category: "PlaidLink"
    )

    struct SafeLinkLogEvent: Equatable {
        let name: String
        let sessionType: String?
        let institutionID: String?
        let institutionName: String?
        let errorCode: String?
        let viewName: String?
        let linkSessionID: String?
    }

    static func sessionType(isReconnect: Bool) -> String {
        isReconnect ? "reconnect" : "new_connection"
    }

    /// Pure builder for a LinkKit `onEvent` callback firing — covers institution selection, OAuth
    /// handoff (`openOAuth`/`closeOAuth`/`failOAuth`/`handoff`), view transitions, and every other
    /// event in LinkKit's `EventName` enum, via the same safe extraction regardless of which one
    /// fired. Separated from `logLinkEvent` (the side-effecting call) so this mapping is directly
    /// unit-testable without needing a live Logger/LinkKit event.
    static func makeLinkEvent(
        eventName: String,
        isReconnect: Bool,
        institutionID: String?,
        institutionName: String?,
        errorCode: String?,
        viewName: String?,
        linkSessionID: String?
    ) -> SafeLinkLogEvent {
        SafeLinkLogEvent(
            name: eventName,
            sessionType: sessionType(isReconnect: isReconnect),
            institutionID: institutionID,
            institutionName: institutionName,
            errorCode: errorCode,
            viewName: viewName,
            linkSessionID: linkSessionID
        )
    }

    /// Pure builder for an app-level lifecycle step outside LinkKit's own event stream —
    /// link-token creation, public-token exchange, duplicate-Item decisions, final completion,
    /// etc. Separated from `logLifecycle` for the same reason as `makeLinkEvent` above.
    static func makeLifecycleEvent(
        _ name: String,
        isReconnect: Bool? = nil,
        institutionName: String? = nil,
        errorCode: String? = nil
    ) -> SafeLinkLogEvent {
        SafeLinkLogEvent(
            name: name,
            sessionType: isReconnect.map(sessionType),
            institutionID: nil,
            institutionName: institutionName,
            errorCode: errorCode,
            viewName: nil,
            linkSessionID: nil
        )
    }

    static func logLinkEvent(
        eventName: String,
        isReconnect: Bool,
        institutionID: String?,
        institutionName: String?,
        errorCode: String?,
        viewName: String?,
        linkSessionID: String?
    ) {
        log(makeLinkEvent(
            eventName: eventName,
            isReconnect: isReconnect,
            institutionID: institutionID,
            institutionName: institutionName,
            errorCode: errorCode,
            viewName: viewName,
            linkSessionID: linkSessionID
        ))
    }

    static func logLifecycle(
        _ name: String,
        isReconnect: Bool? = nil,
        institutionName: String? = nil,
        errorCode: String? = nil
    ) {
        log(makeLifecycleEvent(name, isReconnect: isReconnect, institutionName: institutionName, errorCode: errorCode))
    }

    private static func log(_ event: SafeLinkLogEvent) {
        logger.log("plaid_link event=\(event.name, privacy: .public) session=\(event.sessionType ?? "-", privacy: .public) institution_id=\(event.institutionID ?? "-", privacy: .public) institution_name=\(event.institutionName ?? "-", privacy: .public) error_code=\(event.errorCode ?? "-", privacy: .public) view=\(event.viewName ?? "-", privacy: .public) link_session_id=\(event.linkSessionID ?? "-", privacy: .public)")
    }
}

/// Which "your connection may stop working soon" warning, if any, a connection card should show —
/// a pure decision extracted from `connectionCard(_:)` specifically so the priority rule ("Follow
/// Link UI best practices": pending disconnect must win over pending expiration, never show both
/// at once) is unit-testable without needing a live SwiftUI view. `requiresReauth` is deliberately
/// NOT modeled here — that's a harder, already-broken state with its own existing branch in
/// `connectionCard`, evaluated before this is ever consulted.
enum PlaidConnectionWarning: Equatable {
    case none
    case pendingDisconnect(Date)
    case pendingExpiration(Date)

    /// `pendingDisconnectAt` wins whenever both are present — Plaid's own `LOGIN_REPAIRED`
    /// webhook clears both flags together, so a stale case where only one was cleared already
    /// reads as "the more urgent one is still real," never as "show two confusing warnings."
    static func evaluate(pendingDisconnectAt: Date?, pendingExpirationAt: Date?) -> PlaidConnectionWarning {
        if let pendingDisconnectAt {
            return .pendingDisconnect(pendingDisconnectAt)
        }
        if let pendingExpirationAt {
            return .pendingExpiration(pendingExpirationAt)
        }
        return .none
    }
}

/// Shows every linked financial institution and lets the user connect more — ANY institution
/// Plaid supports under the `transactions` product, never assumed to be American Express (an
/// earlier version of this screen hardcoded that assumption throughout; see the multi-institution
/// architecture work). Real backend calls only — this talks to `PlaidBackendService` (your
/// Supabase Edge Functions), never to Plaid directly, and never sees a Plaid credential. Until
/// `PlaidBackendConfig.baseURL` is set (see `supabase/README.md`), every backend call fails with a
/// clear "not configured" message rather than silently pretending to succeed.
///
/// Plaid Link itself (the hosted UI that collects bank credentials) is presented via `LinkKit`.
/// This view only ever sees the `link_token` (from `create-link-token`) and the resulting
/// `public_token`/institution metadata (handed straight to `exchange-public-token`) — it never
/// sees a bank credential, a Plaid `access_token`, or a Plaid client secret; those exist only
/// inside the Supabase Edge Functions and their Postgres tables.
struct ConnectedAccountsView: View {
    // `LinkKit` also exports a type named `Environment` (its sandbox/production enum), which
    // collides with SwiftUI's `@Environment` property wrapper once both modules are imported —
    // qualify it here to disambiguate.
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(PlaidConnectionManager.self) private var plaidConnection
    @SwiftUI.Environment(\.modelContext) private var modelContext
    @SwiftUI.Environment(AuthenticationService.self) private var authService

    /// Normally this screen is only reachable at all while signed in (Settings itself is behind
    /// `RootView`'s auth gate) — but an in-session auth failure (expired/revoked token) can still
    /// flip this to false while the screen is already open, so it's checked here too, not just at
    /// the RootView level.
    private var isSignedIn: Bool { authService.sessionState == .signedIn }

    private let backend: PlaidBackendService = SupabasePlaidBackendService()

    @State private var connectionAttempt: ConnectionAttempt = .idle
    /// Which connection a per-row action (refresh/reconnect/disconnect) is currently running
    /// against — nil means no row-scoped action is in flight. A single property is enough since
    /// only one Link sheet/one backend call can realistically be in flight from user action at a
    /// time in this UI.
    @State private var activeConnectionId: String?
    @State private var isPresentingDisconnectConfirmation = false
    @State private var connectionPendingDisconnect: String?
    @State private var isPresentingImportReview = false
    @State private var linkSession: PlaidLinkSession?
    @State private var isPresentingLink = false
    /// Whether the in-flight Link session is a reconnect (update mode) for an existing
    /// connection, vs. a brand-new one — determines what `handleLinkSuccess` does afterward.
    @State private var linkReconnectingConnectionId: String?
    @State private var balancesByConnectionId: [String: [PlaidAccountBalance]] = [:]
    /// e.g. "Imported 187 new transactions" per connection — set after a successful
    /// refresh/initial sync for that connection, cleared on the next attempt.
    @State private var lastSyncSummaryByConnectionId: [String: String] = [:]
    /// Set when `refreshConnectionStatusFromServer` fails — surfaced as a retryable banner rather
    /// than only a console log, since a failed restore attempt (especially with empty local
    /// state) is exactly the moment a user most needs to know something didn't load.
    @State private var restoreErrorMessage: String?
    /// Set by `handleLinkSuccess` when `exchange-public-token` reports the just-created Item is
    /// for an institution this user already has connected — held here, UNSYNCED and NOT yet added
    /// to `plaidConnection`, until the user picks "Keep Both" or "Use Existing Connection" via the
    /// confirmation dialog this drives. See that dialog's own doc comment for why nothing is
    /// added locally until a choice is made.
    @State private var pendingDuplicateInstitution: PendingDuplicateInstitution?
    /// Informational banner shown after "Use Existing Connection" successfully removes the
    /// duplicate — points the user at the institution's existing card. Cleared by its own
    /// "Dismiss" button, same pattern as `restoreErrorMessage`'s banner.
    @State private var duplicateResolutionMessage: String?

    /// Everything needed to resolve a duplicate-institution prompt once the user picks a side —
    /// captured at the moment `exchange-public-token` reports the duplicate, since by the time the
    /// user responds to the dialog, nothing else in this view still remembers which new connection
    /// (or which existing one) it was about.
    private struct PendingDuplicateInstitution {
        let newConnectionId: String
        let institutionId: String?
        let institutionName: String
        let existingConnectionId: String
        let existingInstitutionName: String
    }

    enum ConnectionAttempt: Equatable {
        case idle
        case requestingLinkToken
        case exchangingToken
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header
                    if isSignedIn {
                        if plaidConnection.oauthReturnMissedActiveSession {
                            CardBackground {
                                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                    inlineMessage(
                                        icon: "exclamationmark.triangle.fill",
                                        text: "We couldn't finish connecting your bank. Please try connecting again below.",
                                        color: Theme.statusWarning
                                    )
                                    PremiumActionButton(title: "Dismiss", systemIconName: "xmark") {
                                        plaidConnection.acknowledgeOAuthReturnWithoutActiveSession()
                                    }
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                        }
                        if let restoreErrorMessage {
                            CardBackground {
                                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                    inlineMessage(
                                        icon: "exclamationmark.triangle.fill",
                                        text: restoreErrorMessage,
                                        color: Theme.statusOver
                                    )
                                    PremiumActionButton(title: "Retry", systemIconName: "arrow.clockwise") {
                                        Task { await refreshConnectionStatusFromServer() }
                                    }
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                        }
                        if let duplicateResolutionMessage {
                            CardBackground {
                                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                    inlineMessage(
                                        icon: "checkmark.circle.fill",
                                        text: duplicateResolutionMessage,
                                        color: Theme.statusGood
                                    )
                                    PremiumActionButton(title: "Dismiss", systemIconName: "xmark") {
                                        self.duplicateResolutionMessage = nil
                                    }
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                        }
                        ForEach(plaidConnection.connections) { connection in
                            connectionCard(connection)
                        }
                        addInstitutionCard
                        howThisWorksCard
                        manageSection
                    } else {
                        signedOutCard
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Connected Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .task { await refreshConnectionStatusFromServer() }
            .sheet(isPresented: $isPresentingImportReview) {
                ImportedTransactionsReviewView()
            }
            .sheet(isPresented: $isPresentingLink) {
                linkSession?.sheet()
            }
            .confirmationDialog(
                "Disconnect this institution?",
                isPresented: $isPresentingDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    if let connectionId = connectionPendingDisconnect {
                        Task { await disconnect(connectionId: connectionId) }
                    }
                }
                Button("Cancel", role: .cancel) { connectionPendingDisconnect = nil }
            } message: {
                Text("SpendSmart's backend will revoke access to this account. No manual transactions or accounts are affected.")
            }
            // Plaid duplicate-Item detection ("Implement duplicate Item detection" onboarding
            // requirement) — shown when exchange-public-token reports the just-created Item is for
            // an institution this user already has connected. The new connection has deliberately
            // NOT been added to `plaidConnection`/synced yet at this point (see `handleLinkSuccess`)
            // — this dialog decides whether it ever will be. Exactly two real choices, matching the
            // required behavior; there is no explicit Cancel button because there is no safe
            // "do nothing" outcome (the new Item already exists server-side) — a swipe-to-dismiss is
            // instead handled by the `isPresented` binding's setter below, which treats it the same
            // as a failed cleanup: never silently pretend the new Item doesn't exist.
            .confirmationDialog(
                "You already have \(pendingDuplicateInstitution?.existingInstitutionName ?? "this institution") connected.",
                isPresented: Binding(
                    get: { pendingDuplicateInstitution != nil },
                    set: { isPresented in
                        guard !isPresented, let pending = pendingDuplicateInstitution else { return }
                        // Reached only on swipe/tap-outside dismissal — neither button branch below
                        // clears `pendingDuplicateInstitution` before this setter runs, so seeing it
                        // still set here means the user left without choosing. Surface the new
                        // connection rather than letting it silently exist only server-side.
                        pendingDuplicateInstitution = nil
                        Task { await refreshConnectionStatusFromServer() }
                        connectionAttempt = .failed(
                            "You have a new \(pending.institutionName) connection waiting — choose Keep Both or Use Existing Connection to finish setting it up."
                        )
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingDuplicateInstitution
            ) { pending in
                Button("Keep Both") {
                    pendingDuplicateInstitution = nil
                    Task { await keepBothDuplicateConnections(pending) }
                }
                Button("Use Existing Connection") {
                    pendingDuplicateInstitution = nil
                    Task { await useExistingConnection(pending) }
                }
            } message: { pending in
                Text("This may be the same login connected again, or a different login at \(pending.existingInstitutionName). Choose Keep Both if these are different logins, or Use Existing Connection if this was accidental.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SpendSmart is manual-first. Connecting a financial institution through Plaid lets you review synced transactions here — nothing is added to your budget automatically.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
            // Shown on this screen before any Link session can be launched — the required
            // pre-consent disclosure for Plaid onboarding ("Provide required notices and obtain
            // consent"). This is informational only; it never replaces or precedes Plaid Link's
            // own hosted consent/disclosure screens, which remain the actual consent mechanism
            // (see LinkKit's `Plaid.createPlaidLinkSession` below).
            Text("Connecting an institution is optional. With your authorization, Plaid securely accesses your account and transaction information on SpendSmart's behalf. [Plaid's Privacy Policy and Terms](https://plaid.com/legal) apply to that connection.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Signed out

    private var signedOutCard: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text("Sign in to manage connected financial accounts.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                PremiumActionButton(title: "Sign In") {
                    // RootView switches to the sign-in flow automatically once sessionState is
                    // .signedOut — dismissing this sheet is the only "navigation" needed.
                    dismiss()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - One connection's card

    @ViewBuilder
    private func connectionCard(_ connection: PlaidConnection) -> some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.accent.opacity(0.18)))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.institutionName)
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text("via Plaid")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Spacer()

                    statusPill(for: connection)
                }

                Divider().overlay(Theme.cardStroke)

                HStack {
                    Text("Last Synced")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(lastSyncedText(for: connection))
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack {
                    Text("Mode")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Read-only")
                    }
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.statusGood)
                }

                if let balances = balancesByConnectionId[connection.id], !balances.isEmpty {
                    balancesSection(balances)
                }

                if !authService.isEmailVerified {
                    inlineMessage(
                        icon: "envelope.badge.fill",
                        text: "Verify your email to sync a financial account. Check Account in Settings.",
                        color: Theme.statusWarning
                    )
                } else if connection.requiresReauth {
                    inlineMessage(
                        icon: "exclamationmark.triangle.fill",
                        text: "This connection needs to be reconnected before it can sync again.",
                        color: Theme.statusOver
                    )
                    PremiumActionButton(
                        title: activeConnectionId == connection.id ? "Reconnecting…" : "Reconnect",
                        systemIconName: "arrow.triangle.2.circlepath"
                    ) {
                        Task { await reconnect(connection) }
                    }
                    .disabled(activeConnectionId != nil)
                    .opacity(activeConnectionId != nil && activeConnectionId != connection.id ? 0.6 : 1)
                    .accessibilityHint("Opens Plaid to restore or update this connection.")
                } else {
                    // Pending disconnect/expiration ("Follow Link UI best practices" onboarding
                    // item) — mutually exclusive by construction via PlaidConnectionWarning.evaluate
                    // (disconnect always wins when both are set), so at most one of these two shows
                    // at a time. Visually consistent with the requiresReauth/newAccountsAvailable
                    // states above/below: one inlineMessage + one PremiumActionButton reusing the
                    // same `reconnect(_:)` action.
                    switch PlaidConnectionWarning.evaluate(
                        pendingDisconnectAt: connection.pendingDisconnectAt,
                        pendingExpirationAt: connection.pendingExpirationAt
                    ) {
                    case .pendingDisconnect(let disconnectDate):
                        inlineMessage(
                            icon: "exclamationmark.octagon.fill",
                            text: "This institution is scheduled to disconnect on \(disconnectDate.formatted(date: .abbreviated, time: .omitted)). Reconnect now to avoid losing access.",
                            color: Theme.statusOver
                        )
                        PremiumActionButton(
                            title: activeConnectionId == connection.id ? "Reconnecting…" : "Reconnect",
                            systemIconName: "arrow.triangle.2.circlepath"
                        ) {
                            Task { await reconnect(connection) }
                        }
                        .disabled(activeConnectionId != nil)
                        .opacity(activeConnectionId != nil && activeConnectionId != connection.id ? 0.6 : 1)
                        .accessibilityHint("Opens Plaid to restore or update this connection.")
                    case .pendingExpiration(let expirationDate):
                        inlineMessage(
                            icon: "exclamationmark.triangle.fill",
                            text: "This connection's authorization is approaching expiration on \(expirationDate.formatted(date: .abbreviated, time: .omitted)). Reconnect to avoid an interruption.",
                            color: Theme.statusWarning
                        )
                        PremiumActionButton(
                            title: activeConnectionId == connection.id ? "Reconnecting…" : "Reconnect",
                            systemIconName: "arrow.triangle.2.circlepath"
                        ) {
                            Task { await reconnect(connection) }
                        }
                        .disabled(activeConnectionId != nil)
                        .opacity(activeConnectionId != nil && activeConnectionId != connection.id ? 0.6 : 1)
                        .accessibilityHint("Opens Plaid to restore or update this connection.")
                    case .none:
                        EmptyView()
                    }

                    if connection.newAccountsAvailable {
                        inlineMessage(
                            icon: "plus.circle.fill",
                            text: "New accounts are available at this institution — reconnect to add them.",
                            color: Theme.statusWarning
                        )
                        // Routes through the SAME update-mode Link flow the requiresReauth
                        // branch's "Reconnect" button uses (`reconnect(_:)` →
                        // `createUpdateLinkToken` → Plaid Link, opened with
                        // `account_selection_enabled: true` server-side) — previously this
                        // message had no action of its own, so a user could only discover new
                        // accounts via "Refresh Accounts" below, which never goes through Link
                        // update mode or Plaid's own account-selection UI at all.
                        PremiumActionButton(
                            title: activeConnectionId == connection.id ? "Reconnecting…" : "Add New Accounts",
                            systemIconName: "plus.circle"
                        ) {
                            Task { await reconnect(connection) }
                        }
                        .disabled(activeConnectionId != nil)
                        .opacity(activeConnectionId != nil && activeConnectionId != connection.id ? 0.6 : 1)
                    }
                    PremiumActionButton(
                        title: activeConnectionId == connection.id ? "Refreshing…" : "Manual Refresh",
                        systemIconName: "arrow.clockwise"
                    ) {
                        Task { await refresh(connection) }
                    }
                    .disabled(activeConnectionId != nil)
                    .opacity(activeConnectionId != nil && activeConnectionId != connection.id ? 0.6 : 1)

                    PremiumActionButton(
                        title: activeConnectionId == connection.id ? "Refreshing…" : "Refresh Accounts",
                        systemIconName: "arrow.triangle.2.circlepath.circle"
                    ) {
                        Task { await refreshAccounts(connection) }
                    }
                    .disabled(activeConnectionId != nil)
                    .opacity(activeConnectionId != nil && activeConnectionId != connection.id ? 0.6 : 1)
                }

                if case .failed(let message) = connectionAttempt, activeConnectionId == connection.id {
                    inlineMessage(icon: "exclamationmark.circle.fill", text: message, color: Theme.statusOver)
                } else if let summary = lastSyncSummaryByConnectionId[connection.id] {
                    inlineMessage(icon: "checkmark.circle.fill", text: summary, color: Theme.statusGood)
                }

                Button {
                    isPresentingImportReview = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Review Imported Transactions")
                            .font(Theme.captionFont)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)

                Divider().overlay(Theme.cardStroke)

                Button {
                    connectionPendingDisconnect = connection.id
                    isPresentingDisconnectConfirmation = true
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.statusOver)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Theme.statusOver.opacity(0.12)))
                        Text("Disconnect \(connection.institutionName)")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.statusOver)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Removes this institution and its imported Plaid data from SpendSmart.")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private func balancesSection(_ balances: [PlaidAccountBalance]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Accounts")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            ForEach(balances, id: \.accountId) { balance in
                accountBalanceRow(balance)
            }
        }
    }

    /// One account's card row — never just a bare currency amount next to a name. Per the
    /// account-type-aware balance requirement, this always shows what KIND of account it is
    /// (`accountTypeLabel`) and labels every amount for what it actually means (`Balance Owed`
    /// vs. `Current Balance`, never one generic number) — see `PlaidBalanceFormatter`, the single
    /// place that decides which labeled rows a given account gets, so this view never has to
    /// reason about credit-vs-depository semantics itself.
    @ViewBuilder
    private func accountBalanceRow(_ balance: PlaidAccountBalance) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(balanceDisplayName(balance))
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textSecondary)
                    Text(accountTypeLabel(balance))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }

            let rows = PlaidBalanceFormatter.rows(for: balance)
            if rows.isEmpty {
                Text("Balance unavailable")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.label)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(row.amount, format: .currency(code: balance.isoCurrencyCode ?? balance.unofficialCurrencyCode ?? "USD"))
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func balanceDisplayName(_ balance: PlaidAccountBalance) -> String {
        let base = balance.name ?? balance.officialName ?? "Account"
        guard let mask = balance.mask, !mask.isEmpty else { return base }
        return "\(base) \u{00B7}\u{00B7}\u{00B7}\(mask)"
    }

    /// A short, human label for the account's Plaid `type`/`subtype` — e.g. "Credit Card",
    /// "Checking", "Savings" — falling back to a capitalized raw `subtype`/`type` for anything
    /// this app doesn't have a specific label for, and finally "Account" if Plaid supplied
    /// neither. Never crashes or shows a raw enum-looking string for an unrecognized Plaid type.
    private func accountTypeLabel(_ balance: PlaidAccountBalance) -> String {
        switch PlaidAccountKind.classify(type: balance.type) {
        case .credit:
            return "Credit Card"
        case .depository:
            if let subtype = balance.subtype?.lowercased() {
                if subtype == "checking" { return "Checking" }
                if subtype == "savings" { return "Savings" }
            }
            return "Bank Account"
        case .loan:
            return "Loan"
        case .investment:
            return "Investment"
        case .other:
            if let subtype = balance.subtype, !subtype.isEmpty {
                return subtype.capitalized
            }
            if let type = balance.type, !type.isEmpty {
                return type.capitalized
            }
            return "Account"
        }
    }

    @ViewBuilder
    private func statusPill(for connection: PlaidConnection) -> some View {
        let (color, text): (Color, String) = {
            if connection.requiresReauth { return (Theme.statusOver, "Needs Reconnect") }
            return (Theme.statusGood, "Connected")
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(Theme.captionFont)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func lastSyncedText(for connection: PlaidConnection) -> String {
        guard let lastSyncedAt = connection.lastSyncedAt else { return "Never" }
        return lastSyncedAt.formatted(date: .abbreviated, time: .shortened)
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
    }

    // MARK: - Add another institution

    private var addInstitutionCard: some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.md) {
                if !authService.isEmailVerified {
                    inlineMessage(
                        icon: "envelope.badge.fill",
                        text: "Verify your email to connect a financial account. Check Account in Settings.",
                        color: Theme.statusWarning
                    )
                } else {
                    PremiumActionButton(
                        title: connectionButtonTitle,
                        systemIconName: "link"
                    ) {
                        Task { await connect() }
                    }
                    .disabled(connectionAttempt == .requestingLinkToken || connectionAttempt == .exchangingToken)
                    .opacity(connectionAttempt == .requestingLinkToken || connectionAttempt == .exchangingToken ? 0.6 : 1)
                }

                if case .failed(let message) = connectionAttempt, activeConnectionId == nil {
                    inlineMessage(icon: "exclamationmark.circle.fill", text: message, color: Theme.statusOver)
                } else if connectionAttempt == .exchangingToken {
                    inlineMessage(
                        icon: "arrow.triangle.2.circlepath",
                        text: "Finishing connection and syncing transactions…",
                        color: Theme.statusGood
                    )
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var connectionButtonTitle: String {
        switch connectionAttempt {
        case .requestingLinkToken: return "Connecting…"
        case .exchangingToken: return "Finishing Up…"
        default: return plaidConnection.connections.isEmpty ? "Connect a Financial Institution" : "Connect Another Institution"
        }
    }

    // MARK: - How this works

    private var howThisWorksCard: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                noteRow(icon: "key.slash", text: "Your bank username and password are never entered into or stored by SpendSmart — Plaid Link's own hosted UI collects them.")
                noteRow(icon: "lock.shield", text: "The connection goes through Plaid via a secure backend. This app never talks to Plaid directly and never holds a Plaid access token.")
                noteRow(icon: "checkmark.circle", text: "Every imported transaction stays read-only and excluded from your totals until you explicitly add or match it.")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private func noteRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accent.opacity(0.16)))
            Text(text)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Manage

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Manage")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    disabledRow(
                        icon: "trash",
                        title: "Delete Imported Transaction Data",
                        subtitle: "Coming soon"
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func disabledRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.textTertiary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textTertiary)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .opacity(0.6)
    }

    // MARK: - Actions

    /// Step 1: ask the backend for a `link_token` for a NEW connection, then open Plaid Link's own
    /// hosted UI with it. This app never constructs that UI itself and never sees a bank
    /// credential — Plaid Link renders its own login screen (the user picks their OWN institution
    /// there; nothing here assumes which one) and hands back only a short-lived `public_token`
    /// plus institution metadata on success.
    private func connect() async {
        connectionAttempt = .requestingLinkToken
        activeConnectionId = nil
        linkReconnectingConnectionId = nil
        #if DEBUG
        print("[PlaidMulti] add institution started")
        #endif
        PlaidLinkLogging.logLifecycle("link_token_creation_started", isReconnect: false)
        do {
            let linkToken = try await backend.createLinkToken()
            #if DEBUG
            print("[PlaidMulti] Link token created")
            #endif
            presentLink(withToken: linkToken)
        } catch {
            PlaidLinkLogging.logLifecycle("link_token_creation_failed", isReconnect: false)
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    /// Reconnect (Link UPDATE MODE) for an existing institution — either because it needs
    /// re-authentication (`requiresReauth`'s "Reconnect" button) or because the institution has
    /// accounts this Item doesn't cover yet (`newAccountsAvailable`'s "Add New Accounts" button,
    /// which opens the SAME flow so Plaid's own account-selection UI, enabled server-side via
    /// `create-link-token`'s `account_selection_enabled`, is available). Does NOT delete or
    /// recreate the connection; the existing `plaid_items` row, its access_token, and every
    /// already-synced transaction/account are untouched. Only a successful Link session changes
    /// anything server-side.
    private func reconnect(_ connection: PlaidConnection) async {
        activeConnectionId = connection.id
        connectionAttempt = .requestingLinkToken
        linkReconnectingConnectionId = connection.id
        PlaidLinkLogging.logLifecycle("link_token_creation_started", isReconnect: true, institutionName: connection.institutionName)
        do {
            let linkToken = try await backend.createUpdateLinkToken(connectionId: connection.id)
            #if DEBUG
            print("[SpendSmartBuild] Link Update Mode started")
            #endif
            presentLink(withToken: linkToken)
        } catch {
            PlaidLinkLogging.logLifecycle("link_token_creation_failed", isReconnect: true, institutionName: connection.institutionName)
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    private func presentLink(withToken linkToken: String) {
        let configuration = LinkTokenConfiguration(
            token: linkToken,
            onSuccess: { success in
                Task {
                    await handleLinkSuccess(
                        publicToken: success.publicToken,
                        institutionId: success.metadata.institution.id,
                        institutionName: success.metadata.institution.name
                    )
                }
            },
            onExit: { exit in
                isPresentingLink = false
                plaidConnection.hasActiveLinkFlow = false
                let isReconnect = linkReconnectingConnectionId != nil
                if let error = exit.error {
                    // A real Link error, distinct from the user simply closing Link below.
                    PlaidLinkLogging.logLifecycle(
                        "link_exit_error",
                        isReconnect: isReconnect,
                        institutionName: exit.metadata.institution?.name,
                        errorCode: error.errorCode.description
                    )
                    connectionAttempt = .failed(error.displayMessage ?? error.errorMessage)
                } else {
                    // The user closed Link without finishing — not a real failure, just back to
                    // idle. Logged for both new-connection and reconnect sessions (previously this
                    // was DEBUG-only and only logged for reconnect).
                    PlaidLinkLogging.logLifecycle(
                        "link_exit_cancelled",
                        isReconnect: isReconnect,
                        institutionName: exit.metadata.institution?.name
                    )
                    connectionAttempt = .idle
                    activeConnectionId = nil
                }
            },
            onEvent: { event in
                PlaidLinkLogging.logLinkEvent(
                    eventName: event.eventName.description,
                    isReconnect: linkReconnectingConnectionId != nil,
                    institutionID: event.metadata.institutionID,
                    institutionName: event.metadata.institutionName,
                    errorCode: event.metadata.errorCode?.description,
                    viewName: event.metadata.viewName?.description,
                    linkSessionID: event.metadata.linkSessionID
                )
            },
            onLoad: {
                PlaidLinkLogging.logLifecycle("link_loaded", isReconnect: linkReconnectingConnectionId != nil)
            }
        )

        do {
            linkSession = try Plaid.createPlaidLinkSession(configuration: configuration)
            isPresentingLink = true
            // Marks a Link flow as genuinely in progress — see `PlaidConnectionManager
            // .hasActiveLinkFlow`'s doc comment for why this exists: it's the only signal
            // available if a Plaid OAuth return URL arrives while no flow was ever started.
            plaidConnection.hasActiveLinkFlow = true
        } catch {
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    /// Step 2: Plaid Link succeeded. For a NEW connection, exchanges `publicToken` for an access
    /// token (stored server-side only, never here) and runs the first sync. For a RECONNECT
    /// (`linkReconnectingConnectionId` set), hands off to `completeReconnect` — see its own doc
    /// comment for the required post-update-mode sequence.
    private func handleLinkSuccess(publicToken: String, institutionId: String, institutionName: String) async {
        isPresentingLink = false
        plaidConnection.hasActiveLinkFlow = false
        connectionAttempt = .exchangingToken
        let isReconnect = linkReconnectingConnectionId != nil
        // "Link success" — LinkKit's own onSuccess firing, distinct from the SEPARATE
        // public_token_exchange_success/failure logged below once this app's own backend call
        // (exchange-public-token, or completeReconnect's refreshAccounts for a reconnect) resolves.
        PlaidLinkLogging.logLifecycle("link_success", isReconnect: isReconnect, institutionName: institutionName)

        if let reconnectingId = linkReconnectingConnectionId {
            linkReconnectingConnectionId = nil
            await completeReconnect(connectionId: reconnectingId)
            activeConnectionId = nil
            return
        }

        #if DEBUG
        print("[PlaidMulti] Link completed")
        #endif

        defer { activeConnectionId = nil }

        // Split from the rest of this function's do/catch specifically so a failure here is
        // logged/attributed as an exchange failure, never confused with a later balance/sync
        // failure (which reuses the SAME publicToken-exchange result and has its own do/catch
        // below) — see PlaidLinkLogging's own doc comment for why event names stay this precise.
        let result: PlaidExchangeResult
        do {
            result = try await backend.exchangePublicToken(
                publicToken,
                institutionId: institutionId,
                institutionName: institutionName
            )
            PlaidLinkLogging.logLifecycle("public_token_exchange_success", isReconnect: false, institutionName: result.institutionName)
        } catch {
            PlaidLinkLogging.logLifecycle("public_token_exchange_failure", isReconnect: false)
            connectionAttempt = .failed(error.localizedDescription)
            return
        }

        #if DEBUG
        print("[PlaidMulti] public token exchange completed")
        // exchange-public-token already runs the shared account-discovery helper server-side
        // and returns what it found — no separate refresh-plaid-accounts call is needed here
        // solely to populate this count.
        print("[PlaidMulti] account refresh completed count=\(result.accounts.count)")
        #endif

        // DUPLICATE-ITEM DETECTION: inspect BEFORE treating this as a normal completed
        // connection — deliberately do NOT call addOrUpdate/refreshBalances/performSync yet.
        // The new Item already exists server-side (exchange-public-token already succeeded),
        // but it stays entirely unsynced and invisible to this device's local state until the
        // user picks a side in the confirmation dialog this drives.
        if result.duplicateInstitution, let existingConnectionId = result.existingConnectionId {
            #if DEBUG
            print("[PlaidMulti] duplicate institution detected, awaiting user choice")
            #endif
            PlaidLinkLogging.logLifecycle("duplicate_institution_detected", isReconnect: false, institutionName: result.institutionName)
            pendingDuplicateInstitution = PendingDuplicateInstitution(
                newConnectionId: result.connectionId,
                institutionId: result.institutionId,
                institutionName: result.institutionName,
                existingConnectionId: existingConnectionId,
                existingInstitutionName: result.existingInstitutionName ?? result.institutionName
            )
            connectionAttempt = .idle
            return
        }

        plaidConnection.addOrUpdate(
            connectionId: result.connectionId,
            institutionId: result.institutionId,
            institutionName: result.institutionName
        )
        activeConnectionId = result.connectionId
        lastSyncSummaryByConnectionId[result.connectionId] = nil

        // Balance/transaction/connection-list refresh failures below are surfaced through the
        // existing retryable error UI — the newly created Item itself is never deleted or
        // disconnected on any of these failures; it stays exactly as exchange-public-token
        // left it, and the user can retry via Manual Refresh/Refresh Accounts afterward.
        await refreshBalances(connectionId: result.connectionId)
        #if DEBUG
        print("[PlaidMulti] balance refresh completed count=\(balancesByConnectionId[result.connectionId]?.count ?? 0)")
        #endif
        do {
            try await performSync(connectionId: result.connectionId)
            #if DEBUG
            print("[PlaidMulti] transaction sync completed")
            #endif
            await refreshConnectionStatusFromServer()
            #if DEBUG
            print("[PlaidMulti] connection list refreshed count=\(plaidConnection.connections.count)")
            #endif
            PlaidLinkLogging.logLifecycle("connection_completed", isReconnect: false, institutionName: result.institutionName)
            connectionAttempt = .idle
        } catch {
            PlaidLinkLogging.logLifecycle(
                "transaction_sync_failed",
                isReconnect: false,
                institutionName: result.institutionName,
                errorCode: Self.safeErrorCategory(error)
            )
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    /// "Keep Both" — the user confirmed this really is a separate, legitimate login at an
    /// institution they already have connected (Plaid's own duplicate-Item guidance is explicit
    /// that this must remain possible, never blocked). Proceeds exactly as a normal new-connection
    /// completion would have, had `exchange-public-token` not flagged a duplicate — never touches,
    /// merges into, or otherwise affects the EXISTING connection in any way.
    private func keepBothDuplicateConnections(_ pending: PendingDuplicateInstitution) async {
        PlaidLinkLogging.logLifecycle("duplicate_keep_both_selected", isReconnect: false, institutionName: pending.institutionName)
        activeConnectionId = pending.newConnectionId
        defer { activeConnectionId = nil }
        plaidConnection.addOrUpdate(
            connectionId: pending.newConnectionId,
            institutionId: pending.institutionId,
            institutionName: pending.institutionName
        )
        lastSyncSummaryByConnectionId[pending.newConnectionId] = nil
        await refreshBalances(connectionId: pending.newConnectionId)
        do {
            try await performSync(connectionId: pending.newConnectionId)
            PlaidLinkLogging.logLifecycle("connection_completed", isReconnect: false, institutionName: pending.institutionName)
            connectionAttempt = .idle
        } catch {
            connectionAttempt = .failed(error.localizedDescription)
        }
        await refreshConnectionStatusFromServer()
    }

    /// "Use Existing Connection" — the user confirmed this was an accidental duplicate. Removes
    /// the just-created Item server-side via the same `disconnectAccount` path a normal disconnect
    /// uses. Nothing was ever added to `plaidConnection`/SwiftData for this new connection (it was
    /// deliberately held back pending this choice in `handleLinkSuccess`), so there is no local
    /// data to separately clean up — removing only the newly created Item, and leaving the
    /// existing connection completely untouched, falls out of that by construction rather than
    /// needing its own explicit "don't touch the other one" step.
    ///
    /// If the server-side removal itself fails, this must NEVER pretend the duplicate doesn't
    /// exist: it pulls the (now-orphaned) Item into the visible connection list via
    /// `refreshConnectionStatusFromServer` and surfaces a retryable, user-visible error, so the
    /// user can see it and disconnect it manually rather than it silently lingering, unseen,
    /// server-side.
    private func useExistingConnection(_ pending: PendingDuplicateInstitution) async {
        PlaidLinkLogging.logLifecycle("duplicate_use_existing_selected", isReconnect: false, institutionName: pending.institutionName)
        activeConnectionId = pending.newConnectionId
        defer { activeConnectionId = nil }
        do {
            try await backend.disconnectAccount(connectionId: pending.newConnectionId)
            PlaidLinkLogging.logLifecycle("duplicate_cleanup_success", isReconnect: false, institutionName: pending.institutionName)
            connectionAttempt = .idle
            duplicateResolutionMessage =
                "Removed the duplicate connection. Your existing \(pending.existingInstitutionName) connection is below — use Reconnect there if it needs updating."
        } catch {
            PlaidLinkLogging.logLifecycle("duplicate_cleanup_failure", isReconnect: false, institutionName: pending.institutionName)
            await refreshConnectionStatusFromServer()
            connectionAttempt = .failed(
                "Couldn't remove the duplicate \(pending.institutionName) connection automatically: \(error.localizedDescription). It now appears in your connections list below — disconnect it manually."
            )
        }
    }

    /// The required sequence after a Link UPDATE MODE session succeeds — deliberately NOT just
    /// "re-sync transactions," which is all an earlier version of this function did (the exact
    /// gap that meant reconnecting after `NEW_ACCOUNTS_AVAILABLE` never actually discovered the
    /// new accounts it promised to):
    ///
    /// 1. No second `exchangePublicToken` call — update mode already refreshed the Item's
    ///    access_token server-side; nothing here re-exchanges a public token.
    /// 2. `refreshAccounts` — rediscovers accounts for this Item (`/accounts/get`, via the same
    ///    shared server-side helper a brand-new connection uses) and, ONLY on success, clears
    ///    `requires_reauth`/`new_accounts_available` server-side (see
    ///    `refresh-plaid-accounts/index.ts` for why tying those clears to this specific call's
    ///    success is the correct, self-verifying design). If this step fails, everything stops
    ///    HERE: no balance refresh, no transaction sync, no local flag changes — the existing
    ///    Item is left exactly as it was, `new_accounts_available` stays true server-side, and
    ///    the user sees an actionable error rather than an incorrect "all done."
    /// 3. `syncBalances` — refresh balances for the (possibly now larger) account list.
    /// 4. `performSync` (transactions) — same connectionId as always; reconnecting never creates
    ///    a new Item/connection, so this still targets the SAME `plaid_items` row it always did.
    /// 5. `refreshConnectionStatusFromServer` — re-pulls `list-connections`, which is how this
    ///    device actually learns the server cleared `requires_reauth`/`new_accounts_available` in
    ///    step 2 (this function never optimistically clears either flag locally itself). This same
    ///    pull also reconciles `pendingExpirationAt`/`pendingDisconnectAt` to whatever the server
    ///    currently has — refresh-plaid-accounts does NOT clear either of those (only a
    ///    `LOGIN_REPAIRED` webhook does), so a reconnect can legitimately still show one of them
    ///    afterward; this step reflects that truthfully rather than optimistically hiding it.
    private func completeReconnect(connectionId: String) async {
        lastSyncSummaryByConnectionId[connectionId] = nil

        #if DEBUG
        print("[SpendSmartBuild] account refresh started")
        #endif
        do {
            _ = try await backend.refreshAccounts(connectionId: connectionId)
        } catch {
            PlaidLinkLogging.logLifecycle("account_refresh_failed", isReconnect: true, errorCode: Self.safeErrorCategory(error))
            connectionAttempt = .failed(
                "Reconnected, but SpendSmart couldn't refresh this institution's accounts: \(error.localizedDescription). Your existing connection is unchanged — try Reconnect again."
            )
            return
        }

        do {
            await refreshBalances(connectionId: connectionId)
            try await performSync(connectionId: connectionId)
            await refreshConnectionStatusFromServer()
            connectionAttempt = .idle
            #if DEBUG
            print("[SpendSmartBuild] Link Update Mode succeeded")
            #endif
            PlaidLinkLogging.logLifecycle("connection_completed", isReconnect: true)
        } catch {
            PlaidLinkLogging.logLifecycle("transaction_sync_failed", isReconnect: true, errorCode: Self.safeErrorCategory(error))
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    private func refresh(_ connection: PlaidConnection) async {
        activeConnectionId = connection.id
        lastSyncSummaryByConnectionId[connection.id] = nil
        defer { activeConnectionId = nil }
        do {
            try await performSync(connectionId: connection.id)
            await refreshBalances(connectionId: connection.id)
        } catch PlaidBackendError.requiresReauth {
            plaidConnection.markRequiresReauth(connectionId: connection.id)
        } catch {
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    /// Dedicated account-discovery action for an already-linked institution — calls the same
    /// server-side `refresh-plaid-accounts` path Link UPDATE MODE uses, but without forcing the
    /// user through a Link session. Existing behavior only: never disconnects, recreates,
    /// exchanges, or resets anything; any failure leaves the Item exactly as it was and surfaces
    /// through the existing retryable `connectionAttempt = .failed(...)` UI.
    private func refreshAccounts(_ connection: PlaidConnection) async {
        activeConnectionId = connection.id
        defer { activeConnectionId = nil }
        #if DEBUG
        print("[SpendSmartBuild] account refresh started")
        #endif
        do {
            _ = try await backend.refreshAccounts(connectionId: connection.id)
            await refreshBalances(connectionId: connection.id)
        } catch PlaidBackendError.requiresReauth {
            plaidConnection.markRequiresReauth(connectionId: connection.id)
        } catch {
            PlaidLinkLogging.logLifecycle("account_refresh_failed", errorCode: Self.safeErrorCategory(error))
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    private func refreshBalances(connectionId: String) async {
        do {
            let balances = try await backend.syncBalances(connectionId: connectionId)
            balancesByConnectionId[connectionId] = balances
            // Caches the freshly retrieved balance locally so the Dashboard can display it without
            // ever calling Plaid itself — only reached on success, so a failed refresh below never
            // touches (and never wipes) whatever was cached from the last successful call.
            plaidConnection.updateCachedBalances(connectionId: connectionId, balances: balances)
        } catch PlaidBackendError.requiresReauth {
            plaidConnection.markRequiresReauth(connectionId: connectionId)
        } catch {
            // Balance refresh failing is never fatal to the rest of this screen — transactions
            // sync is the primary flow; balances are a display-only addition. Logged via the same
            // closed-allowlist safeErrorCategory mapping every other Plaid failure log in this
            // file uses — never the raw error.localizedDescription, which isn't guaranteed free
            // of institution/response-specific detail.
            PlaidLinkLogging.logLifecycle("balance_refresh_failed", errorCode: Self.safeErrorCategory(error))
        }
    }

    /// Pulls the authoritative, server-side status for every linked institution (including any
    /// flag a Plaid webhook set while this device wasn't looking) and reconciles it into local
    /// state via `restoreFromServer`. Runs once per screen appearance — cheap, and this is the
    /// ONLY path that can recover a connection this specific device never locally recorded (no
    /// legacy or v2 UserDefaults state for it), which is exactly why this must run even when
    /// `plaidConnection.connections` is currently empty — an empty local cache is precisely the
    /// case restoration exists for, not a reason to skip it.
    private func refreshConnectionStatusFromServer() async {
        guard isSignedIn else { return }
        #if DEBUG
        print("[PlaidRestore] list-connections started")
        #endif
        do {
            let statuses = try await backend.listConnections()
            #if DEBUG
            print("[PlaidRestore] list-connections succeeded count=\(statuses.count)")
            #endif
            plaidConnection.restoreFromServer(statuses)
            restoreErrorMessage = nil
            #if DEBUG
            print("[PlaidRestore] manager updated count=\(plaidConnection.connections.count)")
            #endif
        } catch {
            // Best-effort — existing local state is left exactly as it was; only the banner and
            // the log reflect the failure. Logged via the Release-safe PlaidLinkLogging path (not
            // just the pre-existing DEBUG print below) so a list-connections failure is visible in
            // Release/TestFlight builds too.
            PlaidLinkLogging.logLifecycle("list_connections_failed", errorCode: Self.safeErrorCategory(error))
            #if DEBUG
            print("[PlaidRestore] list-connections failed category=\(Self.safeErrorCategory(error))")
            #endif
            restoreErrorMessage = "SpendSmart couldn't check for connected accounts. Your existing connections, if any, are unchanged."
        }
    }

    /// Maps any error from a `list-connections` call to a coarse, non-sensitive category for
    /// DEBUG logging — never the error's own message/payload, which could echo back
    /// request/response details this build must not print.
    private static func safeErrorCategory(_ error: Error) -> String {
        if let backendError = error as? PlaidBackendError {
            switch backendError {
            case .notConfigured: return "not_configured"
            case .invalidResponse: return "decoding"
            case .unauthorized: return "unauthorized"
            case .requiresReauth: return "requires_reauth"
            case .server: return "server"
            }
        }
        return "network"
    }

    /// Fetches from the backend, persists to SwiftData, and only THEN marks the connection
    /// synced and shows a summary — a decode failure or a `modelContext.save()` failure both
    /// throw before any of that happens, so this never claims success for data that didn't
    /// actually make it onto the device. See `PlaidTransactionImportService.applySync` for the
    /// insert/update/remove/dedup/pending-merge logic itself.
    ///
    /// ATOMICITY NOTE: `sync-transactions` persists its new Plaid cursor server-side as soon as
    /// its own pagination loop succeeds — BEFORE this function's `applySync` call below runs. If
    /// `applySync` throws (a `DecodingError`, or `context.save()` failing — e.g. disk full, or the
    /// app killed mid-save), that diff is effectively lost: Plaid's cursor-based sync never
    /// redelivers an already-consumed "added" transaction. Nothing financial is at risk (imported
    /// transactions are read-only and uncounted until explicitly approved), but some imported
    /// transactions could be silently missing until Plaid produces new activity. Closing this gap
    /// for real means sync-transactions holding the cursor until the app acks persistence — a
    /// backend protocol change beyond this pass's scope.
    private func performSync(connectionId: String) async throws {
        #if DEBUG
        print("[SpendSmartBuild] transaction sync started")
        #endif
        let result = try await backend.syncTransactions(connectionId: connectionId)
        let outcome = try PlaidTransactionImportService.applySync(result, context: modelContext)
        plaidConnection.markSynced(connectionId: connectionId)
        lastSyncSummaryByConnectionId[connectionId] = Self.summaryMessage(for: outcome)
        #if DEBUG
        print("[SpendSmartBuild] transaction sync completed: inserted \(outcome.insertedCount), updated \(outcome.updatedCount), removed \(outcome.removedCount), mergedFromPending \(outcome.mergedFromPendingCount)")
        #endif
    }

    private static func summaryMessage(for outcome: PlaidTransactionImportService.SyncOutcome) -> String {
        var parts: [String] = []
        if outcome.insertedCount > 0 {
            parts.append("Imported \(outcome.insertedCount) new transaction\(outcome.insertedCount == 1 ? "" : "s")")
        }
        if outcome.mergedFromPendingCount > 0 {
            parts.append("\(outcome.mergedFromPendingCount) transaction\(outcome.mergedFromPendingCount == 1 ? "" : "s") posted")
        }
        if outcome.updatedCount > 0 {
            parts.append("Updated \(outcome.updatedCount) transaction\(outcome.updatedCount == 1 ? "" : "s")")
        }
        if outcome.removedCount > 0 {
            parts.append("Removed \(outcome.removedCount) transaction\(outcome.removedCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No new transactions" : parts.joined(separator: ". ")
    }

    /// Disconnects one institution and removes only ITS OWN Plaid-imported transactions from
    /// this device — see `PlaidLocalDataCleanupService`'s doc comment for why locally-cached
    /// Plaid data shouldn't outlive the connection it came from (data-retention compliance, not
    /// just a UI cleanup).
    ///
    /// Account-ID resolution happens BEFORE the server-side disconnect (once the Item is removed
    /// server-side, `refreshAccounts` would 404 for it — this is the last moment that lookup is
    /// still possible), falling back to whatever this screen already has cached in
    /// `balancesByConnectionId` if that live call fails. The actual LOCAL DELETE, however, only
    /// runs AFTER `disconnectAccount` succeeds — never before, and never if it fails — so a
    /// failed/interrupted disconnect can never leave this device having already discarded data
    /// for a connection that's still live server-side.
    private func disconnect(connectionId: String) async {
        activeConnectionId = connectionId
        defer { activeConnectionId = nil }

        let accountIds = await resolvePlaidAccountIds(connectionId: connectionId)

        do {
            try await backend.disconnectAccount(connectionId: connectionId)
            PlaidLocalDataCleanupService.deletePlaidTransactions(matchingAccountIds: accountIds, context: modelContext)
            plaidConnection.remove(connectionId: connectionId)
            balancesByConnectionId.removeValue(forKey: connectionId)
            lastSyncSummaryByConnectionId.removeValue(forKey: connectionId)
            connectionAttempt = .idle
        } catch {
            PlaidLinkLogging.logLifecycle("disconnect_failed", errorCode: Self.safeErrorCategory(error))
            connectionAttempt = .failed(error.localizedDescription)
        }
        connectionPendingDisconnect = nil
    }

    /// The set of Plaid `account_id`s belonging to `connectionId`, used to scope local
    /// transaction cleanup to exactly this institution and no other. Prefers a live
    /// `refreshAccounts` call (authoritative, always current); falls back to whatever balances
    /// this screen already has cached for the connection if that call fails (e.g. offline) —
    /// never fails the disconnect itself just because this resolution step couldn't complete.
    /// An empty result is safe: `PlaidLocalDataCleanupService.deletePlaidTransactions` treats an
    /// empty set as "delete nothing," never as "delete everything."
    private func resolvePlaidAccountIds(connectionId: String) async -> Set<String> {
        if let summaries = try? await backend.refreshAccounts(connectionId: connectionId) {
            return Set(summaries.map(\.accountId))
        }
        let cachedIds = balancesByConnectionId[connectionId]?.map(\.accountId) ?? []
        return Set(cachedIds)
    }
}

#Preview {
    ConnectedAccountsView()
        .environment(PlaidConnectionManager())
        .environment(PrivacyModeManager())
        .environment(AuthenticationService.shared)
}
