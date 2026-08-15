import Foundation

/// Builds the "Export CSV" file from Settings ▸ Data. Exports every account's full transaction
/// history (not filtered by date range or by the Activity screen's own filters — that screen's
/// filters are a display concern, not part of this export's scope), one section per account with
/// the account name as a header line above that account's rows, newest transaction first within
/// each section (matching `ManualAccountDetailView`'s own `\FinanceTransaction.date, order:
/// .reverse` convention). Includes archived accounts: archiving only affects where an account is
/// surfaced in the UI, never whether its historical transactions are real financial data — a full
/// history export must not silently drop them.
enum TransactionCSVExportService {
    /// CSV RESTORE/IMPORT SCHEMA EXTENSION — "Transaction ID"/"External ID" were appended (never
    /// inserted between existing columns) so this file stays byte-compatible with anything
    /// already parsing the original 7-column export. "Transaction ID" is `FinanceTransaction.id`
    /// itself: the one stable, collision-proof identity `TransactionCSVImportService` can use to
    /// tell "already present" from "genuinely missing" without ever guessing from date+amount+
    /// description, which two entirely legitimate transactions can share. "External ID" preserves
    /// `externalTransactionId` (Plaid's own dedupe key) so a restored connected-account
    /// transaction can never collide with what a later Plaid sync delivers for the same real
    /// bank transaction — see `TransactionCSVImportService`'s own header for the full restore
    /// design this schema exists to support.
    static let header = "Date,Description,Category,Type,Amount,Pending,Source,Transaction ID,External ID"

    /// The signed amount as shown to the user for this transaction — mirrors `TransactionRow`'s
    /// own `signPrefix` exactly (expense negative, refund/income positive, everything else
    /// unsigned/positive) so the export never disagrees with what's on screen for the same row.
    private static func signedAmount(for transaction: FinanceTransaction) -> Decimal {
        switch transaction.type {
        case .expense, .transferWithdrawal: return -transaction.amount
        case .refund, .income, .transfer, .creditCardPayment, .balanceAdjustment, .transferDeposit: return transaction.amount
        }
    }

    private static let amountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.negativePrefix = "-"
        return formatter
    }()

    private static func formattedAmount(_ amount: Decimal) -> String {
        amountFormatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// RFC 4180-style escaping: a field containing a comma, double quote, or line break is
    /// quote-wrapped with any embedded quotes doubled; every other field is left as-is.
    private static func escapedField(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func row(for transaction: FinanceTransaction) -> String {
        let fields = [
            dateFormatter.string(from: transaction.date),
            transaction.displayName,
            transaction.category?.name ?? "",
            transaction.type.label,
            formattedAmount(signedAmount(for: transaction)),
            transaction.isPending ? "Yes" : "No",
            transaction.source.label,
            transaction.id.uuidString,
            transaction.externalTransactionId ?? "",
        ]
        return fields.map(escapedField).joined(separator: ",")
    }

    /// `accounts`/`allTransactions` are taken separately, filtered by `account?.id`/
    /// `transferDestinationAccount?.id` match — the same "this account's transactions" definition
    /// `ManualAccountDetailView.accountTransactions` already uses (including a `.creditCardPayment`
    /// under both its source AND destination account, exactly like each account's own register
    /// screen would show it individually) — rather than reading the `Account.transactions` inverse
    /// relationship array directly, so this matches the one established pattern for "find an
    /// account's transactions" already used elsewhere in the app.
    ///
    /// `nil` when there is nothing eligible to export (every account has zero transactions) —
    /// callers must treat `nil` as the empty state and never write a header-only or otherwise
    /// misleading file.
    static func csvString(for accounts: [Account], allTransactions: [FinanceTransaction]) -> String? {
        let sortedAccounts = accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var sections: [String] = []

        for account in sortedAccounts {
            let transactions = allTransactions
                .filter { $0.account?.id == account.id || $0.transferDestinationAccount?.id == account.id }
                .sorted { $0.date > $1.date }
            guard !transactions.isEmpty else { continue }

            var lines = [escapedField(account.name), header]
            lines.append(contentsOf: transactions.map(row))
            sections.append(lines.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    static func exportFilename(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "SpendSmart-Transactions-\(formatter.string(from: date)).csv"
    }

    /// Writes `csv` to `url` as UTF-8, prefixed with a byte-order mark so Excel (which otherwise
    /// guesses a system codepage rather than UTF-8 for a BOM-less file) reliably renders non-ASCII
    /// account/category/description text correctly. Numbers and other UTF-8-aware readers ignore
    /// a leading BOM without issue.
    static func write(_ csv: String, to url: URL) throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let data = bom + Data(csv.utf8)
        try data.write(to: url, options: .atomic)
    }
}
