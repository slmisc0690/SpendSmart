import Foundation

/// One account Plaid discovered within a connected institution (a single Item can cover more than
/// one physical card/account) — returned by `exchangePublicToken`. Carries no balance; that's
/// `PlaidAccountBalance`'s job via `syncBalances`, kept separate since discovery and balance
/// refresh happen at different times/cadences.
struct PlaidAccountSummary: Equatable {
    let accountId: String
    let name: String?
    let mask: String?
    let type: String?
    let subtype: String?
}

/// The result of a successful `exchangePublicToken` call — the institution SpendSmart's backend
/// resolved (from Plaid Link's own metadata, never hardcoded/guessed) plus every account Plaid
/// reported for it.
struct PlaidExchangeResult: Equatable {
    let connectionId: String
    let institutionId: String?
    let institutionName: String
    let accounts: [PlaidAccountSummary]
    /// True when, at the moment this Item was created, the authenticated user already had a
    /// DIFFERENT connection for the same institution — see `exchange-public-token`'s duplicate-
    /// Item detection (`computeDuplicateInstitutionResult` in `_shared/plaid.ts`). Never blocks
    /// or invalidates the new connection by itself; this is metadata only, for the call site to
    /// act on (see `ConnectedAccountsView.handleLinkSuccess`).
    let duplicateInstitution: Bool
    /// The OTHER connection's opaque id — never this new one's, never a Plaid item_id. Only
    /// meaningful when `duplicateInstitution` is true.
    let existingConnectionId: String?
    let existingInstitutionName: String?
}

/// One account's current balance, as of the last `syncBalances` call — never persisted into
/// SwiftData (see `PlaidBackendService`'s doc comment on why this stays read-only, display-only
/// data rather than feeding the user's manually-tracked `Account` balances).
struct PlaidAccountBalance: Equatable {
    let accountId: String
    let name: String?
    let officialName: String?
    let mask: String?
    /// Plaid's own `type` (e.g. `"depository"`, `"credit"`, `"loan"`, `"investment"`) — kept as a
    /// raw `String`, not a Swift enum, specifically so a future Plaid account type this app has
    /// never seen decodes safely instead of throwing; `PlaidAccountKind.classify(type:subtype:)`
    /// is where that string gets interpreted for display, with an explicit unknown case.
    let type: String?
    let subtype: String?
    let currentBalance: Decimal?
    let availableBalance: Decimal?
    /// Plaid's `balances.limit` — for credit accounts, the credit limit; for depository accounts,
    /// the pre-arranged overdraft limit (see Plaid's Accounts API docs). Null when Plaid doesn't
    /// report one.
    let creditLimit: Decimal?
    let isoCurrencyCode: String?
    /// Set only when `isoCurrencyCode` is null (Plaid guarantees exactly one of the two is
    /// non-null) — a small number of institutions report balances in a currency without an ISO
    /// 4217 code (e.g. some cryptocurrencies).
    let unofficialCurrencyCode: String?
}

/// The result of a successful `refreshConnectedAccount` call — the ONE requested account's
/// freshly-refreshed balance, plus how many of today's (UTC calendar day) 2 manual refreshes
/// remain for that specific account afterward. The server is always authoritative for the count;
/// this is purely informational for the client to mirror in the Dashboard's button state.
struct ConnectedAccountRefreshResult: Equatable {
    let balance: PlaidAccountBalance
    let remaining: Int
}

/// The server-side truth about one linked institution, as `list-connections` reports it —
/// including flags a Plaid webhook set that this device could never have learned about on its
/// own (see `PlaidConnectionManager.applyServerState`).
struct PlaidConnectionStatus: Equatable {
    let connectionId: String
    let institutionId: String?
    let institutionName: String
    let requiresReauth: Bool
    let pendingExpirationAt: Date?
    /// Mirrors `plaid_items.pending_disconnect_at` — set once Plaid sends a `PENDING_DISCONNECT`
    /// webhook (this Item is expected to stop working soon). Never causes any automatic action;
    /// see the `pending_disconnect_at` column's own comment in
    /// `0006_plaid_items_pending_disconnect.sql`.
    let pendingDisconnectAt: Date?
    let newAccountsAvailable: Bool
}

