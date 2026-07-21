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
