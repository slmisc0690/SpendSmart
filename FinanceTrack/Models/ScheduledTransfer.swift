import Foundation
import SwiftData

/// A recurring transfer the user sets up once (e.g. "$25, Checking to Savings, every Mid-Month")
/// instead of re-entering it by hand every cycle — Scott's own explicit request. Either side can
/// be a Manual Account OR a Connected/Plaid account (Scott's own real setup: a Manual Checking
/// register paired with his real, Plaid-synced Savings account) — mirroring exactly how
/// `FinanceTransaction.account`/`transferCounterpartyAccount`/`transferCounterpartyPlaidAccountId`
/// already splits "a real local Manual Account" from "a Connected account, reference tag only, no
/// local balance to mutate" for a single manual transfer entry. AT LEAST ONE side must be Manual —
/// there is no local account object at all for a Connected account, so a Connected-to-Connected
/// schedule would have nothing to post a transaction against or mutate; the add/edit UI enforces
/// this (see `AddEditScheduledTransferView.validationMessages`).
///
/// POSTING MODEL — there is no background-task/push infrastructure anywhere in this app (verified
/// by direct audit), so this can only ever be checked when the app is actually open
/// (`ScheduledTransferPostingService`, called the same way `DashboardView` already checks for
/// synced Plaid transactions on launch/foreground). `lastPostedMonth` is the idempotency marker —
/// the first-of-month `Date` this schedule was last successfully posted for — so a schedule posts
/// AT MOST once per calendar month regardless of how many times the app opens that month, and a
/// missed month (app not opened on/after the scheduled day) still posts, dated the scheduled day
/// itself, the next time the app opens — per Scott's own explicit choice, never silently skipped
/// and never dated "whenever you happened to check."
@Model
final class ScheduledTransfer {
    var id: UUID
    var amount: Decimal
    /// Restricted to `.beginningMonth`/`.midMonth`/`.endMonth` by the add/edit UI — `.weekly`/
    /// `.customDate` exist on the shared `PlanTiming` enum for `RecurringExpense`'s own use but
    /// have no meaning here.
    var timing: PlanTiming
    /// Mutually exclusive with `sourceConnectedAccountId` — exactly one of the two is set once a
    /// schedule is fully configured.
    var sourceAccount: Account?
    /// Plaid's own `account_id` for a Connected source — resolved to a display label/subtype
    /// live via `ConnectedAccountOptionPresenter` (never persisted here, so a renamed/re-masked
    /// Connected account is always shown current).
    var sourceConnectedAccountId: String?
    /// Mutually exclusive with `destinationConnectedAccountId`.
    var destinationAccount: Account?
    var destinationConnectedAccountId: String?
    var isActive: Bool
    var note: String
    var createdAt: Date
    var updatedAt: Date
    /// The first-of-month `Date` (in the CURRENT device calendar/timezone at the time of posting)
    /// this schedule last successfully created a transfer for — `nil` means never posted.
    var lastPostedMonth: Date?
    /// The Supabase auth user UUID that locally owns this row — same optional-in-this-phase
    /// convention as every other model `UserDataStoreManager` isolates per user (see
    /// `RecurringExpense.ownerUserID`'s own header).
    var ownerUserID: UUID?

    init(
        id: UUID = UUID(),
        amount: Decimal,
        timing: PlanTiming = .beginningMonth,
        sourceAccount: Account? = nil,
        sourceConnectedAccountId: String? = nil,
        destinationAccount: Account? = nil,
        destinationConnectedAccountId: String? = nil,
        isActive: Bool = true,
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastPostedMonth: Date? = nil,
        ownerUserID: UUID? = nil
    ) {
        self.id = id
        self.amount = amount
        self.timing = timing
        self.sourceAccount = sourceAccount
        self.sourceConnectedAccountId = sourceConnectedAccountId
        self.destinationAccount = destinationAccount
        self.destinationConnectedAccountId = destinationConnectedAccountId
        self.isActive = isActive
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPostedMonth = lastPostedMonth
        self.ownerUserID = ownerUserID
    }
}