/// Contract for talking to SpendSmart's own backend (Supabase Edge Functions) about linked
/// financial institutions — ANY institution Plaid supports, not just American Express. **This app
/// never talks to Plaid's API directly** — every method here calls one HTTPS endpoint on
/// `PlaidBackendConfig.baseURL` and nothing else.
///
/// SECURITY — what this type deliberately does NOT do:
/// - It never holds a Plaid client secret or access token. Those exist only inside the Edge
///   Functions in `supabase/functions/` and the `plaid_items` table in Supabase Postgres.
/// - It never constructs a request to `*.plaid.com`. The backend is the only thing that does.
/// - It never asks for or transmits a bank username/password — those are entered directly into
///   Plaid Link's own hosted UI, which this app doesn't control or observe.
///
/// See `supabase/README.md` for what needs to be deployed before any of this actually works.
protocol PlaidBackendService {
    /// Asks the backend to create a Plaid `link_token` for a NEW connection, used to open Plaid
    /// Link on-device. `daysRequested`, if provided, asks Plaid to make that many days of
    /// transaction history available (subject to Plaid's own per-account entitlement — this app
    /// doesn't enforce a ceiling beyond a basic sanity range; Plaid rejects anything it can't
    /// honor).
    func createLinkToken(daysRequested: Int?) async throws -> String

    /// Asks the backend to create a Plaid `link_token` in Link's UPDATE MODE for an ALREADY
    /// linked institution — used to reconnect after `ITEM_LOGIN_REQUIRED`/`PENDING_EXPIRATION`
    /// without deleting and recreating the connection (the existing `plaid_items` row, its
    /// access_token, and every already-synced transaction/account stay exactly as they are).
    func createUpdateLinkToken(connectionId: String) async throws -> String

    /// Sends the `public_token` Plaid Link returned to the backend, which exchanges it for an
    /// access token and stores that token server-side, along with the institution Plaid Link
    /// itself reported (`institutionId`/`institutionName` — NEVER assumed/hardcoded by this app)
    /// and the full account list Plaid reports for the new Item. Nothing sensitive comes back —
    /// only non-secret identifiers.
    func exchangePublicToken(_ publicToken: String, institutionId: String?, institutionName: String) async throws -> PlaidExchangeResult

    /// Asks the backend to fetch new/updated/removed transactions since the last sync for ONE
    /// linked institution. `connectionId` is required — a household account may have more than
    /// one linked institution, so there's no longer an implicit "the" connection to sync.
    func syncTransactions(connectionId: String) async throws -> PlaidSyncResult

    /// Asks the backend to refresh account balances for ONE linked institution. Separate from
    /// `syncTransactions` since balance refresh and transaction sync have different natural
    /// cadences and failure domains.
    func syncBalances(connectionId: String) async throws -> [PlaidAccountBalance]

    /// Asks the backend to refresh ONE specific account's balance (the Dashboard's per-account
    /// "Refresh" button) — subject to a server-enforced maximum of 2 manual refreshes per account
    /// per UTC calendar day (see `refresh-connected-account/index.ts` and
    /// `0009_connected_account_refresh_log.sql`). `accountId` is Plaid's own `account_id`, the
    /// same identifier `PlaidAccountBalance.accountId`/`CachedPlaidAccountBalance.accountId`
    /// already carry — never this project's internal `plaid_accounts.id`, which the client never
    /// needs to know. Throws `PlaidBackendError.rateLimited` when today's allowance for this
    /// specific account is already used — never silently retried, never shown as a raw backend
    /// error; callers must handle it as "disable this account's button for the rest of today."
    func refreshConnectedAccount(connectionId: String, accountId: String) async throws -> ConnectedAccountRefreshResult

    /// Asks the backend to re-run Plaid account DISCOVERY (`/accounts/get`) for an ALREADY linked
    /// institution — call this right after a successful Link UPDATE MODE session, so any account
    /// that became newly available (the reason `NEW_ACCOUNTS_AVAILABLE` fired in the first place)
    /// actually gets inserted into `plaid_accounts`, not just re-synced for balances/transactions.
    /// On success, the backend also clears `requires_reauth`/`new_accounts_available` for this
    /// connection server-side — see `refresh-plaid-accounts/index.ts` for why tying those clears
    /// to THIS call's own success, rather than a client-asserted "Link succeeded" flag, is the
    /// stronger guarantee. On failure, neither flag is touched and nothing about the existing
    /// connection changes — callers must surface the failure, not silently treat it as success.
    func refreshAccounts(connectionId: String) async throws -> [PlaidAccountSummary]

