import Foundation

enum HouseholdSharingError: Error, Equatable {
    case notConfigured
    case unauthorized
    case invalidResponse
    case server(status: Int, message: String)
}

/// Contract for talking to SpendSmart's own backend about PHASE 7's household/sharing controls —
/// mirrors `MonthlyPlanSyncService`'s/`ManualDataSyncService`'s exact shape/security posture.
/// Every call authenticates via the caller's own access token; none of these calls ever sends a
/// client-supplied "who am I" identity in the body — only the specific data a write targets
/// (email, invitation id, category/item id), matching every trusted-write Edge Function's own
/// contract (see their file headers).
protocol HouseholdSharingService {
    /// Idempotent — becomes Primary of a new household, or returns the caller's existing
    /// membership state if one already exists.
    func initializeHousehold() async throws -> HouseholdStateResponse

    /// The one consolidated read for the Account Related Options screen.
    func getAccountRelatedOptions() async throws -> AccountRelatedOptionsResponse

    func manageInvitation(_ request: InvitationActionRequest) async throws -> InvitationActionResponse

    func updateSharingPermission(_ request: SharingPermissionUpdateRequest) async throws -> SharingPermissionUpdateResponse

    /// Phase 8 — safe pre-acceptance preview for the token in an opened invitation link.
    func previewInvitation(token: String) async throws -> InvitationPreviewResponse

    /// Phase 8 — the sole mutation: accepts the invitation matching `token` for the
    /// currently-authenticated caller.
    func acceptInvitation(token: String) async throws -> AcceptInvitationResponse

    /// Phase 8D — checks whether the currently-authenticated caller has a valid pending
    /// invitation addressed to their own verified email, with no token/link needed.
    func checkMyPendingInvitation() async throws -> MyPendingInvitationResponse

    /// Phase 8D — accepts a SELF-DISCOVERED invitation (from `checkMyPendingInvitation`) by id
    /// rather than by token. See migration 0015's own header for why this is an equally-secure,
    /// differently-shaped acceptance path.
    func acceptInvitation(invitationId: UUID) async throws -> AcceptInvitationResponse

    /// Phase 8D follow-up — declines a SELF-DISCOVERED invitation (from
    /// `checkMyPendingInvitation`) by id. See migration 0015's `decline_household_invitation_by_id`
    /// header for why this is a distinct status value from the pre-existing `revoked`.
    func declineInvitation(invitationId: UUID) async throws -> DeclineInvitationResponse

    /// Phase 9 — reads normalized transactions for a Primary-owned Connected Account the caller
    /// (an active Secondary) has been shown by `getAccountRelatedOptions`'s own
    /// `primarySharedConnectedAccounts`. `plaidAccountId` must be one of those server-discovered
    /// ids — never fabricated client-side. Unmodified, pre-existing Phase 4 endpoint; permission
    /// is decided entirely server-side (see `get-connected-account-transactions`'s own header).
    func getSharedConnectedAccountTransactions(plaidAccountId: UUID) async throws -> SharedConnectedAccountTransactionsResponse

    /// Phase 9 — reads a Primary-owned Manual Account (plus its transactions) the caller has been
    /// shown by `primarySharedManualAccounts`. Same "server-discovered id only" contract as above.
    /// Unmodified, pre-existing Phase 5 endpoint.
    func getSharedManualAccountData(manualAccountId: UUID) async throws -> SharedManualAccountDataResponse

    /// Phase 9 — reads the Primary's Monthly Plan when `primaryMonthlyPlanShared` is true, using
    /// the server-discovered `primaryUserId` (never the caller's own id, never fabricated).
    /// Unmodified, pre-existing Phase 6 endpoint.
    func getSharedMonthlyPlan(ownerUserId: UUID) async throws -> SharedMonthlyPlanResponse

    /// CLIENT UI PHASE — the Primary's own aggregate savings totals upload (`savedThisMonth`/
    /// `totalSavingsToDate` only, never individual `SavingsEntry` rows). Caller identity comes
    /// from the access token alone; there is no owner field to (mis)trust — `set_savings_summary`
    /// always writes to the authenticated caller's own row.
    func upsertSavingsSummary(_ request: UpsertSavingsSummaryRequest) async throws -> UpsertSavingsSummaryResponse

