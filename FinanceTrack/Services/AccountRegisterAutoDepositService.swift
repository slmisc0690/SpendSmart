import Foundation
import SwiftData

/// ACCOUNT REGISTER AUTO DEPOSIT — Scott's own explicit request (2026-09-15). Detects a posted
/// Connected-account deposit (e.g. a Wells Fargo paycheck) and offers to mirror it into his manual
/// Account Register(s). Gated by `BudgetSettings.accountRegisterAutoDepositEnabled`/
/// `accountRegisterAutoDepositAccountIds` (Settings ▸ Accounts), off by default.
///
/// REVIEW STEP (revised 2026-09-15, replacing an initial "post immediately, no review" design):
/// Scott's own concrete scenario is why — he transfers $100 from Savings to Checking BY HAND inside
/// the app (a manual register entry, both balances already updated), and separately, because that's
/// a real bank transfer, Plaid's own sync later reports that same $100 landing in Checking as an
/// ordinary deposit. Nothing about that Plaid transaction distinguishes it from a genuine external
/// deposit (a paycheck looks identical to a self-transfer once it posts), so silently auto-creating
/// a register entry for it would double-count money already recorded by hand. Posting immediately
/// can never resolve this — only a human can say "I already accounted for this one." So this
/// service NEVER creates a register entry unattended: it only computes which eligible deposits are
/// still awaiting a decision (`pendingDeposits`), and `confirmDeposits` applies exactly the choice
/// the user made in `AccountRegisterDepositReviewView`. Every eligible deposit is marked reviewed
/// the moment it's shown, whether the user includes it or not, so it is never asked about twice.
///
/// Deliberately built as a thin layer on top of the EXISTING `RegisterImportService` — the exact
/// same creation/dedup mechanism the user-initiated "Add to Register" flow already uses — rather
/// than a second, parallel deposit-import implementation. A confirmed deposit is therefore
/// indistinguishable from one the user imported by hand, and a transaction already manually
/// imported can never be offered for review at all (both paths dedup off the same
/// `importedFromTransactionId` scan).
enum AccountRegisterAutoDepositService {
    /// A posted Connected-account transaction counts as a "deposit" for THIS feature's purposes
    /// when `PlaidTransactionImportService.classifyPlaidAmount` classified it `.creditCardPayment`
    /// (Plaid's own sign convention: a negative amount is money coming INTO the account) AND the
    /// account itself is depository (checking/savings), never a credit card — `.creditCardPayment`
    /// is the correct label for a payment credited to an actual credit card, but the identical
    /// negative-amount signature on a depository account is a real deposit (paycheck, refund,
    /// etc.), not a "payment." This does NOT change the Connected transaction's own stored `type`
    /// — only decides whether this separate feature treats it as a deposit worth reviewing.
    ///
    /// Pending transactions are deliberately excluded — a pending amount can still change or merge
    /// into a posted row before it settles (see `PlaidTransactionImportService`'s own
    /// pending-to-posted re-keying), so a deposit is only ever offered for review once it's posted,
    /// avoiding ever having to reconcile an already-confirmed entry after the fact.
    /// `enabledAt` is the DATE FLOOR — see `BudgetSettings.accountRegisterAutoDepositEnabledAt`'s
    /// own header for the real incident that made this mandatory: without it, this check matched
    /// every eligible deposit ever, going back through an account's FULL history. `nil` means "the
    /// feature hasn't actually been turned on with a recorded start time yet" and is treated as
    /// "nothing is eligible" — the safe direction — never as "no floor."
    static func isEligibleDeposit(_ transaction: FinanceTransaction, connections: [PlaidConnection], enabledAt: Date?) -> Bool {
        guard transaction.source == .plaid, transaction.type == .creditCardPayment, !transaction.isPending else {
            return false
        }
        guard let enabledAt, transaction.date >= enabledAt else { return false }
        guard let accountId = transaction.plaidAccountId else { return false }
        for connection in connections {
            if let cached = connection.cachedBalances?[accountId] {
                return cached.type == "depository"
            }
        }
        return false
    }

    /// Every eligible deposit still awaiting a decision — never already manually imported (via
    /// `RegisterImportService`'s own dedup) and never already shown in a prior review (via
    /// `BudgetSettings.accountRegisterAutoDepositReviewedTransactionIds`). Empty whenever the
    /// master toggle is off or no destination register is selected — there's nothing to review if
    /// there's nowhere configured to put it.
    static func pendingDeposits(
        allTransactions: [FinanceTransaction],
        connections: [PlaidConnection],
        settings: BudgetSettings?
    ) -> [FinanceTransaction] {
        guard let settings, settings.accountRegisterAutoDepositEnabled ?? false else { return [] }
        guard !(settings.accountRegisterAutoDepositAccountIds ?? []).isEmpty else { return [] }
        let alreadyImported = RegisterImportService.alreadyImportedSourceIds(in: allTransactions)
        let alreadyReviewed = Set(settings.accountRegisterAutoDepositReviewedTransactionIds ?? [])
        let enabledAt = settings.accountRegisterAutoDepositEnabledAt
        return allTransactions.filter {
            isEligibleDeposit($0, connections: connections, enabledAt: enabledAt)
                && !alreadyImported.contains($0.id)
                && !alreadyReviewed.contains($0.id)
        }
    }

    /// Applies the user's reviewed decision: creates a register entry (in every selected
    /// destination — selecting more than one broadcasts the SAME deposit into every selected
    /// register, a deliberate choice, never a per-source-account mapping) for exactly the
    /// transactions in `included`, then marks EVERY transaction in `shown` — included or not — as
    /// reviewed, so nothing shown in this pass is ever asked about again. `shown` must be a
    /// superset of `included`.
    @discardableResult
    static func confirmDeposits(
        shown: [FinanceTransaction],
        included: [FinanceTransaction],
        destinations: [Account],
        settings: BudgetSettings,
        context: ModelContext
    ) throws -> Int {
        var createdCount = 0
        if !included.isEmpty, !destinations.isEmpty {
            let allTransactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
            let alreadyImported = RegisterImportService.alreadyImportedSourceIds(in: allTransactions)
            let resolvedType = RegisterImportResolvedType(choice: .deposit, transferDirection: nil)
            for destination in destinations {
                let created = try RegisterImportService.createEntries(
                    for: included,
                    resolvedType: resolvedType,
                    destinationAccount: destination,
                    transferToNote: nil,
                    alreadyImportedSourceIds: alreadyImported,
                    context: context
                )
                createdCount += created.count
            }
        }
        var reviewed = Set(settings.accountRegisterAutoDepositReviewedTransactionIds ?? [])
        reviewed.formUnion(shown.map(\.id))
        settings.accountRegisterAutoDepositReviewedTransactionIds = Array(reviewed)
        settings.updatedAt = .now
        return createdCount
    }
}
