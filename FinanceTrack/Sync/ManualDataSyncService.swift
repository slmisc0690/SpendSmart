import Foundation

/// The result of one `sync-manual-data` call — which ids the server actually upserted/deleted, so
/// the caller can precisely clear the matching local `PendingCloudDeletion` tombstones (never more
/// than what the server confirmed).
struct ManualDataSyncResult: Decodable, Equatable {
    let syncedAccountIds: [String]
    let syncedTransactionIds: [String]
    let deletedAccountIds: [String]
    let deletedTransactionIds: [String]

    enum CodingKeys: String, CodingKey {
        case syncedAccountIds = "synced_account_ids"
        case syncedTransactionIds = "synced_transaction_ids"
        case deletedAccountIds = "deleted_account_ids"
        case deletedTransactionIds = "deleted_transaction_ids"
    }
}

private struct ManualDataSyncErrorBody: Decodable {
    let error: String
}

enum ManualDataSyncError: Error, Equatable {
    case notConfigured
    case unauthorized
    case invalidResponse
    case server(status: Int, message: String)
}

/// Contract for talking to SpendSmart's own backend about Manual Account/Transaction cloud sync
/// (Phase 5 foundation) — mirrors `PlaidBackendService`'s own shape/security posture exactly (see
/// that protocol's doc comment): never holds a credential beyond the user's own Supabase access
/// token, never talks to anything but `PlaidBackendConfig.baseURL`.
protocol ManualDataSyncService {
    /// Pushes the given accounts/transactions/deletions in one authenticated batch call. Never
    /// throws for a partially-rejected batch (a malformed individual row) — only for a total
    /// failure (network, auth, server error) that means NOTHING in this call was processed; the
    /// server's own per-row rejection reporting is carried in the returned `ManualDataSyncResult`
    /// only implicitly (via which ids are/aren't present in the synced/deleted arrays) since this
    /// phase's foundation has no UI surfacing individual-row sync failures yet.
    func syncManualData(_ request: ManualDataSyncRequest) async throws -> ManualDataSyncResult
}

/// Talks only to `PlaidBackendConfig.baseURL` (the same Supabase project every other backend call
/// in this app uses — not Plaid-specific despite the name; see that type's own doc comment).
struct SupabaseManualDataSyncService: ManualDataSyncService {
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

    func syncManualData(_ request: ManualDataSyncRequest) async throws -> ManualDataSyncResult {
        try await post("sync-manual-data", body: request)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        guard let baseURL else {
            throw ManualDataSyncError.notConfigured
        }
        guard let accessToken = try? await accessTokenProvider(), !accessToken.isEmpty else {
            throw ManualDataSyncError.unauthorized
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: urlRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw ManualDataSyncError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw ManualDataSyncError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ManualDataSyncErrorBody.self, from: data).error) ?? "Unknown error"
            throw ManualDataSyncError.server(status: httpResponse.statusCode, message: message)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}