    /// CLIENT UI PHASE — reads the Primary's shared Monthly Savings aggregate when
    /// `primaryMonthlySavingsShared` is true, using the server-discovered `primaryUserId`. Same
    /// "server-discovered id only" contract as `getSharedMonthlyPlan`.
    func getMonthlySavingsSummary(ownerUserId: UUID) async throws -> SharedMonthlySavingsSummaryResponse

    /// SAVED VIA TRANSFER SHARING — the Primary's own aggregate Saved-via-Transfer total upload
    /// (`savedViaTransferThisMonth` only). Caller identity comes from the access token alone;
    /// `set_saved_via_transfer_summary` always writes to the authenticated caller's own row.
    func upsertSavedViaTransferSummary(_ request: UpsertSavedViaTransferSummaryRequest) async throws -> UpsertSavedViaTransferSummaryResponse

    /// SAVED VIA TRANSFER SHARING — reads the Primary's shared Saved-via-Transfer aggregate when
    /// `primarySavedViaTransferShared` is true, using the server-discovered `primaryUserId`. Same
    /// "server-discovered id only" contract as `getSharedMonthlyPlan`.
    func getSavedViaTransferSummary(ownerUserId: UUID) async throws -> SharedSavedViaTransferSummaryResponse

    /// USER B DASHBOARD PARITY — the Primary's own authoritative Dashboard aggregate upload
    /// (`actualSpentThisMonth`/`monthlySpendRemaining`/`weeklySpendingLimit`/`actualSpentThisWeek`/
    /// `weeklyRemaining`, already privacy-filtered to only explicitly-shared accounts, plus the
    /// optional `monthlySpendingBudget` consistency figure). Caller identity comes from the access
    /// token alone; `set_dashboard_summary` always writes to the authenticated caller's own row.
    func upsertDashboardSummary(_ request: UpsertDashboardSummaryRequest) async throws -> UpsertDashboardSummaryResponse

    /// USER B DASHBOARD PARITY — reads the Primary's shared, authoritative Dashboard aggregate
    /// when `primaryMonthlyPlanShared` is true (the SAME gate `getSharedMonthlyPlan` uses), using
    /// the server-discovered `primaryUserId`. Never a second independent calculation — this is the
    /// exact number the Primary's own Dashboard shows.
    func getDashboardSummary(ownerUserId: UUID) async throws -> SharedDashboardSummaryResponse

    /// LOCAL DATA RESTORE — reads ALL of the caller's own Manual Accounts (+ transactions) from
    /// Supabase, for recovering a device whose local SwiftData store was wiped (fresh install, new
    /// device) but whose data had already synced to the cloud. Owner-only: no id of any kind is
    /// ever passed in the request — identity comes entirely from the caller's own access token,
    /// same as `getAccountRelatedOptions`. See `get-my-manual-accounts`'s own header for why this
    /// needed a new endpoint (`getSharedManualAccountData` requires an id the caller doesn't have
    /// yet after a wipe) while Monthly Plan restore reuses `getSharedMonthlyPlan(ownerUserId:)`
    /// unmodified (self-access was already authorized there).
    func getMyManualAccounts() async throws -> MyManualAccountsResponse
}

private struct HouseholdSharingErrorBody: Decodable {
    let error: String
}

/// Talks only to `PlaidBackendConfig.baseURL` (the same Supabase project every other backend call
/// in this app uses).
struct SupabaseHouseholdSharingService: HouseholdSharingService {
    private let baseURL: URL?
    private let session: URLSession
    private let accessTokenProvider: () async throws -> String

    init(
        baseURL: URL? = PlaidBackendConfig.baseURL,
        session: URLSession = .shared,
        accessTokenProvider: @escaping () async throws -> String = { try await AuthenticationService.shared.currentAccessToken() }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.accessTokenProvider = accessTokenProvider
    }

    func initializeHousehold() async throws -> HouseholdStateResponse {
        try await post("initialize-household", body: EmptyRequest())
    }

