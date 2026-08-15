import Foundation
import SwiftData

/// "Restore Missing Transactions from CSV" — reads back a file `TransactionCSVExportService`
/// itself produced and adds ONLY the transactions that are missing from the current store. This
/// is a MERGE, never a replace: existing transactions (whether from before or after the CSV was
/// exported) are never touched, never overwritten, never deleted. See the three-stage pipeline
/// below (`parse` → `preview` → `restore`) for how that guarantee is enforced structurally, not
/// just by convention.
///
/// IDENTITY: `TransactionCSVExportService` exports `FinanceTransaction.id` itself as the
/// "Transaction ID" column — the one stable, collision-proof identity this import uses to decide
/// "already present" vs. "missing." A row whose Transaction ID is missing or not a valid UUID is
/// rejected as malformed rather than guessed from date+amount+description, which two entirely
/// legitimate transactions can share (same amount, same day, same merchant, same account).
///
/// RESTORABLE SCOPE: only `.expense`/`.refund`/`.income` rows are restorable. `.transfer` and
/// `.creditCardPayment` both require a `transferDestinationAccount` relationship the CSV does not
/// capture (no destination-account column exists), and `.balanceAdjustment` stores an ABSOLUTE
/// target balance, not a delta the CSV's signed amount can safely reconstruct — inventing either
/// would risk applying a wrong/partial balance effect, so these three types are reported as
/// "not restorable" per row rather than guessed. This mirrors the same “stop and report rather
/// than invent unsafe matching” instruction that governs account-name resolution below.
///
/// ACCOUNT RECONNECTION: the CSV's account "section header" is the account's plain `name` (no
/// stable account ID column exists) — resolved against the CURRENT user's own accounts by exact
/// name match. Zero or multiple accounts sharing that name make the row's account relationship
/// unrecoverable, so it's skipped with a reported reason rather than attached to a guessed
/// account.
///
/// BALANCE RESTORATION: only for `.manual`-sourced rows — applied through the SAME
/// `AccountBalanceManager` delta methods (`applyExpense`/`applyRefund`/`applyIncome`) every other
/// manual entry point in this app already uses, never a new independent formula. `.plaid`-sourced
/// rows NEVER touch `Account.currentBalance` at all: this app's connected-account balances are
/// refreshed directly from Plaid's own `/accounts/get` response (see `PlaidConnectionManager`'s
/// per-account refresh), never derived by summing local transactions — touching balance for a
/// restored connected transaction would be inventing behavior this app has never had.
///
/// PLAID DUPLICATE PROTECTION: a restored `.plaid`-sourced row keeps its original
/// `externalTransactionId` exactly as exported. `PlaidTransactionImportService.applySync`'s own
/// dedupe key is `externalTransactionId` (see its own header) — so a LATER real Plaid sync for
/// the same bank transaction finds the restored row already present under that same key and
/// updates it in place rather than inserting a duplicate. This is Option A from this task's own
/// investigation checklist, made safe specifically because identity is preserved exactly, not
/// guessed.
enum TransactionCSVImportService {
    // MARK: - Parsed row

    /// One syntactically valid, structurally supported CSV data row, before comparison against
    /// the current store.
    struct ParsedRow {
        let id: UUID
        let date: Date
        let description: String
        let categoryName: String
        let type: TransactionType
        /// The RAW (unsigned-per-type) amount — already reversed from the CSV's signed DISPLAY
        /// value back to what `FinanceTransaction.amount` itself stores, mirroring
        /// `TransactionCSVExportService.signedAmount(for:)`'s own mapping in reverse.
        let rawAmount: Decimal
        let isPending: Bool
        let source: TransactionSource
        let externalTransactionId: String?
        let accountName: String
    }

    /// Why a syntactically-parseable row was excluded from the restorable set.
    enum SkipReason: Equatable {
        case malformedRow(String)
        case unsupportedType(String)
        case accountNotFound(String)
        case ambiguousAccount(String)
    }

    struct SkippedRow: Equatable {
        let accountName: String
        let reason: SkipReason
    }

