import Foundation

/// Request/response wire types for PHASE 7's four sharing-controls Edge Functions
/// (initialize-household, get-account-related-options, manage-household-invitation,
/// update-sharing-permission). Mirrors `MonthlyPlanSyncPayload`'s exact shape/naming convention —
/// snake_case `CodingKeys` matching the Edge Functions' own JSON verbatim, money/date fields
/// passed through as their natural JSON types since none of these payloads carry money values.

/// Role/membership status for the CALLER only — never trusted as authorization on its own; every
/// server write independently re-verifies Primary status. Used purely to drive UI visibility.
enum HouseholdRole: String, Decodable {
    case primary
    case secondary
}

enum HouseholdMembershipStatus: String, Decodable {
    case active
    case removed
}

/// Decodes a required `updated_at` timestamptz string as Postgres/PostgREST actually serializes
/// it (e.g. `to_json(timestamptz)`) — `"2026-07-11T09:34:56.234+00:00"`, WITH fractional seconds.
/// `JSONDecoder.dateDecodingStrategy = .iso8601` (this file's ambient strategy, set by
/// `SupabaseHouseholdSharingService.post`) uses a plain `ISO8601DateFormatter` with no
/// `.withFractionalSeconds` option, which cannot parse that string and throws — silently aborting
/// the ENTIRE response decode for any type with a required `Date` field fed by a `timestamptz`
/// column. Tries fractional-seconds first (the actual live format), then falls back to
/// non-fractional for robustness, and only THEN throws — never fabricates a `Date()`/epoch
/// fallback, so an actually-invalid timestamp still fails decoding exactly as before.
enum SharedTimestampDecoding {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func decode<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> Date {
        let string = try container.decode(String.self, forKey: key)
        if let date = date(from: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\"\(string)\" is not a valid ISO8601 timestamp")
    }

    /// PHASE B ACTIVITY REGRESSION FIX — migration 0017's `pa.updated_at::text` cast (needed for
    /// the numeric-adjacent fields to share one consistent encoding, see that migration's own
    /// header) produces Postgres's own default text format for `timestamptz`
    /// (`"2026-07-24 11:03:59.452775+00"` — space-separated, short `+00` offset), NOT the ISO8601
    /// format `to_jsonb`/PostgREST auto-serialization produces elsewhere in this app
    /// (`"2026-07-24T11:03:59.452775+00:00"`). `ISO8601DateFormatter` rejects the former outright,
    /// which previously threw out of `SharedConnectedAccountDTO`'s decoder, failing the ENTIRE
    /// `connected_accounts` array decode, which failed the ENTIRE `AccountRelatedOptionsResponse`
    /// decode — the confirmed root cause of shared Connected Accounts disappearing from both
    /// Dashboard and Activity after migration 0017 shipped. `normalized(_:)` converts the
    /// Postgres-default shape into an ISO8601-parseable one; a string that's already ISO8601
    /// passes through unchanged (no space to replace, offset already has a colon or is `Z`).
    private static func normalized(_ string: String) -> String {
        var result = string
        if let spaceIndex = result.firstIndex(of: " ") {
            result.replaceSubrange(spaceIndex...spaceIndex, with: "T")
        }
        // A trailing short offset like "+00"/"-05" (exactly 2 digits, no minutes, no colon)
        // needs ":00" appended — ISO8601DateFormatter requires the full "+HH:MM" form. Only the
        // LAST +/- after the time portion is the offset (a date's own "-" separators come first),
        // so search from the end.
        if !result.hasSuffix("Z"),
           let offsetSignIndex = result.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let offset = result[result.index(after: offsetSignIndex)...]
            if offset.count == 2, offset.allSatisfy(\.isNumber) {
                result += ":00"
            }
        }
        return result
    }

    private static func date(from string: String) -> Date? {
        if let date = withFractionalSeconds.date(from: string) ?? withoutFractionalSeconds.date(from: string) {
            return date
        }
        let normalizedString = normalized(string)
        guard normalizedString != string else { return nil }
        return withFractionalSeconds.date(from: normalizedString) ?? withoutFractionalSeconds.date(from: normalizedString)
    }
}

struct SecondaryMemberDTO: Decodable, Equatable {
    let userId: UUID
    let email: String?
    let status: String
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case status
        case joinedAt = "joined_at"
    }
}

struct PendingInvitationDTO: Decodable, Equatable {
    let id: UUID
    let invitedEmail: String
    let status: String
    let expiresAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case invitedEmail = "invited_email"
        case status
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

struct SharingPermissionDTO: Decodable, Equatable {
    let category: String
    let itemId: UUID?
    let isShared: Bool

    enum CodingKeys: String, CodingKey {
        case category
        case itemId = "item_id"
        case isShared = "is_shared"
    }
}

struct ConnectedAccountShareDTO: Decodable, Equatable, Identifiable {
    let plaidAccountId: UUID
    let accountId: String
    let name: String?
    let mask: String?

    var id: UUID { plaidAccountId }

    enum CodingKeys: String, CodingKey {
        case plaidAccountId = "plaid_account_id"
        case accountId = "account_id"
        case name
        case mask
    }
}

struct ManualAccountShareDTO: Decodable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let accountType: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case accountType = "account_type"
    }
}

/// Response of both `initialize-household` and the minimal (non-Primary) shape of
/// `get-account-related-options`.
struct HouseholdStateResponse: Decodable, Equatable {
    let householdId: UUID?
    let role: HouseholdRole?
    let status: HouseholdMembershipStatus?

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case role
        case status
    }
}