    /// Asks the backend for the authoritative, server-side status of every institution this
    /// account has linked — the only way this device learns about a webhook-driven flag (e.g.
    /// `requiresReauth`) it didn't itself set.
    func listConnections() async throws -> [PlaidConnectionStatus]

    /// Asks the backend to disconnect a linked institution and revoke its token. `connectionId`
    /// is the value `exchangePublicToken` returned — never guessed, never omitted. (Renamed from
    /// `disconnectAmex` now that a household account can link more than one institution.)
    func disconnectAccount(connectionId: String) async throws

    /// Sandbox/testing-only recovery path — see `debug-reset-cursor/index.ts` for why this
    /// exists. Resets the stored Plaid cursor for `connectionId` so the next
    /// `syncTransactions(connectionId:)` re-pulls the full history from scratch. Never call this
    /// outside a `#if DEBUG` build.
    func debugResetCursor(connectionId: String) async throws
}

extension PlaidBackendService {
    /// Default so every existing call site (and every test) that doesn't care about historical
    /// range keeps compiling unchanged.
    func createLinkToken() async throws -> String {
        try await createLinkToken(daysRequested: nil)
    }
}

enum PlaidBackendError: FriendlyError {
    /// `PlaidBackendConfig.baseURL` hasn't been set yet — see `supabase/README.md`.
    case notConfigured
    case invalidResponse
    /// No signed-in session, or the backend rejected the access token (expired/invalid) — a 401
    /// from any of the user-invoked functions, each of which validates the caller's own
    /// `Authorization: Bearer <token>` in code (see supabase/functions/_shared/plaid.ts).
    case unauthorized
    /// `sync-transactions`/`sync-balances` returned 409 because `plaid_items.requires_reauth` is
    /// true for this connection (set by a `plaid-webhook` `ITEM_LOGIN_REQUIRED` handler) — the
    /// access_token can no longer be used until the user reconnects via Link UPDATE MODE (see
    /// `PlaidBackendService.createUpdateLinkToken`). Distinct from `.server` so call sites can
    /// route straight to "reconnect" UI instead of showing a generic error.
    case requiresReauth
    /// `refresh-connected-account` returned 429 — today's (UTC calendar day) 2-manual-refresh
    /// allowance for that specific account is already used. Distinct from `.server` for the same
    /// reason as `.requiresReauth`: call sites must route straight to a graceful "disable this
    /// button, show a limit-reached state" UI, never a raw backend error string.
    case rateLimited
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The SpendSmart backend isn't configured yet. Deploy the Supabase Edge Functions and set PlaidBackendConfig.baseURL."
        case .invalidResponse:
            return "The backend returned an unexpected response."
        case .unauthorized:
            return "You're signed out. Please sign in again."
        case .requiresReauth:
            return "This connection needs to be reconnected."
        case .rateLimited:
            return "Daily refresh limit reached for this account."
        case .server(let status, let message):
            return "Backend error (\(status)): \(message)"
        }
    }
}

/// Where the SpendSmart backend lives. `baseURL` is `nil` until you deploy the Edge Functions in
/// `supabase/functions/` and fill this in — every `SupabasePlaidBackendService` call throws
/// `.notConfigured` until then, so nothing here can accidentally reach a real endpoint.
enum PlaidBackendConfig {
    /// The deployed Supabase project's Edge Functions base URL. Supabase invokes Edge Functions
    /// at `https://<project-ref>.supabase.co/functions/v1/<function-name>`, so the project ref's
    /// bare domain isn't enough on its own — the `/functions/v1` path is part of this constant so
    /// every call site can keep doing `baseURL.appendingPathComponent("create-link-token")` etc.
    /// without needing to know that.
    ///
    /// This app never chooses a Plaid environment — that's a server-side-only decision (the
    /// `PLAID_ENV` Supabase Secret, read by `loadPlaidCredentials` in
    /// `supabase/functions/_shared/plaid.ts`), and it never appears in this URL or anywhere else
    /// in the app. This constant is the same Supabase project URL regardless of whether the
    /// backend is currently pointed at Plaid Sandbox, Development, or (once enabled) Production —
    /// switching Plaid environments is a one-secret server-side change, not an iOS change.
    static let baseURL: URL? = URL(string: "https://dlqjgpgnaguhubftfpel.supabase.co/functions/v1")
}