    func getAccountRelatedOptions() async throws -> AccountRelatedOptionsResponse {
        try await post("get-account-related-options", body: EmptyRequest())
    }

    func manageInvitation(_ request: InvitationActionRequest) async throws -> InvitationActionResponse {
        try await post("manage-household-invitation", body: request)
    }

    func updateSharingPermission(_ request: SharingPermissionUpdateRequest) async throws -> SharingPermissionUpdateResponse {
        try await post("update-sharing-permission", body: request)
    }

    func previewInvitation(token: String) async throws -> InvitationPreviewResponse {
        try await post("get-household-invitation-preview", body: InvitationTokenRequest(token: token))
    }

    func acceptInvitation(token: String) async throws -> AcceptInvitationResponse {
        try await post("accept-household-invitation", body: InvitationTokenRequest(token: token))
    }

    func checkMyPendingInvitation() async throws -> MyPendingInvitationResponse {
        try await post("get-my-pending-household-invitation", body: EmptyRequest())
    }

    func acceptInvitation(invitationId: UUID) async throws -> AcceptInvitationResponse {
        try await post("accept-household-invitation", body: InvitationIdRequest(invitationId: invitationId.uuidString))
    }

    func declineInvitation(invitationId: UUID) async throws -> DeclineInvitationResponse {
        try await post("decline-household-invitation", body: InvitationIdRequest(invitationId: invitationId.uuidString))
    }

    func getSharedConnectedAccountTransactions(plaidAccountId: UUID) async throws -> SharedConnectedAccountTransactionsResponse {
        try await post("get-connected-account-transactions", body: PlaidAccountIdRequest(plaidAccountId: plaidAccountId.uuidString))
    }

    func getSharedManualAccountData(manualAccountId: UUID) async throws -> SharedManualAccountDataResponse {
        try await post("get-manual-account-data", body: ManualAccountIdRequest(manualAccountId: manualAccountId.uuidString))
    }

    func getSharedMonthlyPlan(ownerUserId: UUID) async throws -> SharedMonthlyPlanResponse {
        try await post("get-monthly-plan-data", body: OwnerUserIdRequest(ownerUserId: ownerUserId.uuidString))
    }

    func upsertSavingsSummary(_ request: UpsertSavingsSummaryRequest) async throws -> UpsertSavingsSummaryResponse {
        try await post("upsert-savings-summary", body: request)
    }

    func getMonthlySavingsSummary(ownerUserId: UUID) async throws -> SharedMonthlySavingsSummaryResponse {
        try await post("get-monthly-savings-summary", body: OwnerUserIdRequest(ownerUserId: ownerUserId.uuidString))
    }

    func upsertSavedViaTransferSummary(_ request: UpsertSavedViaTransferSummaryRequest) async throws -> UpsertSavedViaTransferSummaryResponse {
        try await post("upsert-saved-via-transfer-summary", body: request)
    }

    func getSavedViaTransferSummary(ownerUserId: UUID) async throws -> SharedSavedViaTransferSummaryResponse {
        try await post("get-saved-via-transfer-summary", body: OwnerUserIdRequest(ownerUserId: ownerUserId.uuidString))
    }

    func upsertDashboardSummary(_ request: UpsertDashboardSummaryRequest) async throws -> UpsertDashboardSummaryResponse {
        try await post("upsert-dashboard-summary", body: request)
    }

    func getDashboardSummary(ownerUserId: UUID) async throws -> SharedDashboardSummaryResponse {
        try await post("get-dashboard-summary", body: OwnerUserIdRequest(ownerUserId: ownerUserId.uuidString))
    }

    func getMyManualAccounts() async throws -> MyManualAccountsResponse {
        try await post("get-my-manual-accounts", body: EmptyRequest())
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        guard let baseURL else {
            throw HouseholdSharingError.notConfigured
        }
        guard let accessToken = try? await accessTokenProvider(), !accessToken.isEmpty else {
            throw HouseholdSharingError.unauthorized
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: urlRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw HouseholdSharingError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw HouseholdSharingError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(HouseholdSharingErrorBody.self, from: data).error) ?? "Unknown error"
            throw HouseholdSharingError.server(status: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }
}