/// Full response of `get-account-related-options`.
///
/// PHASE 9 — the four `primary*` fields are present ONLY on the Secondary branch (see migration
/// 0016's `get_secondary_shared_data` and this Edge Function's own Secondary-branch comment) —
/// the Primary branch never includes them at all. Decoded via `decodeIfPresent` with safe
/// defaults (`nil`/`[]`/`false`) rather than a synthesized `Decodable`, so a Primary's response
/// (which omits these keys entirely) still decodes cleanly instead of throwing.
struct AccountRelatedOptionsResponse: Decodable, Equatable {
    let householdId: UUID?
    let role: HouseholdRole?
    let status: HouseholdMembershipStatus?
    let secondaryMember: SecondaryMemberDTO?
    let pendingInvitation: PendingInvitationDTO?
    let sharingPermissions: [SharingPermissionDTO]
    let connectedAccounts: [ConnectedAccountShareDTO]
    let manualAccounts: [ManualAccountShareDTO]
    /// The household's Primary — only ever present for an active Secondary, and only needed to
    /// drive `get-monthly-plan-data`'s `owner_user_id` field (see that endpoint's own contract).
    let primaryUserId: UUID?
    /// Primary-owned Connected Accounts the Primary currently, effectively shares with THIS
    /// Secondary — already scoped server-side by migration 0016's own re-verification against the
    /// canonical `is_effectively_shared_for_user` evaluator; never includes an unshared account.
    let primarySharedConnectedAccounts: [SharedConnectedAccountDTO]
    /// Same as above, for Manual Accounts.
    let primarySharedManualAccounts: [SharedManualAccountDTO]
    /// Whether the Primary's Monthly Plan is currently, effectively shared with this Secondary
    /// (global-only category — see migration 0008's own header).
    let primaryMonthlyPlanShared: Bool
    /// CLIENT UI PHASE — whether the Primary's Monthly Savings aggregate (`monthlySavings`
    /// category, migration 0018) is currently, effectively shared with this Secondary. Evaluated
    /// entirely independently of `primaryMonthlyPlanShared` server-side (see
    /// `get_secondary_shared_data`'s own header) — never derived from it here either.
    let primaryMonthlySavingsShared: Bool

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case role
        case status
        case secondaryMember = "secondary_member"
        case pendingInvitation = "pending_invitation"
        case sharingPermissions = "sharing_permissions"
        case connectedAccounts = "connected_accounts"
        case manualAccounts = "manual_accounts"
        case primaryUserId = "primary_user_id"
        case primarySharedConnectedAccounts = "primary_shared_connected_accounts"
        case primarySharedManualAccounts = "primary_shared_manual_accounts"
        case primaryMonthlyPlanShared = "primary_monthly_plan_shared"
        case primaryMonthlySavingsShared = "primary_monthly_savings_shared"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        householdId = try container.decodeIfPresent(UUID.self, forKey: .householdId)
        role = try container.decodeIfPresent(HouseholdRole.self, forKey: .role)
        status = try container.decodeIfPresent(HouseholdMembershipStatus.self, forKey: .status)
        secondaryMember = try container.decodeIfPresent(SecondaryMemberDTO.self, forKey: .secondaryMember)
        pendingInvitation = try container.decodeIfPresent(PendingInvitationDTO.self, forKey: .pendingInvitation)
        sharingPermissions = try container.decodeIfPresent([SharingPermissionDTO].self, forKey: .sharingPermissions) ?? []
        connectedAccounts = try container.decodeIfPresent([ConnectedAccountShareDTO].self, forKey: .connectedAccounts) ?? []
        manualAccounts = try container.decodeIfPresent([ManualAccountShareDTO].self, forKey: .manualAccounts) ?? []
        primaryUserId = try container.decodeIfPresent(UUID.self, forKey: .primaryUserId)
        primarySharedConnectedAccounts = try container.decodeIfPresent([SharedConnectedAccountDTO].self, forKey: .primarySharedConnectedAccounts) ?? []
        primarySharedManualAccounts = try container.decodeIfPresent([SharedManualAccountDTO].self, forKey: .primarySharedManualAccounts) ?? []
        primaryMonthlyPlanShared = try container.decodeIfPresent(Bool.self, forKey: .primaryMonthlyPlanShared) ?? false
        primaryMonthlySavingsShared = try container.decodeIfPresent(Bool.self, forKey: .primaryMonthlySavingsShared) ?? false
    }

    /// Memberwise initializer — the custom `init(from:)` above (required for the safe-default
    /// decode behavior) suppresses Swift's normally-synthesized one, so tests constructing this
    /// type directly still need one.
    init(
        householdId: UUID?,
        role: HouseholdRole?,
        status: HouseholdMembershipStatus?,
        secondaryMember: SecondaryMemberDTO?,
        pendingInvitation: PendingInvitationDTO?,
        sharingPermissions: [SharingPermissionDTO],
        connectedAccounts: [ConnectedAccountShareDTO],
        manualAccounts: [ManualAccountShareDTO],
        primaryUserId: UUID? = nil,
        primarySharedConnectedAccounts: [SharedConnectedAccountDTO] = [],
        primarySharedManualAccounts: [SharedManualAccountDTO] = [],
        primaryMonthlyPlanShared: Bool = false,
        primaryMonthlySavingsShared: Bool = false
    ) {
        self.householdId = householdId
        self.role = role
        self.status = status
        self.secondaryMember = secondaryMember
        self.pendingInvitation = pendingInvitation
        self.sharingPermissions = sharingPermissions
        self.connectedAccounts = connectedAccounts
        self.manualAccounts = manualAccounts
        self.primaryUserId = primaryUserId
        self.primarySharedConnectedAccounts = primarySharedConnectedAccounts
        self.primarySharedManualAccounts = primarySharedManualAccounts
        self.primaryMonthlyPlanShared = primaryMonthlyPlanShared
        self.primaryMonthlySavingsShared = primaryMonthlySavingsShared
    }
}

// MARK: - Phase 9: Primary-shared discovery metadata

/// A Primary-owned Connected Account the Primary currently shares with the caller (an active
/// Secondary) — see migration 0016's `get_secondary_shared_data`. Carries only safe display
/// metadata, never a Plaid credential/cursor/institution secret.
struct SharedConnectedAccountDTO: Decodable, Equatable, Identifiable {
    let plaidAccountId: UUID
    let name: String?
    let mask: String?
    /// PHASE B PARITY FIX, STEP 1 (migration 0017) — the same non-secret balance/type/timestamp
    /// fields the Primary's own owned-account listing already exposes, added so a Secondary's
    /// Dashboard card can render the same `PlaidBalanceFormatter.rows(for:)` output the Primary's
    /// own card shows. All four `nil` for an account that hasn't been refreshed/synced yet — the
    /// exact same "Balance not refreshed yet" empty state an owned account shows in that case,
    /// never fabricated.
    let currentBalance: Decimal?
    let availableBalance: Decimal?
    let creditLimit: Decimal?
    /// Plaid's own `type` (e.g. `"depository"`, `"credit"`) — drives which balance label
    /// (`PlaidBalanceFormatter`) applies. Raw `String?`, matching `PlaidAccountBalance.type`'s own
    /// "never crash on an unrecognized type" convention.
    let accountType: String?
    let updatedAt: Date?

    var id: UUID { plaidAccountId }

    enum CodingKeys: String, CodingKey {
        case plaidAccountId = "plaid_account_id"
        case name
        case mask
        case currentBalance = "current_balance"
        case availableBalance = "available_balance"
        case creditLimit = "credit_limit"
        case accountType = "type"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plaidAccountId = try container.decode(UUID.self, forKey: .plaidAccountId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        mask = try container.decodeIfPresent(String.self, forKey: .mask)
        currentBalance = try Self.decodeOptionalDecimal(container, forKey: .currentBalance)
        availableBalance = try Self.decodeOptionalDecimal(container, forKey: .availableBalance)
        creditLimit = try Self.decodeOptionalDecimal(container, forKey: .creditLimit)
        accountType = try container.decodeIfPresent(String.self, forKey: .accountType)
        if container.contains(.updatedAt), try !container.decodeNil(forKey: .updatedAt) {
            updatedAt = try SharedTimestampDecoding.decode(container, forKey: .updatedAt)
        } else {
            updatedAt = nil
        }
    }