/// Real implementation of `PlaidBackendService` — calls the SpendSmart backend over HTTPS.
/// Talks only to `PlaidBackendConfig.baseURL`; never to Plaid, never with a Plaid credential.
struct SupabasePlaidBackendService: PlaidBackendService {
    private let baseURL: URL?
    private let session: URLSession
    /// Supplies the signed-in user's current access token for every call — defaults to
    /// `AuthenticationService.shared`, the one app-wide session (see its doc comment for why a
    /// second instance would be a bug). Tests inject a throwing/fixed closure instead of a real
    /// session, so `.unauthorized` behavior is verified without a live Supabase Auth call.
    private let accessTokenProvider: () async throws -> String

    /// `baseURL` defaults to `PlaidBackendConfig.baseURL` — the production call sites never pass
    /// this explicitly. Tests inject `nil` directly so the "not configured" path is verified
    /// deterministically, independent of whatever `PlaidBackendConfig.baseURL` happens to be set
    /// to for this build.
    init(
        baseURL: URL? = PlaidBackendConfig.baseURL,
        session: URLSession = .shared,
        accessTokenProvider: @escaping () async throws -> String = { try await AuthenticationService.shared.currentAccessToken() }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.accessTokenProvider = accessTokenProvider
        Self.logConfigurationStatus(baseURL: baseURL)
    }

    /// Logs only whether a backend URL is configured and its host/path — never its query,
    /// never any request body, header, or credential. Safe to leave enabled in Debug builds
    /// when diagnosing "backend isn't configured" reports.
    private static func logConfigurationStatus(baseURL: URL?) {
        #if DEBUG
        if let baseURL, let host = baseURL.host {
            print("[PlaidBackend] configured=true host=\(host) path=\(baseURL.path)")
        } else {
            print("[PlaidBackend] configured=false (baseURL is nil)")
        }
        #endif
    }

    func createLinkToken(daysRequested: Int?) async throws -> String {
        struct Body: Encodable { let days_requested: Int? }
        let response: CreateLinkTokenResponse = try await post("create-link-token", body: Body(days_requested: daysRequested))
        return response.linkToken
    }

    func createUpdateLinkToken(connectionId: String) async throws -> String {
        struct Body: Encodable { let connection_id: String }
        let response: CreateLinkTokenResponse = try await post("create-link-token", body: Body(connection_id: connectionId))
        return response.linkToken
    }

    func exchangePublicToken(_ publicToken: String, institutionId: String?, institutionName: String) async throws -> PlaidExchangeResult {
        struct Body: Encodable {
            let public_token: String
            let institution_id: String?
            let institution_name: String
        }
        let response: ExchangeResponse = try await post(
            "exchange-public-token",
            body: Body(public_token: publicToken, institution_id: institutionId, institution_name: institutionName)
        )
        return PlaidExchangeResult(
            connectionId: response.connectionId,
            institutionId: response.institutionId,
            institutionName: response.institutionName,
            accounts: response.accounts.map(\.asPlaidAccountSummary),
            duplicateInstitution: response.duplicateInstitution,
            existingConnectionId: response.existingConnectionId,
            existingInstitutionName: response.existingInstitutionName
        )
    }

    func syncTransactions(connectionId: String) async throws -> PlaidSyncResult {
        struct Body: Encodable { let connection_id: String }
        let response: SyncTransactionsResponse = try await post("sync-transactions", body: Body(connection_id: connectionId))
        #if DEBUG
        print("[PlaidBackend] sync response decoded: true")
        print("[PlaidBackend] added count: \(response.transactions.count)")
        print("[PlaidBackend] modified count: \(response.modifiedTransactions.count)")
        print("[PlaidBackend] removed count: \(response.removedTransactionIds.count)")
        #endif
        return PlaidSyncResult(
            added: response.transactions.map(\.asPlaidTransactionDTO),
            modified: response.modifiedTransactions.map(\.asPlaidTransactionDTO),
            removedExternalIds: response.removedTransactionIds
        )
    }

    func syncBalances(connectionId: String) async throws -> [PlaidAccountBalance] {
        struct Body: Encodable { let connection_id: String }
        let response: SyncBalancesResponse = try await post("sync-balances", body: Body(connection_id: connectionId))
        #if DEBUG
        print("[PlaidBackend] balance refresh completed, account count: \(response.accounts.count)")
        #endif
        return response.accounts.map { $0.asPlaidAccountBalance() }
    }

