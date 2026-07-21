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
struct AccountRelatedOptionsResponse: Decodable, Equatable {
    let householdId: UUID?
    let role: HouseholdRole?
    let status: HouseholdMembershipStatus?
    let secondaryMember: SecondaryMemberDTO?
    let pendingInvitation: PendingInvitationDTO?
    let sharingPermissions: [SharingPermissionDTO]
    let connectedAccounts: [ConnectedAccountShareDTO]
    let manualAccounts: [ManualAccountShareDTO]

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case role
        case status
        case secondaryMember = "secondary_member"
        case pendingInvitation = "pending_invitation"
        case sharingPermissions = "sharing_permissions"
        case connectedAccounts = "connected_accounts"
        case manualAccounts = "manual_accounts"
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