    private static func decodeOptionalDecimal(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Decimal? {
        guard let string = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let value = Decimal(string: string) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\"\(string)\" is not a valid decimal amount")
        }
        return value
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(
        plaidAccountId: UUID, name: String?, mask: String?,
        currentBalance: Decimal? = nil, availableBalance: Decimal? = nil, creditLimit: Decimal? = nil,
        accountType: String? = nil, updatedAt: Date? = nil
    ) {
        self.plaidAccountId = plaidAccountId
        self.name = name
        self.mask = mask
        self.currentBalance = currentBalance
        self.availableBalance = availableBalance
        self.creditLimit = creditLimit
        self.accountType = accountType
        self.updatedAt = updatedAt
    }
}

/// A Primary-owned Manual Account the Primary currently shares with the caller — see
/// `SharedConnectedAccountDTO`'s own header for the equivalent reasoning.
struct SharedManualAccountDTO: Decodable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let accountType: String

    enum CodingKeys: String, CodingKey {
        case id = "manual_account_id"
        case name
        case accountType = "account_type"
    }
}

/// `manage-household-invitation` request — `action` selects which fields are meaningful; unused
/// fields are simply omitted (nil) rather than sent as empty strings.
struct InvitationActionRequest: Encodable {
    let action: String
    let householdId: String?
    let email: String?
    let invitationId: String?

    enum CodingKeys: String, CodingKey {
        case action
        case householdId = "household_id"
        case email
        case invitationId = "invitation_id"
    }

    static func invite(householdId: UUID, email: String) -> InvitationActionRequest {
        InvitationActionRequest(action: "invite", householdId: householdId.uuidString, email: email, invitationId: nil)
    }

    static func resend(invitationId: UUID) -> InvitationActionRequest {
        InvitationActionRequest(action: "resend", householdId: nil, email: nil, invitationId: invitationId.uuidString)
    }

    static func revoke(invitationId: UUID) -> InvitationActionRequest {
        InvitationActionRequest(action: "revoke", householdId: nil, email: nil, invitationId: invitationId.uuidString)
    }
}

struct InvitationActionResponse: Decodable, Equatable {
    let invitationId: UUID?
    let revoked: Bool?
    /// Present only for `invite`/`resend` — the `spendsmart://household-invitation?token=...`
    /// link the Primary can share with the Secondary via the OS share sheet. See
    /// `manage-household-invitation`'s own header for why this project sends no automated email
    /// yet (no email-provider infrastructure exists).
    let invitationUrl: String?

    enum CodingKeys: String, CodingKey {
        case invitationId = "invitation_id"
        case revoked
        case invitationUrl = "invitation_url"
    }
}

/// `update-sharing-permission` request — `itemId` nil means the GLOBAL row for `category`.
struct SharingPermissionUpdateRequest: Encodable {
    let category: String
    let itemId: String?
    let isShared: Bool

    enum CodingKeys: String, CodingKey {
        case category
        case itemId = "item_id"
        case isShared = "is_shared"
    }
}

struct SharingPermissionUpdateResponse: Decodable, Equatable {
    let sharingPermissionId: UUID

    enum CodingKeys: String, CodingKey {
        case sharingPermissionId = "sharing_permission_id"
    }
}

/// Empty request body — `initialize-household` and `get-account-related-options` take no fields.
struct EmptyRequest: Encodable {}

// MARK: - Phase 8: invitation acceptance

/// `get-household-invitation-preview`/`accept-household-invitation` request — the ONLY input is
/// the raw acceptance token. Neither endpoint accepts a household id, user id, or email from the
/// client; both derive caller identity from the verified session server-side.
struct InvitationTokenRequest: Encodable {
    let token: String
}

/// `found: false` is returned uniformly for "no such invitation" and "invitation exists but isn't
/// addressed to my verified email" — see `preview_household_invitation`'s own header (migration
/// 0014) for why that ambiguity is deliberate, not a gap.
struct InvitationPreviewResponse: Decodable, Equatable {
    let found: Bool
    let status: String?
    let isExpired: Bool?
    let expiresAt: Date?
    let primaryDisplayName: String?
    let invitedEmail: String?

    enum CodingKeys: String, CodingKey {
        case found
        case status
        case isExpired = "is_expired"
        case expiresAt = "expires_at"
        case primaryDisplayName = "primary_display_name"
        case invitedEmail = "invited_email"
    }
}

struct AcceptInvitationResponse: Decodable, Equatable {
    let householdId: UUID
    let role: HouseholdRole
    let status: HouseholdMembershipStatus

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case role
        case status
    }
}

// MARK: - Phase 8D: automatic pending-invitation discovery

/// `accept-household-invitation` request when accepting a SELF-DISCOVERED invitation (from
/// `get-my-pending-household-invitation`) rather than a manually-opened link — see
/// `HouseholdSharingService.acceptInvitation(invitationId:)`'s own doc comment.
struct InvitationIdRequest: Encodable {
    let invitationId: String

    enum CodingKeys: String, CodingKey {
        case invitationId = "invitation_id"
    }
}

/// `get-my-pending-household-invitation` response — no token/hash ever appears here; `found:
/// false` covers "no pending invitation exists" uniformly (there is no wrong-identity case to
/// distinguish, since this endpoint accepts no client-suppliable parameter to query by — see that
/// function's own header).
struct MyPendingInvitationResponse: Decodable, Equatable {
    let found: Bool
    let invitationId: UUID?
    let status: String?
    let isExpired: Bool?
    let expiresAt: Date?
    let primaryDisplayName: String?
    let invitedEmail: String?

    enum CodingKeys: String, CodingKey {
        case found
        case invitationId = "invitation_id"
        case status
        case isExpired = "is_expired"
        case expiresAt = "expires_at"
        case primaryDisplayName = "primary_display_name"
        case invitedEmail = "invited_email"
    }
}

/// `decline-household-invitation` response — PHASE 8D FOLLOW-UP. Mirrors migration 0015's
/// `decline_household_invitation_by_id` return shape exactly; carries no token/hash, matching
/// every other self-discovered-invitation payload in this file.
struct DeclineInvitationResponse: Decodable, Equatable {
    let invitationId: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case invitationId = "invitation_id"
        case status
    }
}