    func refreshConnectedAccount(connectionId: String, accountId: String) async throws -> ConnectedAccountRefreshResult {
        struct Body: Encodable { let connection_id: String; let account_id: String }
        let response: RefreshConnectedAccountResponse = try await post(
            "refresh-connected-account",
            body: Body(connection_id: connectionId, account_id: accountId)
        )
        #if DEBUG
        print("[PlaidBackend] connected-account refresh completed, remaining today: \(response.remaining)")
        #endif
        return ConnectedAccountRefreshResult(balance: response.account.asPlaidAccountBalance(), remaining: response.remaining)
    }

    func refreshAccounts(connectionId: String) async throws -> [PlaidAccountSummary] {
        struct Body: Encodable { let connection_id: String }
        let response: RefreshAccountsResponse = try await post("refresh-plaid-accounts", body: Body(connection_id: connectionId))
        #if DEBUG
        print("[PlaidBackend] account refresh completed, account count: \(response.accounts.count)")
        #endif
        return response.accounts.map(\.asPlaidAccountSummary)
    }

    func listConnections() async throws -> [PlaidConnectionStatus] {
        let response: ListConnectionsResponse = try await post("list-connections", body: EmptyRequestBody())
        return response.connections.map(\.asPlaidConnectionStatus)
    }

    func disconnectAccount(connectionId: String) async throws {
        struct Body: Encodable { let connection_id: String }
        do {
            let _: DisconnectedResponse = try await post("disconnect-account", body: Body(connection_id: connectionId))
            #if DEBUG
            print("[PlaidBackend] function=disconnect-account status=200")
            #endif
        } catch {
            #if DEBUG
            print("[PlaidBackend] function=disconnect-account status=\(Self.statusDescription(for: error))")
            #endif
            throw error
        }
    }

    #if DEBUG
    /// Only a status code (or a short, non-sensitive fallback word) — never a connection id,
    /// token, or response body.
    private static func statusDescription(for error: Error) -> String {
        switch error {
        case PlaidBackendError.server(let status, _): return "\(status)"
        case PlaidBackendError.unauthorized: return "401"
        case PlaidBackendError.notConfigured: return "not_configured"
        case PlaidBackendError.invalidResponse: return "invalid_response"
        default: return "error"
        }
    }
    #endif

    func debugResetCursor(connectionId: String) async throws {
        struct Body: Encodable { let connection_id: String }
        let _: ResetCursorResponse = try await post("debug-reset-cursor", body: Body(connection_id: connectionId))
    }

    // MARK: - Networking

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        guard let baseURL else {
            throw PlaidBackendError.notConfigured
        }

        // Every one of these functions requires `Authorization: Bearer <user access token>` (see
        // supabase/functions/_shared/plaid.ts's requireAuthenticatedUserId) — gateway-level
        // verify_jwt doesn't work with this project's key format, so this is the REAL auth check,
        // not a formality. No session means no call — fail locally with `.unauthorized` instead
        // of sending a request that would just get a 401 back.
        guard let accessToken = try? await accessTokenProvider(), !accessToken.isEmpty else {
            throw PlaidBackendError.unauthorized
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw PlaidBackendError.invalidResponse
        }
        #if DEBUG
        // Never the raw body — a synced transaction list can carry merchant names and amounts.
        // Never the Authorization header either, obviously.
        print("[PlaidBackend] \(path) HTTP status: \(httpResponse.statusCode)")
        print("[PlaidBackend] \(path) response byte count: \(data.count)")
        #endif

        if httpResponse.statusCode == 401 {
            throw PlaidBackendError.unauthorized
        }
        if httpResponse.statusCode == 409 {
            // `sync-transactions`/`sync-balances`'s "this connection needs to be reconnected"
            // response — see `PlaidBackendError.requiresReauth`'s doc comment. Every other
            // function either never returns 409 or has no meaningful distinction to make here, so
            // this check is safe to apply globally rather than per-endpoint.
            throw PlaidBackendError.requiresReauth
        }
        if httpResponse.statusCode == 429 {
            // `refresh-connected-account`'s "today's 2-refresh allowance for this account is
            // already used" response — see `PlaidBackendError.rateLimited`'s doc comment. No other
            // function returns 429, so this check is safe to apply globally.
            throw PlaidBackendError.rateLimited
        }

