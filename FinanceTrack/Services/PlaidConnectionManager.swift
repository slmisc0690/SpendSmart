import Foundation
import Observation

/// One linked institution's local UI-state snapshot — mirrors a `plaid_items` row's non-sensitive
/// fields. `id` is the row's own opaque UUID (`connection_id` in every backend response), never a
/// Plaid `item_id`/`access_token`, neither of which this device ever holds.
struct PlaidConnection: Codable, Identifiable, Equatable {
    let id: String
    var institutionId: String?
    var institutionName: String
    /// Local-only — the server has no concept of "last synced from this specific device", only
    /// `plaid_items.updated_at` (which also moves on unrelated writes like a webhook flag flip).
    var lastSyncedAt: Date?
    /// Mirrors `plaid_items.requires_reauth`, refreshed from `list-connections` — true once Plaid
    /// has sent an `ITEM_LOGIN_REQUIRED` webhook for this Item. `sync-transactions`/
    /// `sync-balances` also fail fast with this same signal, so this flag can be set either by an
    /// explicit refresh or by a sync attempt that came back 409.
    var requiresReauth: Bool
    /// Mirrors `plaid_items.pending_expiration_at` — set once Plaid sends a `PENDING_EXPIRATION`
    /// webhook (mainly OAuth institutions with a scheduled consent expiry).
    var pendingExpirationAt: Date?
    /// Mirrors `plaid_items.new_accounts_available` — set once Plaid sends a
    /// `NEW_ACCOUNTS_AVAILABLE` webhook; cleared the next time this connection is reconnected via
    /// Link update mode (which re-runs account discovery).
    var newAccountsAvailable: Bool

    init(
        id: String,
        institutionId: String?,
        institutionName: String,
        lastSyncedAt: Date? = nil,
        requiresReauth: Bool = false,
        pendingExpirationAt: Date? = nil,
        newAccountsAvailable: Bool = false
    ) {
        self.id = id
        self.institutionId = institutionId
        self.institutionName = institutionName
        self.lastSyncedAt = lastSyncedAt
        self.requiresReauth = requiresReauth
        self.pendingExpirationAt = pendingExpirationAt
        self.newAccountsAvailable = newAccountsAvailable
    }
}

/// Tracks the local UI state of every linked institution — a household account is no longer
/// assumed to have at most one (see the multi-institution architecture work). Deliberately holds
/// no Plaid secret or access token; those never exist on this device (see `PlaidBackendService`).
/// Persisted to `UserDefaults` as a JSON-encoded array since this is just non-sensitive status
/// metadata, not financial data (which lives in SwiftData) or a credential (which never touches
/// this device at all).
@Observable
final class PlaidConnectionManager {
    private static let connectionsKey = "plaid.connections.v2"

    private let defaults: UserDefaults

    private(set) var connections: [PlaidConnection] {
        didSet { persist() }
    }