// MARK: - Phase 9: Primary-shared data reads (get-connected-account-transactions /
// get-manual-account-data / get-monthly-plan-data)
//
// These three Edge Functions are UNMODIFIED by Phase 9 — authored in Phases 4/5/6, deployed since
// those phases, and reused as-is. Every money-valued field is sent as a JSON STRING (see each
// function's own source header) — decoded via `Decimal(string:)`, matching this project's
// established convention (see `BackendTransactionDTO.init(from:)`) to avoid the Double round-trip
// that can corrupt exact cent values.

struct PlaidAccountIdRequest: Encodable {
    let plaidAccountId: String
    enum CodingKeys: String, CodingKey { case plaidAccountId = "plaid_account_id" }
}

struct ManualAccountIdRequest: Encodable {
    let manualAccountId: String
    enum CodingKeys: String, CodingKey { case manualAccountId = "manual_account_id" }
}

struct OwnerUserIdRequest: Encodable {
    let ownerUserId: String
    enum CodingKeys: String, CodingKey { case ownerUserId = "owner_user_id" }
}

/// One row from `get_connected_account_transactions` (migration 0010) — never carries
/// `plaid_account_id`/`owner_user_id`, matching that function's own narrow RETURNS TABLE shape.
struct SharedConnectedAccountTransactionDTO: Decodable, Equatable, Identifiable {
    let id: UUID
    let transactionId: String
    let pendingTransactionId: String?
    let originalDescription: String
    let merchantName: String?
    let amount: Decimal
    let authorizedDate: Date?
    let postedDate: Date?
    let transactionDate: Date?
    let isPending: Bool
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case transactionId = "transaction_id"
        case pendingTransactionId = "pending_transaction_id"
        case originalDescription = "original_description"
        case merchantName = "merchant_name"
        case amount
        case authorizedDate = "authorized_date"
        case postedDate = "posted_date"
        case transactionDate = "transaction_date"
        case isPending = "is_pending"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        transactionId = try container.decode(String.self, forKey: .transactionId)
        pendingTransactionId = try container.decodeIfPresent(String.self, forKey: .pendingTransactionId)
        originalDescription = try container.decode(String.self, forKey: .originalDescription)
        merchantName = try container.decodeIfPresent(String.self, forKey: .merchantName)
        amount = try Self.decodeDecimal(container, forKey: .amount)
        authorizedDate = try Self.decodeBareDateIfPresent(container, forKey: .authorizedDate)
        postedDate = try Self.decodeBareDateIfPresent(container, forKey: .postedDate)
        transactionDate = try Self.decodeBareDateIfPresent(container, forKey: .transactionDate)
        isPending = try container.decode(Bool.self, forKey: .isPending)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    private static func decodeDecimal(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Decimal {
        let string = try container.decode(String.self, forKey: key)
        guard let value = Decimal(string: string) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\"\(string)\" is not a valid decimal amount")
        }
        return value
    }

    private static func decodeBareDateIfPresent(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Date? {
        guard let string = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return BackendTransactionDTO.parseBareDate(string)
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(
        id: UUID, transactionId: String, pendingTransactionId: String?, originalDescription: String,
        merchantName: String?, amount: Decimal, authorizedDate: Date?, postedDate: Date?,
        transactionDate: Date?, isPending: Bool, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.transactionId = transactionId
        self.pendingTransactionId = pendingTransactionId
        self.originalDescription = originalDescription
        self.merchantName = merchantName
        self.amount = amount
        self.authorizedDate = authorizedDate
        self.postedDate = postedDate
        self.transactionDate = transactionDate
        self.isPending = isPending
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct SharedConnectedAccountTransactionsResponse: Decodable, Equatable {
    let transactions: [SharedConnectedAccountTransactionDTO]
}

/// One row from `get_manual_account_with_transactions`'s embedded `transactions` array
/// (migration 0011) — never carries `manual_account_id`/`owner_user_id`.
struct SharedManualTransactionDTO: Decodable, Equatable, Identifiable {
    let id: UUID
    let amount: Decimal
    let transactionType: String
    let transactionDate: Date?
    let note: String
    let categoryName: String?
    let isPending: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, amount
        case transactionType = "transaction_type"
        case transactionDate = "transaction_date"
        case note
        case categoryName = "category_name"
        case isPending = "is_pending"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let amountString = try container.decode(String.self, forKey: .amount)
        guard let decodedAmount = Decimal(string: amountString) else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: container, debugDescription: "\"\(amountString)\" is not a valid decimal amount")
        }
        amount = decodedAmount
        transactionType = try container.decode(String.self, forKey: .transactionType)
        if let dateString = try container.decodeIfPresent(String.self, forKey: .transactionDate) {
            transactionDate = BackendTransactionDTO.parseBareDate(dateString)
        } else {
            transactionDate = nil
        }
        note = try container.decode(String.self, forKey: .note)
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName)
        isPending = try container.decode(Bool.self, forKey: .isPending)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(id: UUID, amount: Decimal, transactionType: String, transactionDate: Date?, note: String, categoryName: String?, isPending: Bool, updatedAt: Date) {
        self.id = id
        self.amount = amount
        self.transactionType = transactionType
        self.transactionDate = transactionDate
        self.note = note
        self.categoryName = categoryName
        self.isPending = isPending
        self.updatedAt = updatedAt
    }
}

/// `get-manual-account-data`'s `account` object — never carries `owner_user_id`.
struct SharedManualAccountDetailDTO: Decodable, Equatable {
    let id: UUID
    let name: String
    let accountType: String
    let currentBalance: Decimal?
    let institutionName: String?
    let lastFourDigits: String?
    let showsInRecentActivity: Bool
    let updatedAt: Date
    let transactions: [SharedManualTransactionDTO]

