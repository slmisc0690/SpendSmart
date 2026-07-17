import Foundation
import Observation

/// Recognizes SpendSmart's one Plaid OAuth Universal Link — `https://plaid.sldevapps.com/spendsmart/plaid/`
/// (see `PLAID_OAUTH_REDIRECT_URI` in `supabase/functions/_shared/plaid.ts`, which this must match
/// byte-for-byte). Hosted on this dedicated subdomain (via Cloudflare), not the root domain, since
/// the root domain lacks a trusted SSL certificate. LinkKit (the installed `plaid-link-ios-spm`
/// 7.0.2 package) exposes no public API for "continuing"/"resuming" a Link session from a URL —
/// verified directly against its installed `.swiftinterface` and Plaid's own current OAuth
/// documentation: the SDK completes the entire OAuth round-trip internally once the app is
/// foregrounded via this registered Universal Link. This type's only job is the boundary decision
/// every app-level URL handler needs regardless: "is this URL ours to silently absorb, or should
/// it fall through to something else" (here, Supabase's own `spendsmart://` auth callback, handled
/// separately in `FinanceTrackApp`).
enum PlaidOAuthReturn {
    static let host = "plaid.sldevapps.com"
    static let path = "/spendsmart/plaid"

    /// True only for `https://plaid.sldevapps.com/spendsmart/plaid` or any path beginning with
    /// `/spendsmart/plaid/` (e.g. Plaid appending its own query parameters or a sub-path) — never
    /// a bare host match, never a different path on the same domain, and never anything but
    /// `https`. Pure and side-effect-free so it is directly unit-testable without LinkKit, UIKit,
    /// or any network/session state.
    static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.host?.lowercased() == host else { return false }
        return url.path == path || url.path.hasPrefix(path + "/")
    }
}

