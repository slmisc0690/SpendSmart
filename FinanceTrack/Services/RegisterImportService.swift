import Foundation
import SwiftData

/// ACTIVITY REGISTER IMPORT — the four user-facing "Add to..." choices Scott picks from when
/// importing one or more connected (Plaid) Activity transactions into a Manual Account register.
/// Deliberately a presentation-layer enum, separate from `TransactionType`: the production
/// manual-register model has no standalone "Withdrawal" case distinct from `.expense` (a plain
/// register withdrawal/purchase/expense are all the same canonical type), so "Transaction" and
/// "Withdrawal" intentionally map to the SAME `TransactionType.expense` — reusing the existing
/// canonical type rather than inventing a new one, per this phase's own "do not invent new sign
/// math" instruction.
enum RegisterImportEntryChoice: String, CaseIterable, Identifiable {
    case deposit
    case transaction
    case withdrawal
    case transfer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deposit: return "Deposit"
        case .transaction: return "Transaction"
        case .withdrawal: return "Withdrawal"
        case .transfer: return "Transfer"
        }
    }

    var subtitle: String {
        switch self {
        case .deposit: return "Money coming in"
        case .transaction: return "Regular transaction / purchase / expense"
        case .withdrawal: return "Money going out"
        case .transfer: return "Money moved between accounts"
        }
    }
}

/// Only relevant when `RegisterImportEntryChoice.transfer` is chosen — a transfer can either
/// increase or decrease the destination register.
enum RegisterImportTransferDirection: String, CaseIterable, Identifiable {
    case deposit
    case withdrawal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deposit: return "Deposit"
        case .withdrawal: return "Withdrawal"
        }
    }

    var subtitle: String {
        switch self {
        case .deposit: return "Money transferred INTO this register"
        case .withdrawal: return "Money transferred OUT OF this register"
        }
    }
}

/// The fully-resolved choice (entry choice + transfer direction, when applicable), and the
/// canonical `TransactionType` it maps to — the ONLY place this mapping is decided, so the review
/// screen and the actual batch-creation code can never disagree with each other.
struct RegisterImportResolvedType {
    let choice: RegisterImportEntryChoice
    let transferDirection: RegisterImportTransferDirection?

    /// Reuses the exact canonical `TransactionType` cases `AddExpenseView`/
    /// `ManualTransactionCreationService` already use for these same concepts — never a new case.
    var transactionType: TransactionType {
        switch choice {
        case .deposit: return .income
        case .transaction, .withdrawal: return .expense
        case .transfer:
            switch transferDirection {
            case .deposit: return .transferDeposit
            case .withdrawal, nil: return .transferWithdrawal
            }
        }
    }

    /// `true` when the resulting entry increases the destination register's balance
    /// (`AccountBalanceManager.applyIncome`); `false` when it decreases it (`applyExpense`) —
    /// reused by both the deterministic review total and the actual batch-creation code so they
    /// can never diverge.
    var increasesBalance: Bool {
        switch transactionType {
        case .income, .transferDeposit: return true
        case .expense, .transferWithdrawal: return false
        case .transfer, .creditCardPayment, .refund, .balanceAdjustment, .transferToSavings: return false
        }
    }
}

/// ACTIVITY REGISTER IMPORT — creates Manual Account register entries FROM selected connected
/// (Plaid) Activity transactions. The connected `FinanceTransaction` rows are NEVER mutated by
/// this service — only new `source: .manual` rows are created, exactly the same shape
/// `AddExpenseView`/`ManualTransactionCreationService` already produce for a hand-entered register
/// transaction, via the same `AccountBalanceManager` calls (never new balance math).
enum RegisterImportService {
    /// Every source transaction id (a connected `FinanceTransaction.id`) that already has a
    /// manual entry pointing to it via `importedFromTransactionId` — used both to badge already-
    /// imported rows in Activity and to block re-selecting them. Scans locally, no query needed
    /// beyond the same `@Query`-backed `transactions` array every other Activity computation uses.
    static func alreadyImportedSourceIds(in transactions: [FinanceTransaction]) -> Set<UUID> {
        Set(transactions.compactMap(\.importedFromTransactionId))
    }

    /// The deterministic review total: the SAME per-transaction amount used at creation time,
    /// signed according to `resolvedType.increasesBalance` — never a separate calculation.
    static func reviewTotal(for sourceTransactions: [FinanceTransaction], resolvedType: RegisterImportResolvedType) -> Decimal {
        let magnitude = sourceTransactions.reduce(Decimal(0)) { $0 + $1.amount }
        return resolvedType.increasesBalance ? magnitude : -magnitude
    }

    enum ImportError: Error {
        case containsAlreadyImportedTransaction
    }

    /// Creates one manual register entry per `sourceTransactions` element, then a single explicit
    /// `context.save()` for the whole batch — the SAME explicit capture-then-restore recovery
    /// pattern `PayBillsView.submit()` already established for a batch of register writes (never
    /// `ModelContext.rollback()`, per that pattern's own documented reasoning). On `save()` failure,
    /// every transaction this call created is deleted and `destinationAccount.currentBalance` is
    /// reset to its captured original value, on this same live context — so the register list and
    /// balance the user is looking at update immediately, with no partial batch, no duplicate rows,
    /// and no stale balance ever visible.
    @discardableResult
    static func createEntries(
        for sourceTransactions: [FinanceTransaction],
        resolvedType: RegisterImportResolvedType,
        destinationAccount: Account,
        transferToNote: String?,
        alreadyImportedSourceIds: Set<UUID>,
        context: ModelContext
    ) throws -> [FinanceTransaction] {
        guard sourceTransactions.allSatisfy({ !alreadyImportedSourceIds.contains($0.id) }) else {
            throw ImportError.containsAlreadyImportedTransaction
        }

        let originalBalance = destinationAccount.currentBalance
        var createdTransactions: [FinanceTransaction] = []

        for source in sourceTransactions {
            let note: String
            if resolvedType.choice == .transfer, let transferToNote, !transferToNote.isEmpty {
                note = "\(source.displayName) — Transfer to: \(transferToNote)"
            } else {
                note = source.displayName
            }

            let entry = FinanceTransaction(
                amount: source.amount,
                date: source.date,
                type: resolvedType.transactionType,
                source: .manual,
                note: note,
                account: destinationAccount,
                category: source.category,
                ownerUserID: destinationAccount.ownerUserID,
                importedFromTransactionId: source.id
            )
            context.insert(entry)

            if resolvedType.increasesBalance {
                AccountBalanceManager.applyIncome(amount: source.amount, to: destinationAccount)
            } else {
                AccountBalanceManager.applyExpense(amount: source.amount, to: destinationAccount)
            }
            createdTransactions.append(entry)
        }

        do {
            try context.save()
            return createdTransactions
        } catch {
            for transaction in createdTransactions {
                context.delete(transaction)
            }
            destinationAccount.currentBalance = originalBalance
            throw error
        }
    }
}