    enum CodingKeys: String, CodingKey {
        case id, name
        case accountType = "account_type"
        case currentBalance = "current_balance"
        case institutionName = "institution_name"
        case lastFourDigits = "last_four_digits"
        case showsInRecentActivity = "shows_in_recent_activity"
        case updatedAt = "updated_at"
        case transactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        accountType = try container.decode(String.self, forKey: .accountType)
        if let balanceString = try container.decodeIfPresent(String.self, forKey: .currentBalance) {
            guard let value = Decimal(string: balanceString) else {
                throw DecodingError.dataCorruptedError(forKey: .currentBalance, in: container, debugDescription: "\"\(balanceString)\" is not a valid decimal amount")
            }
            currentBalance = value
        } else {
            currentBalance = nil
        }
        institutionName = try container.decodeIfPresent(String.self, forKey: .institutionName)
        lastFourDigits = try container.decodeIfPresent(String.self, forKey: .lastFourDigits)
        showsInRecentActivity = try container.decode(Bool.self, forKey: .showsInRecentActivity)
        updatedAt = try SharedTimestampDecoding.decode(container, forKey: .updatedAt)
        transactions = try container.decode([SharedManualTransactionDTO].self, forKey: .transactions)
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(
        id: UUID, name: String, accountType: String, currentBalance: Decimal?, institutionName: String?,
        lastFourDigits: String?, showsInRecentActivity: Bool, updatedAt: Date, transactions: [SharedManualTransactionDTO]
    ) {
        self.id = id
        self.name = name
        self.accountType = accountType
        self.currentBalance = currentBalance
        self.institutionName = institutionName
        self.lastFourDigits = lastFourDigits
        self.showsInRecentActivity = showsInRecentActivity
        self.updatedAt = updatedAt
        self.transactions = transactions
    }
}

/// `found: false`-equivalent — `account: null` covers both "doesn't exist" and "exists but not
/// shared with you" uniformly, matching this project's established anti-enumeration convention.
struct SharedManualAccountDataResponse: Decodable, Equatable {
    let account: SharedManualAccountDetailDTO?
}

/// `get-my-manual-accounts`'s response — ALL of the caller's own Manual Accounts (+ transactions),
/// reusing `SharedManualAccountDetailDTO`/`SharedManualTransactionDTO` unmodified since the wire
/// shape of a single account is identical; only "one account by id" vs. "every account I own"
/// differs, which is a request-shape difference, not a DTO difference. See
/// `HouseholdSharingService.getMyManualAccounts`'s own header for why this endpoint exists.
struct MyManualAccountsResponse: Decodable, Equatable {
    let accounts: [SharedManualAccountDetailDTO]
}

/// One row from `get_monthly_plan_with_sources`'s embedded `income_sources` array.
struct SharedIncomeSourceDTO: Decodable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let amount: Decimal
    let frequency: String
    let isActive: Bool
    let nextPayDate: Date?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, name, amount, frequency
        case isActive = "is_active"
        case nextPayDate = "next_pay_date"
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let amountString = try container.decode(String.self, forKey: .amount)
        guard let decodedAmount = Decimal(string: amountString) else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: container, debugDescription: "\"\(amountString)\" is not a valid decimal amount")
        }
        amount = decodedAmount
        frequency = try container.decode(String.self, forKey: .frequency)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        if let dateString = try container.decodeIfPresent(String.self, forKey: .nextPayDate) {
            nextPayDate = BackendTransactionDTO.parseBareDate(dateString)
        } else {
            nextPayDate = nil
        }
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(id: UUID, name: String, amount: Decimal, frequency: String, isActive: Bool, nextPayDate: Date?, note: String?) {
        self.id = id
        self.name = name
        self.amount = amount
        self.frequency = frequency
        self.isActive = isActive
        self.nextPayDate = nextPayDate
        self.note = note
    }
}

/// One row from `get_monthly_plan_with_sources`'s embedded `recurring_expenses` array.
struct SharedRecurringExpenseDTO: Decodable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let amount: Decimal
    let frequency: String
    let isActive: Bool
    let dueDate: Date?
    let isEssential: Bool
    let categoryName: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, name, amount, frequency
        case isActive = "is_active"
        case dueDate = "due_date"
        case isEssential = "is_essential"
        case categoryName = "category_name"
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let amountString = try container.decode(String.self, forKey: .amount)
        guard let decodedAmount = Decimal(string: amountString) else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: container, debugDescription: "\"\(amountString)\" is not a valid decimal amount")
        }
        amount = decodedAmount
        frequency = try container.decode(String.self, forKey: .frequency)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        if let dateString = try container.decodeIfPresent(String.self, forKey: .dueDate) {
            dueDate = BackendTransactionDTO.parseBareDate(dateString)
        } else {
            dueDate = nil
        }
        isEssential = try container.decode(Bool.self, forKey: .isEssential)
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(
        id: UUID, name: String, amount: Decimal, frequency: String, isActive: Bool,
        dueDate: Date?, isEssential: Bool, categoryName: String?, note: String?
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.frequency = frequency
        self.isActive = isActive
        self.dueDate = dueDate
        self.isEssential = isEssential
        self.categoryName = categoryName
        self.note = note
    }
}

/// `get-monthly-plan-data`'s `plan` object — never carries `owner_user_id`. Deliberately carries
/// only the raw synchronized values, never a recomputed derived figure (estimated income,
/// recommended weekly limit, etc.) — `MonthlyPlanCalculator` operates on this app's own SwiftData
/// `IncomeSource`/`RecurringExpense` models, and feeding another user's data through it would risk
/// exactly the cross-user SwiftData contamination this phase must avoid. The shared Monthly Plan
/// view therefore presents the Primary's own raw goal/buffer/income/expense figures directly.
struct SharedMonthlyPlanDTO: Decodable, Equatable {
    let monthlySavingsGoal: Decimal
    let bufferAmount: Decimal?
    let autoUpdateWeeklyBudgetFromPlan: Bool
    let updatedAt: Date
    let incomeSources: [SharedIncomeSourceDTO]
    let recurringExpenses: [SharedRecurringExpenseDTO]

    enum CodingKeys: String, CodingKey {
        case monthlySavingsGoal = "monthly_savings_goal"
        case bufferAmount = "buffer_amount"
        case autoUpdateWeeklyBudgetFromPlan = "auto_update_weekly_budget_from_plan"
        case updatedAt = "updated_at"
        case incomeSources = "income_sources"
        case recurringExpenses = "recurring_expenses"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let goalString = try container.decode(String.self, forKey: .monthlySavingsGoal)
        guard let goal = Decimal(string: goalString) else {
            throw DecodingError.dataCorruptedError(forKey: .monthlySavingsGoal, in: container, debugDescription: "\"\(goalString)\" is not a valid decimal amount")
        }
        monthlySavingsGoal = goal
        if let bufferString = try container.decodeIfPresent(String.self, forKey: .bufferAmount) {
            guard let value = Decimal(string: bufferString) else {
                throw DecodingError.dataCorruptedError(forKey: .bufferAmount, in: container, debugDescription: "\"\(bufferString)\" is not a valid decimal amount")
            }
            bufferAmount = value
        } else {
            bufferAmount = nil
        }
        autoUpdateWeeklyBudgetFromPlan = try container.decode(Bool.self, forKey: .autoUpdateWeeklyBudgetFromPlan)
        updatedAt = try SharedTimestampDecoding.decode(container, forKey: .updatedAt)
        incomeSources = try container.decode([SharedIncomeSourceDTO].self, forKey: .incomeSources)
        recurringExpenses = try container.decode([SharedRecurringExpenseDTO].self, forKey: .recurringExpenses)
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(
        monthlySavingsGoal: Decimal, bufferAmount: Decimal?, autoUpdateWeeklyBudgetFromPlan: Bool,
        updatedAt: Date, incomeSources: [SharedIncomeSourceDTO], recurringExpenses: [SharedRecurringExpenseDTO]
    ) {
        self.monthlySavingsGoal = monthlySavingsGoal
        self.bufferAmount = bufferAmount
        self.autoUpdateWeeklyBudgetFromPlan = autoUpdateWeeklyBudgetFromPlan
        self.updatedAt = updatedAt
        self.incomeSources = incomeSources
        self.recurringExpenses = recurringExpenses
    }
}

/// `plan: null` covers both "no plan exists" and "exists but not shared with you" uniformly,
/// matching this project's established anti-enumeration convention.
struct SharedMonthlyPlanResponse: Decodable, Equatable {
    let plan: SharedMonthlyPlanDTO?
}

// MARK: - CLIENT UI PHASE: Monthly Savings sharing (migration 0018 / upsert-savings-summary /
// get-monthly-savings-summary)
//
// `SavingsEntry` itself is never uploaded — these two types carry ONLY the two aggregate totals
// this feature's own locked design authorizes (`savedThisMonth`/`totalSavingsToDate`). No entry
// id, no entry date, no Savings Goal ever appears here.

/// `upsert-savings-summary` request — the Primary's own aggregate totals, computed locally via
/// `SavingsCalculator` from this device's own `SavingsEntry` records. Money-as-string, matching
/// this project's universal wire convention.
struct UpsertSavingsSummaryRequest: Encodable {
    let savedThisMonth: String
    let totalSavingsToDate: String

