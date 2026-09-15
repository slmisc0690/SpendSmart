import Foundation
import SwiftData

/// ACCOUNT REGISTER AUTO DEPOSIT — Scott's own explicit request (2026-09-15): once a Connected
/// account's transactions sync and a deposit shows up (e.g. a Wells Fargo paycheck), automatically
/// mirror it into his manual Account Register(s), with no review step. Gated by
/// `BudgetSettings.accountRegisterAutoDepositEnabled`/`accountRegisterAutoDepositAccountIds`
/// (Settings ▸ Accounts), off by default.
///
/// Deliberately built as a thin sweep on top of the EXISTING `RegisterImportService` — the exact
/// same creation/dedup mechanism the user-initiated "Add to Register" flow already uses — rather
/// than a second, parallel deposit-import implementation. An auto-created entry is therefore
/// indistinguishable from one the user imported by hand, and a transaction already manually
/// imported can never be double-counted here (both paths dedup off the same
/// `importedFromTransactionId` scan).
enum AccountRegisterAutoDepositService {
    /// A posted Connected-account transaction counts as a "deposit" for THIS feature's purposes
    /// when `PlaidTransactionImportService.classifyPlaidAmount` classified it `.creditCardPayment`
    /// (Plaid's own sign convention: a negative amount is money coming INTO the account) AND the
    /// account itself is depository (checking/savings), never a credit card — `.creditCardPayment`
    /// is the correct label for a payment credited to an actual credit card, but the identical
    /// negative-amount signature on a depository account is a real deposit (paycheck, refund,
    /// etc.), not a "payment." This does NOT change the Connected transaction's own stored `type`
    /// — only decides whether this separate feature treats it as a deposit worth mirroring.
    ///
    /// Pending transactions are deliberately excluded — a pending amount can still change or merge
    /// into a posted row before it settles (see `PlaidTransactionImportService`'s own
    /// pending-to-posted re-keying), so auto-depositing only once a transaction has posted avoids
    /// ever having to reconcile an auto-created entry after the fact.
    static func isEligibleDeposit(_ transaction: FinanceTransaction, connections: [PlaidConnection]) -> Bool {
        guard transaction.source == .plaid, transaction.type == .creditCardPayment, !transaction.isPending else {
            return false
        }
        guard let accountId = transaction.plaidAccountId else { return false }
        for connection in connections {
            if let cached = connection.cachedBalances?[accountId] {
                return cached.type == "depository"
            }
        }
        return false
    }

    /// Applies the full sweep: for every Account Register listed in
    /// `accountRegisterAutoDepositAccountIds`, creates an entry for every eligible deposit not
    /// already imported. Selecting more than one register means every eligible deposit is mirrored
    /// into EVERY selected register (a deliberate broadcast, not a per-source-account mapping) —
    /// per Scott's own "they can do all or 1 by 1" framing. No-ops entirely (returns 0, touches
    /// nothing) while the master toggle is off or no register is selected. Returns the total number
    /// of entries created, across all destination registers.
    @discardableResult
    static func applyAutoDeposits(
        connections: [PlaidConnection],
        context: ModelContext
    ) throws -> Int {
        let settingsList = try context.fetch(FetchDescriptor<BudgetSettings>())
        guard let settings = settingsList.first, settings.accountRegisterAutoDepositEnabled ?? false else {
            return 0
        }
        let destinationIds = Set(settings.accountRegisterAutoDepositAccountIds ?? [])
        guard !destinationIds.isEmpty else { return 0 }

        let allAccounts = try context.fetch(FetchDescriptor<Account>())
        let destinations = allAccounts.filter { destinationIds.contains($0.id) }
        guard !destinations.isEmpty else { return 0 }

        let allTransactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let alreadyImported = RegisterImportService.alreadyImportedSourceIds(in: allTransactions)
        let eligibleDeposits = allTransactions.filter {
            isEligibleDeposit($0, connections: connections) && !alreadyImported.contains($0.id)
        }
        guard !eligibleDeposits.isEmpty else { return 0 }

        let resolvedType = RegisterImportResolvedType(choice: .deposit, transferDirection: nil)
        var createdCount = 0
        for destination in destinations {
            let created = try RegisterImportService.createEntries(
                for: eligibleDeposits,
                resolvedType: resolvedType,
                destinationAccount: destination,
                transferToNote: nil,
                alreadyImportedSourceIds: alreadyImported,
                context: context
            )
            createdCount += created.count
        }
        return createdCount
    }
}