        // 2xx and non-2xx are decoded as two entirely separate, non-overlapping types — a non-2xx
        // response is never handed to `Response`'s (the success type's) decoder, and a 2xx
        // response never attempts `BackendErrorBody`.
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendErrorBody.self, from: data).error) ?? "Unknown error"
            throw PlaidBackendError.server(status: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Response.self, from: data)
        } catch let decodingError as DecodingError {
            #if DEBUG
            print("[PlaidBackend] \(path) success response decoded: false")
            logDecodingError(decodingError, path: path)
            #endif
            throw decodingError
        }
    }

    private func handleServerError<Response>(status: Int, message: String) throws -> Response {
        throw PlaidBackendError.server(status: status, message: message)
    }

    #if DEBUG
    /// Logs only the decoder's own structural diagnostics (which key path failed, and Swift's
    /// description of why) — never the payload itself, since it can carry transaction details.
    private func logDecodingError(_ error: DecodingError, path: String) {
        let codingPath: String
        let debugDescription: String
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .keyNotFound(_, let context), .dataCorrupted(let context):
            codingPath = context.codingPath.map(\.stringValue).joined(separator: ".")
            debugDescription = context.debugDescription
        @unknown default:
            codingPath = "(unknown)"
            debugDescription = "(unknown DecodingError case)"
        }
        print("[PlaidBackend] \(path) DecodingError codingPath: \(codingPath)")
        print("[PlaidBackend] \(path) DecodingError debugDescription: \(debugDescription)")
    }
    #endif
}

private struct EmptyRequestBody: Encodable {}

private struct BackendErrorBody: Decodable {
    let error: String
}

private struct CreateLinkTokenResponse: Decodable {
    let linkToken: String
    enum CodingKeys: String, CodingKey { case linkToken = "link_token" }
}

private struct BackendAccountSummaryDTO: Decodable {
    let accountId: String
    let name: String?
    let mask: String?
    let type: String?
    let subtype: String?
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id", name, mask, type, subtype
    }

    var asPlaidAccountSummary: PlaidAccountSummary {
        PlaidAccountSummary(accountId: accountId, name: name, mask: mask, type: type, subtype: subtype)
    }
}

private struct ExchangeResponse: Decodable {
    let connected: Bool
    let connectionId: String
    let institutionId: String?
    let institutionName: String
    let accounts: [BackendAccountSummaryDTO]
    let duplicateInstitution: Bool
    let existingConnectionId: String?
    let existingInstitutionName: String?
    enum CodingKeys: String, CodingKey {
        case connected, connectionId = "connection_id"
        case institutionId = "institution_id", institutionName = "institution_name"
        case accounts
        case duplicateInstitution = "duplicate_institution"
        case existingConnectionId = "existing_connection_id"
        case existingInstitutionName = "existing_institution_name"
    }
}

private struct DisconnectedResponse: Decodable {
    let disconnected: Bool
}

private struct RefreshAccountsResponse: Decodable {
    let connectionId: String
    let accounts: [BackendAccountSummaryDTO]
    enum CodingKeys: String, CodingKey { case connectionId = "connection_id", accounts }
}

private struct BackendAccountBalanceDTO: Decodable {
    let accountId: String
    let name: String?
    let officialName: String?
    let mask: String?
    let type: String?
    let subtype: String?
    /// Parsed from a JSON **string**, not a JSON number — see `BackendTransactionDTO.init(from:)`'s
    /// doc comment for why (the same `Double`-precision risk applies to balances as it does to
    /// transaction amounts). Parsing happens here in `init(from:)`, not in a separate mapping
    /// step, so a malformed balance string is a genuine decode failure (thrown immediately) rather
    /// than something a later call site could accidentally coerce to nil and silently ignore.
    let currentBalance: Decimal?
    let availableBalance: Decimal?
    let creditLimit: Decimal?
    let isoCurrencyCode: String?
    let unofficialCurrencyCode: String?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id", name
        case officialName = "official_name", mask, type, subtype
        case currentBalance = "current_balance", availableBalance = "available_balance"
        case creditLimit = "credit_limit"
        case isoCurrencyCode = "iso_currency_code"
        case unofficialCurrencyCode = "unofficial_currency_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        officialName = try container.decodeIfPresent(String.self, forKey: .officialName)
        mask = try container.decodeIfPresent(String.self, forKey: .mask)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        isoCurrencyCode = try container.decodeIfPresent(String.self, forKey: .isoCurrencyCode)
        // decodeIfPresent, not decode — an older backend build (before this field existed) would
        // simply omit the key rather than send it as `null`, and this must decode that the same
        // way as an explicit `null`: no currency code either way.
        unofficialCurrencyCode = try container.decodeIfPresent(String.self, forKey: .unofficialCurrencyCode)
        currentBalance = try Self.decodeBalance(container, forKey: .currentBalance)
        availableBalance = try Self.decodeBalance(container, forKey: .availableBalance)
        creditLimit = try Self.decodeBalance(container, forKey: .creditLimit)
    }

    private static func decodeBalance(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Decimal? {
        guard let string = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let value = Decimal(string: string) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\"\(string)\" is not a valid decimal balance"
            )
        }
        return value
    }

    func asPlaidAccountBalance() -> PlaidAccountBalance {
        PlaidAccountBalance(
            accountId: accountId,
            name: name,
            officialName: officialName,
            mask: mask,
            type: type,
            subtype: subtype,
            currentBalance: currentBalance,
            availableBalance: availableBalance,
            creditLimit: creditLimit,
            isoCurrencyCode: isoCurrencyCode,
            unofficialCurrencyCode: unofficialCurrencyCode
        )
    }
}