    enum CodingKeys: String, CodingKey {
        case savedThisMonth = "saved_this_month"
        case totalSavingsToDate = "total_savings_to_date"
    }

    init(savedThisMonth: Decimal, totalSavingsToDate: Decimal) {
        self.savedThisMonth = "\(savedThisMonth)"
        self.totalSavingsToDate = "\(totalSavingsToDate)"
    }
}

struct UpsertSavingsSummaryResponse: Decodable, Equatable {
    let ok: Bool
}

/// `get-monthly-savings-summary`'s `summary` object.
struct SharedMonthlySavingsSummaryDTO: Decodable, Equatable {
    let savedThisMonth: Decimal
    let totalSavingsToDate: Decimal
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case savedThisMonth = "saved_this_month"
        case totalSavingsToDate = "total_savings_to_date"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedString = try container.decode(String.self, forKey: .savedThisMonth)
        guard let saved = Decimal(string: savedString) else {
            throw DecodingError.dataCorruptedError(forKey: .savedThisMonth, in: container, debugDescription: "\"\(savedString)\" is not a valid decimal amount")
        }
        savedThisMonth = saved
        let totalString = try container.decode(String.self, forKey: .totalSavingsToDate)
        guard let total = Decimal(string: totalString) else {
            throw DecodingError.dataCorruptedError(forKey: .totalSavingsToDate, in: container, debugDescription: "\"\(totalString)\" is not a valid decimal amount")
        }
        totalSavingsToDate = total
        updatedAt = try SharedTimestampDecoding.decode(container, forKey: .updatedAt)
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(savedThisMonth: Decimal, totalSavingsToDate: Decimal, updatedAt: Date) {
        self.savedThisMonth = savedThisMonth
        self.totalSavingsToDate = totalSavingsToDate
        self.updatedAt = updatedAt
    }
}

/// `summary: null` covers both "not shared" and "no summary exists yet" uniformly, matching
/// `SharedMonthlyPlanResponse`'s own established anti-enumeration convention.
struct SharedMonthlySavingsSummaryResponse: Decodable, Equatable {
    let summary: SharedMonthlySavingsSummaryDTO?
}

// MARK: - USER B DASHBOARD PARITY: authoritative shared Dashboard aggregates (migration 0019 /
// upsert-dashboard-summary / get-dashboard-summary)
//
// Mirrors the Monthly Savings sharing types immediately above byte-for-byte in shape/convention.
// Carries ONLY the five authorized aggregate totals (plus one optional consistency figure) — never
// individual transactions, account identifiers, merchant data, or the local per-transaction
// review/exclusion state that made the prior raw-reconstruction approach (`SharedMonthlyOutlookViewModel`)
// unable to guarantee parity. See `PrimaryDashboardSummarySyncService`'s own header for how the
// Primary computes these numbers (reusing `MonthlyPlanCalculator`/`BudgetCalculator` unchanged,
// over a privacy-filtered transaction subset) before upload.

/// `upsert-dashboard-summary` request — the Primary's own aggregate totals, computed locally via
/// the SAME canonical `MonthlyPlanCalculator`/`BudgetCalculator` formulas the Primary's own
/// Dashboard already uses, over a transaction set already filtered to only explicitly-shared
/// accounts. Money-as-string, matching this project's universal wire convention.
struct UpsertDashboardSummaryRequest: Encodable {
    let actualSpentThisMonth: String
    let monthlySpendRemaining: String
    let weeklySpendingLimit: String
    let actualSpentThisWeek: String
    let weeklyRemaining: String
    let monthlySpendingBudget: String?
    /// USER B MONTHLY OUTLOOK / WEEK-BY-WEEK PARITY (migration 0020) — the Primary's own displayed
    /// Monthly Outlook figures. `monthlyOutlookBudgeted` is `BudgetSettings.monthlyGoal` (the
    /// Monthly Savings Goal), a DIFFERENT concept from `monthlySpendingBudget` above — never
    /// conflated. All nil when the Primary has no Monthly Plan settings yet.
    let monthlyOutlookBudgeted: String?
    let monthlyOutlookActual: String?
    let monthlyOutlookProjectedSavings: String?
    let monthlyOutlookStatus: String?
    /// The Primary's own effective/current `WeeklyPlanComparison` ONLY — never the full
    /// `weeklyComparisons` array. `currentPlanWeekIndex`/`currentPlanWeekNumber` are both nil when
    /// the Primary has no valid current comparison (never defaulted to 0/Week 1).
    let currentPlanWeekIndex: Int?
    let currentPlanWeekNumber: Int?
    let currentPlanWeekStartDate: String?
    let currentPlanWeekEndDate: String?
    let currentPlanWeekRecommended: String?
    let currentPlanWeekActual: String?
    let currentPlanWeekRemaining: String?
    let currentPlanWeekStatus: String?

    enum CodingKeys: String, CodingKey {
        case actualSpentThisMonth = "actual_spent_this_month"
        case monthlySpendRemaining = "monthly_spend_remaining"
        case weeklySpendingLimit = "weekly_spending_limit"
        case actualSpentThisWeek = "actual_spent_this_week"
        case weeklyRemaining = "weekly_remaining"
        case monthlySpendingBudget = "monthly_spending_budget"
        case monthlyOutlookBudgeted = "monthly_outlook_budgeted"
        case monthlyOutlookActual = "monthly_outlook_actual"
        case monthlyOutlookProjectedSavings = "monthly_outlook_projected_savings"
        case monthlyOutlookStatus = "monthly_outlook_status"
        case currentPlanWeekIndex = "current_plan_week_index"
        case currentPlanWeekNumber = "current_plan_week_number"
        case currentPlanWeekStartDate = "current_plan_week_start_date"
        case currentPlanWeekEndDate = "current_plan_week_end_date"
        case currentPlanWeekRecommended = "current_plan_week_recommended"
        case currentPlanWeekActual = "current_plan_week_actual"
        case currentPlanWeekRemaining = "current_plan_week_remaining"
        case currentPlanWeekStatus = "current_plan_week_status"
    }