    struct ParseResult {
        let rows: [ParsedRow]
        let skipped: [SkippedRow]
        /// `false` only when the file contains no recognizable "Restore Missing Transactions"
        /// section at all (wrong file entirely) — distinct from "0 missing," which is a fully
        /// valid, unremarkable outcome (the CSV and the store already agree).
        let isRecognizedFormat: Bool
    }

    // MARK: - Preview

    struct PreviewResult {
        let totalCSVRows: Int
        let alreadyPresentCount: Int
        /// Missing from the store AND has an unambiguous account match — exactly what "Restore
        /// Missing Transactions" will actually insert.
        let restorable: [ParsedRow]
        /// Every row NOT in `restorable`, with why: malformed CSV syntax, an unsupported
        /// transaction type, or — for a row that IS otherwise missing from the store — an
        /// account name matching zero or multiple current accounts. All three are reported up
        /// front, before the user ever taps Restore, rather than discovered mid-restore.
        let skipped: [SkippedRow]
        let isRecognizedFormat: Bool
    }

    // MARK: - CSV tokenizing (RFC 4180: quoted commas, escaped "" quotes, embedded newlines)

    private static func tokenizeRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false
        var hasAnyContent = false

        func endField() {
            currentRow.append(currentField)
            currentField = ""
        }
        func endRow() {
            endField()
            rows.append(currentRow)
            currentRow = []
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            hasAnyContent = true
            if insideQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                    } else {
                        insideQuotes = false
                        i += 1
                    }
                } else {
                    currentField.append(c)
                    i += 1
                }
                continue
            }
            switch c {
            case "\"":
                insideQuotes = true
                i += 1
            case ",":
                endField()
                i += 1
            case "\r":
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                i += 1
                endRow()
            case "\n":
                i += 1
                endRow()
            default:
                currentField.append(c)
                i += 1
            }
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            endRow()
        }
        return hasAnyContent ? rows : []
    }

    // MARK: - Field parsing

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let restorableTypesByLabel: [String: TransactionType] = [
        TransactionType.expense.label: .expense,
        TransactionType.refund.label: .refund,
        TransactionType.income.label: .income,
        TransactionType.transferWithdrawal.label: .transferWithdrawal,
        TransactionType.transferDeposit.label: .transferDeposit,
    ]

    private static let unsupportedTypesByLabel: [String: TransactionType] = [
        TransactionType.transfer.label: .transfer,
        TransactionType.creditCardPayment.label: .creditCardPayment,
        TransactionType.balanceAdjustment.label: .balanceAdjustment,
    ]

    private static let sourcesByLabel: [String: TransactionSource] = Dictionary(
        uniqueKeysWithValues: TransactionSource.allCases.map { ($0.label, $0) }
    )

    /// Reverses `TransactionCSVExportService.signedAmount(for:)` back to the raw magnitude
    /// `FinanceTransaction.amount` stores, for the restorable types only.
    private static func rawAmount(signed: Decimal, type: TransactionType) -> Decimal {
        switch type {
        case .expense, .transferWithdrawal: return -signed
        case .refund, .income, .transferDeposit: return signed
        case .transfer, .creditCardPayment, .balanceAdjustment: return signed
        }
    }

    // MARK: - Parse

    /// Parses `csv` into restorable/skipped rows without touching any store — pure, synchronous,
    /// side-effect-free. Recognizes exactly the multi-section shape
    /// `TransactionCSVExportService.csvString(for:allTransactions:)` produces: an account-name
    /// line, this file's own header row, one or more data rows, and a blank-line separator
    /// before the next account's section.
    static func parse(_ csv: String) -> ParseResult {
        let rows = tokenizeRows(csv)
        var currentAccountName: String?
        var sawHeaderForCurrentSection = false
        var isRecognizedFormat = false
        var parsed: [ParsedRow] = []
        var skipped: [SkippedRow] = []

        let expectedHeaderFields = TransactionCSVExportService.header.components(separatedBy: ",")

        for row in rows {
            // Blank-line section separator: a single empty field.
            if row.count == 1, row[0].isEmpty {
                currentAccountName = nil
                sawHeaderForCurrentSection = false
                continue
            }
            // Account-name line: a single non-empty field.
            if row.count == 1 {
                currentAccountName = row[0]
                sawHeaderForCurrentSection = false
                continue
            }
            // This file's own column header.
            if row == expectedHeaderFields {
                sawHeaderForCurrentSection = true
                isRecognizedFormat = true
                continue
            }

            guard let accountName = currentAccountName, sawHeaderForCurrentSection else {
                skipped.append(SkippedRow(accountName: currentAccountName ?? "", reason: .malformedRow("row found outside a recognized account section")))
                continue
            }
            guard row.count == expectedHeaderFields.count else {
                skipped.append(SkippedRow(accountName: accountName, reason: .malformedRow("expected \(expectedHeaderFields.count) fields, found \(row.count)")))
                continue
            }

            let dateString = row[0]
            let description = row[1]
            let categoryName = row[2]
            let typeLabel = row[3]
            let amountString = row[4]
            let pendingString = row[5]
            let sourceLabel = row[6]
            let idString = row[7]
            let externalIdString = row[8]

            guard let date = dateFormatter.date(from: dateString) else {
                skipped.append(SkippedRow(accountName: accountName, reason: .malformedRow("invalid date \"\(dateString)\"")))
                continue
            }
            guard let signedAmount = Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) else {
                skipped.append(SkippedRow(accountName: accountName, reason: .malformedRow("invalid amount \"\(amountString)\"")))
                continue
            }
            guard let isPending = pendingBool(from: pendingString) else {
                skipped.append(SkippedRow(accountName: accountName, reason: .malformedRow("invalid pending value \"\(pendingString)\"")))
                continue
            }
            guard let source = sourcesByLabel[sourceLabel] else {
                skipped.append(SkippedRow(accountName: accountName, reason: .malformedRow("unrecognized source \"\(sourceLabel)\"")))
                continue
            }
            guard let id = UUID(uuidString: idString) else {
                skipped.append(SkippedRow(accountName: accountName, reason: .malformedRow("missing or invalid Transaction ID")))
                continue
            }

            if let type = restorableTypesByLabel[typeLabel] {
                parsed.append(ParsedRow(
                    id: id,
                    date: date,
                    description: description,
                    categoryName: categoryName,
                    type: type,
                    rawAmount: rawAmount(signed: signedAmount, type: type),
                    isPending: isPending,
                    source: source,
                    externalTransactionId: externalIdString.isEmpty ? nil : externalIdString,
                    accountName: accountName
                ))
            } else if unsupportedTypesByLabel[typeLabel] != nil {
                skipped.append(SkippedRow(accountName: accountName, reason: .unsupportedType(typeLabel)))
            } else {
                skipped.append(SkippedRow(accountName: accountName, reason: .malformedRow("unrecognized type \"\(typeLabel)\"")))
            }
        }

        return ParseResult(rows: parsed, skipped: skipped, isRecognizedFormat: isRecognizedFormat)
    }

    private static func pendingBool(from field: String) -> Bool? {
        switch field {
        case "Yes": return true
        case "No": return false
        default: return nil
        }
    }

    // MARK: - Preview

    /// Compares parsed rows against the current store's own transaction IDs — `existingTransactionIDs`
    /// is every `FinanceTransaction.id` already present for the CURRENTLY authenticated user (the
    /// caller supplies these from its own per-user `@Query`, so this function itself never reaches
    /// into a store directly and can never cross into another user's data). Also resolves each
    /// still-missing row's account by exact name against `accounts` (the current user's own), so
    /// an unrestorable account relationship is surfaced HERE — in the preview, before the user
    /// ever taps Restore — rather than discovered mid-restore.
    static func preview(parseResult: ParseResult, existingTransactionIDs: Set<UUID>, accounts: [Account]) -> PreviewResult {
        var accountNameCounts: [String: Int] = [:]
        for account in accounts {
            accountNameCounts[account.name, default: 0] += 1
        }

        var alreadyPresentCount = 0
        var restorable: [ParsedRow] = []
        var skipped = parseResult.skipped
        for row in parseResult.rows {
            if existingTransactionIDs.contains(row.id) {
                alreadyPresentCount += 1
                continue
            }
            switch accountNameCounts[row.accountName] ?? 0 {
            case 1:
                restorable.append(row)
            case 0:
                skipped.append(SkippedRow(accountName: row.accountName, reason: .accountNotFound(row.accountName)))
            default:
                skipped.append(SkippedRow(accountName: row.accountName, reason: .ambiguousAccount(row.accountName)))
            }
        }
        return PreviewResult(
            totalCSVRows: parseResult.rows.count + parseResult.skipped.count,
            alreadyPresentCount: alreadyPresentCount,
            restorable: restorable,
            skipped: skipped,
            isRecognizedFormat: parseResult.isRecognizedFormat
        )
    }

    // MARK: - Restore

    /// Creates one `FinanceTransaction` per row in `restorable` (expected to be exactly
    /// `PreviewResult.restorable` — already missing from the store AND already resolved to a
    /// unique account, so this performs no further eligibility decisions of its own), applies
    /// the manual-only balance effect via `AccountBalanceManager`, and performs a SINGLE
    /// `context.save()` for the whole batch — on failure, every transaction this call inserted
    /// is deleted and every balance this call mutated is restored to its captured original value
    /// (the same explicit capture-then-restore pattern `PayBillsView.submit()` uses, proven
    /// necessary because `ModelContext.rollback()` does not revert in-place `@Model` property
    /// mutations — see that type's own doc comment for the empirical basis). A row whose account
    /// name no longer resolves uniquely by the time this runs (accounts changed between preview
    /// and restore) is skipped defensively rather than crashing or guessing.
    @MainActor
    @discardableResult
    static func restore(
        restorable: [ParsedRow],
        accounts: [Account],
        categories: [Category],
        context: ModelContext
    ) throws -> Int {
        var accountsByName: [String: [Account]] = [:]
        for account in accounts {
            accountsByName[account.name, default: []].append(account)
        }
        var categoriesByName: [String: Category] = [:]
        for category in categories {
            categoriesByName[category.name] = category
        }

        var createdTransactions: [FinanceTransaction] = []
        var originalBalancesByAccountID: [UUID: Decimal] = [:]

        for row in restorable {
            guard let account = (accountsByName[row.accountName] ?? []).first, accountsByName[row.accountName]?.count == 1 else {
                continue
            }

            let transaction = FinanceTransaction(
                id: row.id,
                amount: row.rawAmount,
                date: row.date,
                type: row.type,
                source: row.source,
                note: row.description,
                isPending: row.isPending,
                externalTransactionId: row.externalTransactionId,
                account: account,
                category: categoriesByName[row.categoryName],
                ownerUserID: account.ownerUserID
            )
            context.insert(transaction)
            createdTransactions.append(transaction)

            // Only `.manual` transactions derive Account.currentBalance locally — `.plaid`
            // balances are refreshed directly from the bank, never from local transaction math.
            if row.source == .manual {
                if originalBalancesByAccountID[account.id] == nil {
                    originalBalancesByAccountID[account.id] = account.currentBalance
                }
                switch row.type {
                case .expense, .transferWithdrawal: AccountBalanceManager.applyExpense(amount: row.rawAmount, to: account)
                case .refund: AccountBalanceManager.applyRefund(amount: row.rawAmount, to: account)
                case .income, .transferDeposit: AccountBalanceManager.applyIncome(amount: row.rawAmount, to: account)
                case .transfer, .creditCardPayment, .balanceAdjustment:
                    break // unreachable — parse() never produces these as restorable rows.
                }
            }
        }

        do {
            try context.save()
        } catch {
            for transaction in createdTransactions {
                context.delete(transaction)
            }
            for account in accounts {
                if let original = originalBalancesByAccountID[account.id] {
                    account.currentBalance = original
                }
            }
            throw error
        }

        return createdTransactions.count
    }
}