private struct SyncBalancesResponse: Decodable {
    let connectionId: String
    let accounts: [BackendAccountBalanceDTO]
    enum CodingKeys: String, CodingKey { case connectionId = "connection_id", accounts }
}

private struct RefreshConnectedAccountResponse: Decodable {
    let connectionId: String
    /// Reuses `BackendAccountBalanceDTO` — `refresh-connected-account`'s single `account` object
    /// is deliberately the exact same per-account JSON shape `sync-balances` already sends for
    /// each entry in its `accounts` array, so nothing new needs decoding logic of its own.
    let account: BackendAccountBalanceDTO
    let remaining: Int
    enum CodingKeys: String, CodingKey { case connectionId = "connection_id", account, remaining }
}

private struct BackendConnectionStatusDTO: Decodable {
    let connectionId: String
    let institutionId: String?
    let institutionName: String
    let requiresReauth: Bool
    let pendingExpirationAt: Date?
    let pendingDisconnectAt: Date?
    let newAccountsAvailable: Bool
    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case institutionId = "institution_id", institutionName = "institution_name"
        case requiresReauth = "requires_reauth"
        case pendingExpirationAt = "pending_expiration_at"
        case pendingDisconnectAt = "pending_disconnect_at"
        case newAccountsAvailable = "new_accounts_available"
    }

    var asPlaidConnectionStatus: PlaidConnectionStatus {
        PlaidConnectionStatus(
            connectionId: connectionId,
            institutionId: institutionId,
            institutionName: institutionName,
            requiresReauth: requiresReauth,
            pendingExpirationAt: pendingExpirationAt,
            pendingDisconnectAt: pendingDisconnectAt,
            newAccountsAvailable: newAccountsAvailable
        )
    }
}

private struct ListConnectionsResponse: Decodable {
    let connections: [BackendConnectionStatusDTO]
}

private struct SyncTransactionsResponse: Decodable {
    let transactions: [BackendTransactionDTO]
    /// Same shape as `transactions` — Plaid's `modified` entries are full transaction objects,
    /// just like `added`, so they decode through the exact same `BackendTransactionDTO`.
    let modifiedTransactions: [BackendTransactionDTO]
    /// Plaid's own `transaction_id` for each removed transaction — Plaid's `removed` entries
    /// don't carry a full transaction object, only the id.
    let removedTransactionIds: [String]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case transactions, nextCursor = "next_cursor"
        case modifiedTransactions = "modified_transactions"
        case removedTransactionIds = "removed_transaction_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactions = try container.decode([BackendTransactionDTO].self, forKey: .transactions)
        // decodeIfPresent ?? [] so this stays forward-compatible if an older backend build omits
        // these fields.
        modifiedTransactions = try container.decodeIfPresent([BackendTransactionDTO].self, forKey: .modifiedTransactions) ?? []
        removedTransactionIds = try container.decodeIfPresent([String].self, forKey: .removedTransactionIds) ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

private struct ResetCursorResponse: Decodable {
    let reset: Bool
}

/// The raw JSON shape `sync-transactions` returns (snake_case, matching the backend). Kept
/// separate from `PlaidTransactionDTO` so the wire format can change without touching the rest
/// of the app — only `asPlaidTransactionDTO` needs to know about both shapes.
struct BackendTransactionDTO: Decodable, Equatable {
    let externalTransactionId: String
    let pendingTransactionId: String?
    let plaidAccountId: String
    let amount: Decimal
    let merchantName: String?
    let originalDescription: String
    let authorizedDate: Date?
    let postedDate: Date?
    let isPending: Bool
    let categoryGuess: String?