    /// Convenience for call sites (e.g. `SettingsView`) that only need "is anything connected at
    /// all" — most call sites should read `connections` directly once they need per-institution
    /// detail.
    var isConnected: Bool { !connections.isEmpty }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.connectionsKey),
           let decoded = try? Self.makeDecoder().decode([PlaidConnection].self, from: data) {
            self.connections = decoded
        } else {
            // No data under the current key yet — either a fresh install, or an existing install
            // still on the pre-multi-institution scalar-key format. `didSet` does not fire for a
            // property set inside its own type's initializer, so this migration persists directly
            // (see its own doc comment) rather than relying on `persist()` running as a side
            // effect of this assignment.
            self.connections = Self.migrateLegacyConnectionIfNeeded(defaults: defaults)
        }
        #if DEBUG
        print("[SpendSmartBuild] connections loaded: \(self.connections.count)")
        #endif
    }

    /// One-time migration from the pre-multi-institution scalar UserDefaults keys
    /// (`"plaid.amex.isConnected"`, `"plaid.amex.connectionId"`, `"plaid.amex.lastSyncedAt"` — the
    /// exact keys the single-connection version of this class used) to the current
    /// `[PlaidConnection]` JSON array. Runs at most once per install: this always writes
    /// `Self.connectionsKey` before returning — even for a user who was never connected, which
    /// persists as an explicit empty array — so `init`'s `defaults.data(forKey:)` check finds a
    /// value on every later launch and this function is never reached again. That presence check
    /// IS the "already migrated" marker; no separate migration-done flag is needed.
    ///
    /// Never fabricates a connection: only migrates one if the OLD `isConnected` flag was true
    /// AND a non-empty connection id was actually stored — anything else (never connected, or the
    /// corrupt partial state the old implementation could theoretically leave behind) becomes an
    /// empty array, never a guessed-at connection.
    private static func migrateLegacyConnectionIfNeeded(defaults: UserDefaults) -> [PlaidConnection] {
        let legacyIsConnectedKey = "plaid.amex.isConnected"
        let legacyConnectionIdKey = "plaid.amex.connectionId"
        let legacyLastSyncedAtKey = "plaid.amex.lastSyncedAt"

        let wasConnected = defaults.bool(forKey: legacyIsConnectedKey)
        let legacyConnectionId = defaults.string(forKey: legacyConnectionIdKey)
        let legacyLastSyncedAt = defaults.object(forKey: legacyLastSyncedAtKey) as? Date

        let migrated: [PlaidConnection]
        if wasConnected, let legacyConnectionId, !legacyConnectionId.isEmpty {
            // The pre-migration implementation only ever supported American Express — naming it
            // here isn't a reintroduced hardcoded assumption, it's the literal historical fact
            // about what this specific stored connection always was. `institutionId` was never
            // captured by the old format, so it stays nil until the next successful sync/refresh
            // (`list-connections`/a reconnect) fills it in from the server.
            migrated = [
                PlaidConnection(
                    id: legacyConnectionId,
                    institutionId: nil,
                    institutionName: "American Express",
                    lastSyncedAt: legacyLastSyncedAt
                )
            ]
        } else {
            migrated = []
        }

        // Persist the NEW representation FIRST, and only remove the OLD keys once that succeeds —
        // if encoding somehow failed, the old keys are left in place so this same migration is
        // retried on the next launch instead of silently losing the user's connection state.
        if let data = try? Self.makeEncoder().encode(migrated) {
            defaults.set(data, forKey: Self.connectionsKey)
            defaults.removeObject(forKey: legacyIsConnectedKey)
            defaults.removeObject(forKey: legacyConnectionIdKey)
            defaults.removeObject(forKey: legacyLastSyncedAtKey)
        }

        #if DEBUG
        print("[SpendSmartBuild] legacy migration ran: \(wasConnected), migrated connections: \(migrated.count)")
        #endif

        return migrated
    }

    private func persist() {
        guard let data = try? Self.makeEncoder().encode(connections) else { return }
        defaults.set(data, forKey: Self.connectionsKey)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Adds a newly-connected institution, or replaces an existing entry with the same
    /// `connectionId` (a Link update-mode reconnect reuses the same `connection_id` — it never
    /// creates a new `plaid_items` row). Deliberately does NOT touch `lastSyncedAt` on an update —
    /// callers must call `markSynced(connectionId:)` separately, and only after a sync's results
    /// have actually been persisted to SwiftData, so "last synced" never claims success for a
    /// sync whose transactions never made it into the database.
    func addOrUpdate(connectionId: String, institutionId: String?, institutionName: String) {
        if let index = connections.firstIndex(where: { $0.id == connectionId }) {
            connections[index].institutionId = institutionId
            connections[index].institutionName = institutionName
            // A successful (re)connection means Plaid just accepted fresh credentials — any prior
            // reauth/new-accounts flag is now stale.
            connections[index].requiresReauth = false
            connections[index].newAccountsAvailable = false
        } else {
            connections.append(
                PlaidConnection(id: connectionId, institutionId: institutionId, institutionName: institutionName)
            )
        }
    }

    func markSynced(connectionId: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        connections[index].lastSyncedAt = .now
    }

    /// Applies server-reported state (from `list-connections`) — the only way this device learns
    /// about a webhook-driven flag flip it didn't itself trigger (e.g. Plaid sent
    /// `ITEM_LOGIN_REQUIRED` while the app wasn't running). Never touches `lastSyncedAt`, which
    /// has no server-side equivalent.
    func applyServerState(
        connectionId: String,
        institutionId: String?,
        institutionName: String,
        requiresReauth: Bool,
        pendingExpirationAt: Date?,
        newAccountsAvailable: Bool
    ) {
        guard let index = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        connections[index].institutionId = institutionId
        connections[index].institutionName = institutionName
        connections[index].requiresReauth = requiresReauth
        connections[index].pendingExpirationAt = pendingExpirationAt
        connections[index].newAccountsAvailable = newAccountsAvailable
    }

    /// A sync attempt (`sync-transactions`/`sync-balances`) came back 409 `requires_reauth` —
    /// cheaper than a full `list-connections` round-trip when a sync already told us directly.
    func markRequiresReauth(connectionId: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        connections[index].requiresReauth = true
    }

    func remove(connectionId: String) {
        connections.removeAll { $0.id == connectionId }
    }

    /// Reconciles the local connection list against a SUCCESSFUL `list-connections` response —
    /// the only way this device can recover a connection it never locally recorded (e.g. the
    /// server-side Item was established through a different device/session, so this device has
    /// no legacy or v2 UserDefaults state for it at all). The server response is treated as
    /// authoritative: every server-known connection is inserted (if locally absent) or updated
    /// (if already present, preserving that connection's local `lastSyncedAt` — the server has
    /// no equivalent field), and any local connection NOT present in the response is dropped as
    /// stale. Callers must only invoke this after a successful request; on failure, existing
    /// local state must be left untouched by simply not calling this at all.
    func restoreFromServer(_ statuses: [PlaidConnectionStatus]) {
        connections = statuses.map { status in
            let existingLastSyncedAt = connections.first(where: { $0.id == status.connectionId })?.lastSyncedAt
            return PlaidConnection(
                id: status.connectionId,
                institutionId: status.institutionId,
                institutionName: status.institutionName,
                lastSyncedAt: existingLastSyncedAt,
                requiresReauth: status.requiresReauth,
                pendingExpirationAt: status.pendingExpirationAt,
                newAccountsAvailable: status.newAccountsAvailable
            )
        }
    }
}