    init(
        actualSpentThisMonth: Decimal,
        monthlySpendRemaining: Decimal,
        weeklySpendingLimit: Decimal,
        actualSpentThisWeek: Decimal,
        weeklyRemaining: Decimal,
        monthlySpendingBudget: Decimal? = nil,
        monthlyOutlookBudgeted: Decimal? = nil,
        monthlyOutlookActual: Decimal? = nil,
        monthlyOutlookProjectedSavings: Decimal? = nil,
        monthlyOutlookStatus: SpendingStatus? = nil,
        currentPlanWeek: CurrentPlanWeek? = nil
    ) {
        self.actualSpentThisMonth = "\(actualSpentThisMonth)"
        self.monthlySpendRemaining = "\(monthlySpendRemaining)"
        self.weeklySpendingLimit = "\(weeklySpendingLimit)"
        self.actualSpentThisWeek = "\(actualSpentThisWeek)"
        self.weeklyRemaining = "\(weeklyRemaining)"
        self.monthlySpendingBudget = monthlySpendingBudget.map { "\($0)" }
        self.monthlyOutlookBudgeted = monthlyOutlookBudgeted.map { "\($0)" }
        self.monthlyOutlookActual = monthlyOutlookActual.map { "\($0)" }
        self.monthlyOutlookProjectedSavings = monthlyOutlookProjectedSavings.map { "\($0)" }
        self.monthlyOutlookStatus = monthlyOutlookStatus.map(SpendingStatusWireCoding.wireValue)
        self.currentPlanWeekIndex = currentPlanWeek?.index
        self.currentPlanWeekNumber = currentPlanWeek?.number
        self.currentPlanWeekStartDate = currentPlanWeek.map { ManualDataSyncPayloadBuilder.bareDateString(from: $0.startDate, calendar: $0.calendar) }
        self.currentPlanWeekEndDate = currentPlanWeek.map { ManualDataSyncPayloadBuilder.bareDateString(from: $0.endDate, calendar: $0.calendar) }
        self.currentPlanWeekRecommended = currentPlanWeek.map { "\($0.recommended)" }
        self.currentPlanWeekActual = currentPlanWeek.map { "\($0.actual)" }
        self.currentPlanWeekRemaining = currentPlanWeek.map { "\($0.remaining)" }
        self.currentPlanWeekStatus = currentPlanWeek.map { SpendingStatusWireCoding.wireValue($0.status) }
    }

    /// The Primary's own single effective/current `WeeklyPlanComparison`, plus the 1-based week
    /// number/0-based index it occupies within `weeklyComparisons` — everything
    /// `PrimaryDashboardSummarySyncService` needs to upload the current week ONLY, never the full
    /// month's list.
    struct CurrentPlanWeek {
        let index: Int
        let number: Int
        let startDate: Date
        let endDate: Date
        let recommended: Decimal
        let actual: Decimal
        let remaining: Decimal
        let status: SpendingStatus
        /// The SAME calendar the week boundaries were computed with — never re-derived with a
        /// different one, which could shift the date-only wire values by a day.
        let calendar: Calendar
    }
}

/// Wire representation of `SpendingStatus` (`good`/`warning`/`over`) — this enum has no `Codable`
/// conformance of its own (it lives in `Theme.swift`, UI-only), so the mapping lives here, at the
/// one place it crosses the network boundary. Never a duplicated status-classification formula —
/// only a string label for whichever `SpendingStatus` `BudgetCalculator`/`MonthlyPlanCalculator`
/// already computed.
enum SpendingStatusWireCoding {
    static func wireValue(_ status: SpendingStatus) -> String {
        switch status {
        case .good: return "good"
        case .warning: return "warning"
        case .over: return "over"
        }
    }

    static func status(fromWireValue value: String) -> SpendingStatus? {
        switch value {
        case "good": return .good
        case "warning": return .warning
        case "over": return .over
        default: return nil
        }
    }
}

struct UpsertDashboardSummaryResponse: Decodable, Equatable {
    let ok: Bool
}

/// `get-dashboard-summary`'s `summary` object — the SAME meanings as `DashboardView`'s own
/// Primary-side `monthlyPlanSummary.actualSpentThisMonth`/`monthlySpendRemaining`/`weeklyLimit`/
/// `spentThisWeek`, already computed and privacy-filtered on the Primary's device.
struct SharedDashboardSummaryDTO: Decodable, Equatable {
    let actualSpentThisMonth: Decimal
    let monthlySpendRemaining: Decimal
    let weeklySpendingLimit: Decimal
    let actualSpentThisWeek: Decimal
    let weeklyRemaining: Decimal
    let monthlySpendingBudget: Decimal?
    /// USER B MONTHLY OUTLOOK / WEEK-BY-WEEK PARITY (migration 0020) — all nil for a row written
    /// before this migration, or when the Primary had no valid Monthly Outlook/current-week data
    /// to upload. Never backfilled/guessed client-side — see `SharedMonthlyOutlookSection`'s own
    /// "unavailable" fallback for a nil `monthlyOutlookStatus`/`currentPlanWeek`.
    let monthlyOutlookBudgeted: Decimal?
    let monthlyOutlookActual: Decimal?
    let monthlyOutlookProjectedSavings: Decimal?
    let monthlyOutlookStatus: SpendingStatus?
    let currentPlanWeek: CurrentPlanWeek?
    let updatedAt: Date

    /// The Primary's single effective/current week only — never a full month's list. `weekInterval`
    /// is reconstructed from the date-only start/end via the SAME local-midnight bare-date parser
    /// (`BackendTransactionDTO.parseBareDate`) already used for every other bare date in this app,
    /// so it can never be off-by-one from timezone drift.
    struct CurrentPlanWeek: Equatable {
        let index: Int
        let number: Int
        let weekInterval: DateInterval
        let recommended: Decimal
        let actual: Decimal
        let remaining: Decimal
        let status: SpendingStatus
    }