    enum CodingKeys: String, CodingKey {
        case externalTransactionId = "external_transaction_id"
        case pendingTransactionId = "pending_transaction_id"
        case plaidAccountId = "plaid_account_id"
        case amount
        case merchantName = "merchant_name"
        case originalDescription = "original_description"
        case authorizedDate = "authorized_date"
        case postedDate = "posted_date"
        case isPending = "is_pending"
        case categoryGuess = "category_guess"
    }

    /// `amount` is decoded from a JSON **string** (e.g. `"19.99"`), not a JSON number — the
    /// backend deliberately sends it that way (see `sync-transactions/index.ts`). `JSONDecoder`
    /// decodes numeric literals through `Double` before `Decimal` ever sees them, which silently
    /// corrupts exact cent values (e.g. 19.99 becomes 19.98999999999999488). Going through a
    /// string sidesteps that entirely.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        externalTransactionId = try container.decode(String.self, forKey: .externalTransactionId)
        pendingTransactionId = try container.decodeIfPresent(String.self, forKey: .pendingTransactionId)
        plaidAccountId = try container.decode(String.self, forKey: .plaidAccountId)

        let amountString = try container.decode(String.self, forKey: .amount)
        guard let decodedAmount = Decimal(string: amountString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "\"\(amountString)\" is not a valid decimal amount"
            )
        }
        amount = decodedAmount

        merchantName = try container.decodeIfPresent(String.self, forKey: .merchantName)
        originalDescription = try container.decode(String.self, forKey: .originalDescription)

        // Plaid's `authorized_date`/`date` (forwarded here as `authorized_date`/`posted_date`) are
        // bare calendar dates — e.g. "2026-07-01", NOT "2026-07-01T00:00:00Z". Decoding these
        // through the container's own `Date.self` would use whatever `dateDecodingStrategy` the
        // caller's JSONDecoder is configured with (`.iso8601` in this app's case), which requires
        // a time component and throws `DecodingError.dataCorrupted` on a bare date — this is
        // exactly the "data couldn't be read because it isn't in the correct format" crash. Decode
        // as a string first and parse with a date-only formatter instead, independent of whatever
        // decoding strategy the rest of the payload uses.
        authorizedDate = try Self.decodeBareDate(container, forKey: .authorizedDate)
        postedDate = try Self.decodeBareDate(container, forKey: .postedDate)

        isPending = try container.decode(Bool.self, forKey: .isPending)
        categoryGuess = try container.decodeIfPresent(String.self, forKey: .categoryGuess)
    }

    /// Parses a Plaid date-only string ("2026-07-01") into the **local** midnight `Date` for
    /// that calendar day — deliberately NOT UTC-anchored. Parsing a bare date via
    /// `ISO8601DateFormatter`/`DateFormatter` defaults to UTC, producing e.g.
    /// `2026-07-18T00:00:00Z`; every display/grouping call site in this app (Activity,
    /// Dashboard, Weekly, Monthly Summary) reinterprets a `Date` through `Calendar.current` —
    /// the device's LOCAL time zone — which rolls a UTC-midnight instant back to the PRIOR
    /// calendar day in any time zone behind UTC. This was the confirmed root cause of Plaid-
    /// imported transactions displaying one day early. Building the `Date` directly from the
    /// target calendar's own `DateComponents` instead produces an instant that always
    /// represents THIS calendar day when read back through that same calendar/time zone —
    /// exactly matching how a manually-entered transaction's `DatePicker` value already behaves
    /// (also device-local midnight), so both round-trip through every `Calendar.current`-based
    /// display/grouping call site identically, regardless of device time zone. `calendar` is
    /// injectable (default `.current`) so this is deterministically testable across time zones.
    static func parseBareDate(_ string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    private static func decodeBareDate(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Date? {
        guard let dateString = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = Self.parseBareDate(dateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\"\(dateString)\" is not a valid \"yyyy-MM-dd\" date"
            )
        }
        return date
    }

    var asPlaidTransactionDTO: PlaidTransactionDTO {
        PlaidTransactionDTO(
            externalTransactionId: externalTransactionId,
            pendingTransactionId: pendingTransactionId,
            plaidAccountId: plaidAccountId,
            amount: amount,
            merchantName: merchantName,
            originalDescription: originalDescription,
            authorizedDate: authorizedDate,
            postedDate: postedDate,
            isPending: isPending,
            categoryGuess: categoryGuess
        )
    }
}
