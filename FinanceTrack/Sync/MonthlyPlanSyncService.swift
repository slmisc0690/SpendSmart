import Foundation

/// The result of one `sync-monthly-plan-data` call — which ids the server actually
/// upserted/deleted, so the caller can precisely clear the matching local `PendingCloudDeletion`
/// tombstones. Mirrors `ManualDataSyncResult`'s exact shape/reasoning (Phase 5).
struct MonthlyPlanSyncResult: Decodable, Equatable {
    let settingsSynced: Bool
    let syncedIncomeSourceIds: [String]
    let syncedRecurringExpenseIds: [String]
    let deletedIncomeSourceIds: [String]
    let deletedRecurringExpenseIds: [String]

    enum CodingKeys: String, CodingKey {
        case settingsSynced = "settings_synced"
        case syncedIncomeSourceIds = "synced_income_source_ids"
        case syncedRecurringExpenseIds = "synced_recurring_expense_ids"
        case deletedIncomeSourceIds = "deleted_income_source_ids"
        case deletedRecurringExpenseIds = "deleted_recurring_expense_ids"
    }
}

enum MonthlyPlanSyncError: Error, Equatable {
    case notConfigured
    case unauthorized
    case invalidResponse
    case server(status: Int, message: String)
}

/// Contract for talking to SpendSmart's own backend about Monthly Plan cloud sync (Phase 6
/// foundation) — mirrors `ManualDataSyncService`'s exact shape/security posture (Phase 5).
protocol MonthlyPlanSyncService {
    /// Pushes the given settings/income sources/recurring expenses/deletions in one authenticated
    /// batch call. Never throws for a partially-rejected batch (a malformed individual row) — only
    /// for a total failure (network, auth, server error).
    func syncMonthlyPlanData(_ request: MonthlyPlanSyncRequest) async throws -> MonthlyPlanSyncResult
}

private struct MonthlyPlanSyncErrorBody: Decodable {
    let error: String
}

/// Talks only to `PlaidBackendConfig.baseURL` (the same Supabase project every other backend call
/// in this app uses).
struct SupabaseMonthlyPlanSyncService: MonthlyPlanSyncService {
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

    func syncMonthlyPlanData(_ request: MonthlyPlanSyncRequest) async throws -> MonthlyPlanSyncResult {
        try await post("sync-monthly-plan-data", body: request)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        guard let baseURL else {
            throw MonthlyPlanSyncError.notConfigured
        }
        guard let accessToken = try? await accessTokenProvider(), !accessToken.isEmpty else {
            throw MonthlyPlanSyncError.unauthorized
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: urlRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw MonthlyPlanSyncError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw MonthlyPlanSyncError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(MonthlyPlanSyncErrorBody.self, from: data).error) ?? "Unknown error"
            throw MonthlyPlanSyncError.server(status: httpResponse.statusCode, message: message)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}