/// A non-sensitive, locally cached snapshot of one connected Plaid account's balance, as of the
/// last successful `sync-balances` response for that account — never a token, never an account or
/// routing number. Exists so the Dashboard can show a balance without ever contacting Plaid itself
/// (see `PlaidConnectionManager.updateCachedBalances`); `ConnectedAccountsView` remains the only
/// place that actually calls `sync-balances` live.
struct CachedPlaidAccountBalance: Codable, Equatable {
    /// Plaid's own `account_id` — stable across syncs, the same identifier
    /// `PlaidAccountBalance.accountId` already carries. Never a Plaid `item_id`/`access_token`.
    let accountId: String
    var name: String?
    var mask: String?
    var type: String?
    var subtype: String?
    var currentBalance: Decimal?
    var availableBalance: Decimal?
    var creditLimit: Decimal?
    var isoCurrencyCode: String?
    var unofficialCurrencyCode: String?
    /// When SpendSmart itself successfully received this balance response — `sync-balances`'s own
    /// response carries no timestamp, so this is always stamped by the app at receipt time, never
    /// fabricated for a balance that hasn't actually been fetched. See
    /// `PlaidConnectionManager.updateCachedBalances`, the only place this is ever set.
    let updatedAt: Date
}

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
    /// Mirrors `plaid_items.pending_disconnect_at` — set once Plaid sends a `PENDING_DISCONNECT`
    /// webhook (this Item is expected to stop working soon). Never causes any automatic action on
    /// this device — same "record only" stance as the backend column it mirrors.
    var pendingDisconnectAt: Date?
    /// Mirrors `plaid_items.new_accounts_available` — set once Plaid sends a
    /// `NEW_ACCOUNTS_AVAILABLE` webhook; cleared the next time this connection is reconnected via
    /// Link update mode (which re-runs account discovery).
    var newAccountsAvailable: Bool
    /// The last successfully retrieved balance for each account this connection covers, keyed by
    /// Plaid's own `account_id` (a single Item/connection can cover more than one physical
    /// account). Only ever set by `PlaidConnectionManager.updateCachedBalances`, called after a
    /// SUCCESSFUL `sync-balances` response — never on failure, so a transient error can never wipe
    /// out a previously-known-good balance. Deliberately `Optional` rather than defaulting to an
    /// empty dictionary: Swift's synthesized `Decodable` treats a missing key for an `Optional`
    /// property as `nil` automatically, so a `PlaidConnection` persisted before this field existed
    /// decodes cleanly with no custom migration logic required.
    var cachedBalances: [String: CachedPlaidAccountBalance]? = nil

    init(
        id: String,
        institutionId: String?,
        institutionName: String,
        lastSyncedAt: Date? = nil,
        requiresReauth: Bool = false,
        pendingExpirationAt: Date? = nil,
        pendingDisconnectAt: Date? = nil,
        newAccountsAvailable: Bool = false,
        cachedBalances: [String: CachedPlaidAccountBalance]? = nil
    ) {
        self.id = id
        self.institutionId = institutionId
        self.institutionName = institutionName
        self.lastSyncedAt = lastSyncedAt
        self.requiresReauth = requiresReauth
        self.pendingExpirationAt = pendingExpirationAt
        self.pendingDisconnectAt = pendingDisconnectAt
        self.newAccountsAvailable = newAccountsAvailable
        self.cachedBalances = cachedBalances
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

    /// Set by `ConnectedAccountsView` while a Plaid Link session (including a native OAuth
    /// hand-off) is actively presented, cleared once it finishes or is dismissed — mirrors that
    /// view's own `isPresentingLink` lifecycle. This is the only signal this manager has for "was
    /// a Link flow actually in progress" when a Plaid OAuth-return Universal Link arrives.
    /// LinkKit completes the OAuth round-trip internally once foregrounded via that link (see
    /// `PlaidOAuthReturn`'s doc comment) — there is no LinkKit API this app calls to "resume" it;
    /// this flag exists solely to detect the one unsafe case below.
    var hasActiveLinkFlow = false

    /// Set once a recognized Plaid OAuth return URL arrives while `hasActiveLinkFlow` is false —
    /// e.g. the link was opened directly, outside of any connection attempt, or the app was
    /// killed mid-flow. `ConnectedAccountsView` reads this to show a calm, actionable recovery
    /// message rather than silently doing nothing. Never causes a crash, never creates a
    /// connection, never touches Supabase auth state.
    private(set) var oauthReturnMissedActiveSession = false

    /// Called from the app's single `.onOpenURL` entry point for any URL already confirmed to
    /// match `PlaidOAuthReturn.matches(_:)`. Intentionally does nothing beyond recording the
    /// no-active-session case — LinkKit's own already-presented session (if any) resolves itself;
    /// there is no forwarding call to make.
    func handlePlaidOAuthReturn() {
        if !hasActiveLinkFlow {
            oauthReturnMissedActiveSession = true
        }
    }

    func acknowledgeOAuthReturnWithoutActiveSession() {
        oauthReturnMissedActiveSession = false
    }

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
        pendingDisconnectAt: Date?,
        newAccountsAvailable: Bool
    ) {
        guard let index = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        connections[index].institutionId = institutionId
        connections[index].institutionName = institutionName
        connections[index].requiresReauth = requiresReauth
        connections[index].pendingExpirationAt = pendingExpirationAt
        connections[index].pendingDisconnectAt = pendingDisconnectAt
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

    /// Clears every stored connection at once — used only for full account deletion (never for
    /// disconnecting a single institution, which must always go through `remove(connectionId:)`
    /// so it can never affect a connection the user didn't ask to remove). Persists immediately
    /// via the same `didSet`-triggered `persist()` every other mutation here already uses.
    func clearAllConnections() {
        connections.removeAll()
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
            let existing = connections.first(where: { $0.id == status.connectionId })
            return PlaidConnection(
                id: status.connectionId,
                institutionId: status.institutionId,
                institutionName: status.institutionName,
                lastSyncedAt: existing?.lastSyncedAt,
                requiresReauth: status.requiresReauth,
                pendingExpirationAt: status.pendingExpirationAt,
                pendingDisconnectAt: status.pendingDisconnectAt,
                newAccountsAvailable: status.newAccountsAvailable,
                // Same reasoning as `lastSyncedAt` just above — the server has no concept of this
                // device's locally cached balances, so a server-authoritative reconcile must
                // preserve whatever was already cached rather than wiping it back to nil.
                cachedBalances: existing?.cachedBalances
            )
        }
    }

    /// Updates the locally cached balance for every account in `balances`, keyed by Plaid's own
    /// `account_id` — called ONLY after `ConnectedAccountsView.refreshBalances` receives a
    /// SUCCESSFUL `sync-balances` response (see that call site). Never called on failure, which is
    /// what actually preserves the previous cached balance across a transient error: this method
    /// simply isn't invoked, rather than containing its own failure-handling branch.
    ///
    /// Merges into whatever this connection already had cached rather than replacing the whole
    /// dictionary — an account this particular call didn't report (e.g. Plaid returned fewer
    /// accounts than a prior call, or a caller passes a partial list) keeps its last known cached
    /// balance instead of being dropped, since a stale-but-real balance is more useful on the
    /// Dashboard than none at all.
    func updateCachedBalances(connectionId: String, balances: [PlaidAccountBalance]) {
        guard let index = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        var updated = connections[index].cachedBalances ?? [:]
        let fetchedAt = Date.now
        for balance in balances {
            updated[balance.accountId] = CachedPlaidAccountBalance(
                accountId: balance.accountId,
                name: balance.name,
                mask: balance.mask,
                type: balance.type,
                subtype: balance.subtype,
                currentBalance: balance.currentBalance,
                availableBalance: balance.availableBalance,
                creditLimit: balance.creditLimit,
                isoCurrencyCode: balance.isoCurrencyCode,
                unofficialCurrencyCode: balance.unofficialCurrencyCode,
                updatedAt: fetchedAt
            )
        }
        connections[index].cachedBalances = updated
    }
}