    enum CodingKeys: String, CodingKey {
        case actualSpentThisMonth = "actual_spent_this_month"
        case monthlySpendRemaining = "monthly_spend_remaining"
        case weeklySpendingLimit = "weekly_spending_limit"
        case actualSpentThisWeek = "actual_spent_this_week"
        case weeklyRemaining = "weekly_remaining"
        case monthlySpendingBudget = "monthly_spending_budget"
        case monthlyOutlookBudgeted = "monthly_outlook_budgeted"
        case monthlyOutlookActual = "monthly_outlook_actual"
        case monthlyOutlookProjectedSavings = "monthly_outlook_projected_savings"
        case monthlyOutlookStatus = "monthly_outlook_status"
        case currentPlanWeekIndex = "current_plan_week_index"
        case currentPlanWeekNumber = "current_plan_week_number"
        case currentPlanWeekStartDate = "current_plan_week_start_date"
        case currentPlanWeekEndDate = "current_plan_week_end_date"
        case currentPlanWeekRecommended = "current_plan_week_recommended"
        case currentPlanWeekActual = "current_plan_week_actual"
        case currentPlanWeekRemaining = "current_plan_week_remaining"
        case currentPlanWeekStatus = "current_plan_week_status"
        case updatedAt = "updated_at"
    }

    private static func decodeAmount(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Decimal {
        let string = try container.decode(String.self, forKey: key)
        guard let amount = Decimal(string: string) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\"\(string)\" is not a valid decimal amount")
        }
        return amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actualSpentThisMonth = try Self.decodeAmount(container, forKey: .actualSpentThisMonth)
        monthlySpendRemaining = try Self.decodeAmount(container, forKey: .monthlySpendRemaining)
        weeklySpendingLimit = try Self.decodeAmount(container, forKey: .weeklySpendingLimit)
        actualSpentThisWeek = try Self.decodeAmount(container, forKey: .actualSpentThisWeek)
        weeklyRemaining = try Self.decodeAmount(container, forKey: .weeklyRemaining)
        if let budgetString = try container.decodeIfPresent(String.self, forKey: .monthlySpendingBudget) {
            guard let budget = Decimal(string: budgetString) else {
                throw DecodingError.dataCorruptedError(forKey: .monthlySpendingBudget, in: container, debugDescription: "\"\(budgetString)\" is not a valid decimal amount")
            }
            monthlySpendingBudget = budget
        } else {
            monthlySpendingBudget = nil
        }
        monthlyOutlookBudgeted = try Self.decodeOptionalAmount(container, forKey: .monthlyOutlookBudgeted)
        monthlyOutlookActual = try Self.decodeOptionalAmount(container, forKey: .monthlyOutlookActual)
        monthlyOutlookProjectedSavings = try Self.decodeOptionalAmount(container, forKey: .monthlyOutlookProjectedSavings)
        if let statusString = try container.decodeIfPresent(String.self, forKey: .monthlyOutlookStatus) {
            monthlyOutlookStatus = SpendingStatusWireCoding.status(fromWireValue: statusString)
        } else {
            monthlyOutlookStatus = nil
        }

        // CURRENT PLAN WEEK — every field must be present and internally consistent (a partial
        // week, e.g. a start date with no recommended amount, is treated the same as "unavailable"
        // — never displayed as a half-populated card). Dates are parsed via the SAME
        // local-midnight bare-date parser every other bare date in this app already uses, so a
        // date-only wire value can never shift by a day.
        let weekIndex = try container.decodeIfPresent(Int.self, forKey: .currentPlanWeekIndex)
        let weekNumber = try container.decodeIfPresent(Int.self, forKey: .currentPlanWeekNumber)
        let weekStartString = try container.decodeIfPresent(String.self, forKey: .currentPlanWeekStartDate)
        let weekEndString = try container.decodeIfPresent(String.self, forKey: .currentPlanWeekEndDate)
        let weekRecommended = try Self.decodeOptionalAmount(container, forKey: .currentPlanWeekRecommended)
        let weekActual = try Self.decodeOptionalAmount(container, forKey: .currentPlanWeekActual)
        let weekRemaining = try Self.decodeOptionalAmount(container, forKey: .currentPlanWeekRemaining)
        let weekStatusString = try container.decodeIfPresent(String.self, forKey: .currentPlanWeekStatus)

        if let weekIndex, let weekNumber,
           let weekStartString, let weekStart = BackendTransactionDTO.parseBareDate(weekStartString),
           let weekEndString, let weekEnd = BackendTransactionDTO.parseBareDate(weekEndString),
           let weekRecommended, let weekActual, let weekRemaining,
           let weekStatusString, let weekStatus = SpendingStatusWireCoding.status(fromWireValue: weekStatusString) {
            currentPlanWeek = CurrentPlanWeek(
                index: weekIndex,
                number: weekNumber,
                weekInterval: DateInterval(start: weekStart, end: weekEnd),
                recommended: weekRecommended,
                actual: weekActual,
                remaining: weekRemaining,
                status: weekStatus
            )
        } else {
            currentPlanWeek = nil
        }

        updatedAt = try SharedTimestampDecoding.decode(container, forKey: .updatedAt)
    }

    private static func decodeOptionalAmount(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Decimal? {
        guard let string = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let amount = Decimal(string: string) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\"\(string)\" is not a valid decimal amount")
        }
        return amount
    }

    /// Memberwise initializer for tests — see `AccountRelatedOptionsResponse`'s own identical note.
    init(
        actualSpentThisMonth: Decimal,
        monthlySpendRemaining: Decimal,
        weeklySpendingLimit: Decimal,
        actualSpentThisWeek: Decimal,
        weeklyRemaining: Decimal,
        monthlySpendingBudget: Decimal? = nil,
        monthlyOutlookBudgeted: Decimal? = nil,
        monthlyOutlookActual: Decimal? = nil,
        monthlyOutlookProjectedSavings: Decimal? = nil,
        monthlyOutlookStatus: SpendingStatus? = nil,
        currentPlanWeek: CurrentPlanWeek? = nil,
        updatedAt: Date
    ) {
        self.actualSpentThisMonth = actualSpentThisMonth
        self.monthlySpendRemaining = monthlySpendRemaining
        self.weeklySpendingLimit = weeklySpendingLimit
        self.actualSpentThisWeek = actualSpentThisWeek
        self.weeklyRemaining = weeklyRemaining
        self.monthlySpendingBudget = monthlySpendingBudget
        self.monthlyOutlookBudgeted = monthlyOutlookBudgeted
        self.monthlyOutlookActual = monthlyOutlookActual
        self.monthlyOutlookProjectedSavings = monthlyOutlookProjectedSavings
        self.monthlyOutlookStatus = monthlyOutlookStatus
        self.currentPlanWeek = currentPlanWeek
        self.updatedAt = updatedAt
    }
}

/// `summary: null` covers both "not shared" and "no summary exists yet" uniformly, matching
/// `SharedMonthlySavingsSummaryResponse`'s own established anti-enumeration convention.
struct SharedDashboardSummaryResponse: Decodable, Equatable {
    let summary: SharedDashboardSummaryDTO?
}
