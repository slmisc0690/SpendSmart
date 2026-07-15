import SwiftUI
import SwiftData
import LinkKit

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
    #if DEBUG
    @State private var isResettingCursorConnectionId: String?
    #endif

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
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SpendSmart is manual-first. Connecting a financial institution through Plaid lets you review synced transactions here — nothing is added to your budget automatically.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
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
                } else {
                    if connection.newAccountsAvailable {
                        inlineMessage(
                            icon: "plus.circle.fill",
                            text: "New accounts are available at this institution — reconnect to add them.",
                            color: Theme.statusWarning
                        )
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

                #if DEBUG
                Divider().overlay(Theme.cardStroke)
                Button {
                    Task { await resetCursorAndReimport(connection) }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Theme.accent.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isResettingCursorConnectionId == connection.id ? "Resetting…" : "Reset Cursor & Reimport (Debug)")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.accent)
                            Text("Sandbox-only recovery: re-pulls full history from scratch")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(isResettingCursorConnectionId != nil)
                .opacity(isResettingCursorConnectionId != nil && isResettingCursorConnectionId != connection.id ? 0.6 : 1)
                #endif
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
        do {
            let linkToken = try await backend.createLinkToken()
            #if DEBUG
            print("[PlaidMulti] Link token created")
            #endif
            presentLink(withToken: linkToken)
        } catch {
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    /// Reconnect (Link UPDATE MODE) for an existing institution that needs re-authentication —
    /// does NOT delete or recreate the connection; the existing `plaid_items` row, its
    /// access_token, and every already-synced transaction/account are untouched. Only a
    /// successful re-auth through Link changes anything server-side.
    private func reconnect(_ connection: PlaidConnection) async {
        activeConnectionId = connection.id
        connectionAttempt = .requestingLinkToken
        linkReconnectingConnectionId = connection.id
        do {
            let linkToken = try await backend.createUpdateLinkToken(connectionId: connection.id)
            #if DEBUG
            print("[SpendSmartBuild] Link Update Mode started")
            #endif
            presentLink(withToken: linkToken)
        } catch {
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
                if let error = exit.error {
                    #if DEBUG
                    if linkReconnectingConnectionId != nil {
                        print("[SpendSmartBuild] Link Update Mode failed")
                    }
                    #endif
                    connectionAttempt = .failed(error.displayMessage ?? error.errorMessage)
                } else {
                    // The user closed Link without finishing — not a real failure, just back to
                    // idle.
                    #if DEBUG
                    if linkReconnectingConnectionId != nil {
                        print("[SpendSmartBuild] Link Update Mode cancelled")
                    }
                    #endif
                    connectionAttempt = .idle
                    activeConnectionId = nil
                }
            },
            onEvent: nil,
            onLoad: nil
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
        do {
            let result = try await backend.exchangePublicToken(
                publicToken,
                institutionId: institutionId,
                institutionName: institutionName
            )
            #if DEBUG
            print("[PlaidMulti] public token exchange completed")
            // exchange-public-token already runs the shared account-discovery helper server-side
            // and returns what it found — no separate refresh-plaid-accounts call is needed here
            // solely to populate this count.
            print("[PlaidMulti] account refresh completed count=\(result.accounts.count)")
            #endif
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
            try await performSync(connectionId: result.connectionId)
            #if DEBUG
            print("[PlaidMulti] transaction sync completed")
            #endif
            await refreshConnectionStatusFromServer()
            #if DEBUG
            print("[PlaidMulti] connection list refreshed count=\(plaidConnection.connections.count)")
            #endif
            connectionAttempt = .idle
        } catch {
            connectionAttempt = .failed(error.localizedDescription)
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
    ///    step 2 (this function never optimistically clears either flag locally itself).
    private func completeReconnect(connectionId: String) async {
        lastSyncSummaryByConnectionId[connectionId] = nil

        #if DEBUG
        print("[SpendSmartBuild] account refresh started")
        #endif
        do {
            _ = try await backend.refreshAccounts(connectionId: connectionId)
        } catch {
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
        } catch {
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
            connectionAttempt = .failed(error.localizedDescription)
        }
    }

    private func refreshBalances(connectionId: String) async {
        do {
            let balances = try await backend.syncBalances(connectionId: connectionId)
            balancesByConnectionId[connectionId] = balances
        } catch PlaidBackendError.requiresReauth {
            plaidConnection.markRequiresReauth(connectionId: connectionId)
        } catch {
            // Balance refresh failing is never fatal to the rest of this screen — transactions
            // sync is the primary flow; balances are a display-only addition.
            #if DEBUG
            print("[ConnectedAccountsView] balance refresh failed: \(error.localizedDescription)")
            #endif
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
            // the DEBUG log reflect the failure.
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
    /// backend protocol change beyond this pass's scope. `debugResetCursor` (wired to a
    /// `#if DEBUG`-gated "Reset Cursor & Reimport" button below) is the interim recovery path for
    /// Sandbox/testing.
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

    #if DEBUG
    /// Sandbox/testing-only recovery action for the atomicity gap documented on `performSync()`.
    /// Never shown or reachable in a Release build.
    private func resetCursorAndReimport(_ connection: PlaidConnection) async {
        isResettingCursorConnectionId = connection.id
        defer { isResettingCursorConnectionId = nil }
        do {
            try await backend.debugResetCursor(connectionId: connection.id)
            try await performSync(connectionId: connection.id)
        } catch {
            connectionAttempt = .failed(error.localizedDescription)
        }
    }
    #endif

    private func disconnect(connectionId: String) async {
        activeConnectionId = connectionId
        defer { activeConnectionId = nil }
        do {
            try await backend.disconnectAccount(connectionId: connectionId)
            plaidConnection.remove(connectionId: connectionId)
            balancesByConnectionId.removeValue(forKey: connectionId)
            lastSyncSummaryByConnectionId.removeValue(forKey: connectionId)
            connectionAttempt = .idle
        } catch {
            connectionAttempt = .failed(error.localizedDescription)
        }
        connectionPendingDisconnect = nil
    }
}

#Preview {
    ConnectedAccountsView()
        .environment(PlaidConnectionManager())
        .environment(PrivacyModeManager())
        .environment(AuthenticationService.shared)
}
