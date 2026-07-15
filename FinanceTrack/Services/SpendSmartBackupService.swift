import Foundation
import SwiftData

/// Local-only export/import backup for every SwiftData record SpendSmart stores. Converts each
/// `@Model` into a stable, independent `Codable` DTO (never encodes the SwiftData model types
/// directly, which would be fragile across schema changes), and never includes anything from the
/// Plaid/Supabase backend — no access tokens, no client secrets, no Amex credentials, no API
/// keys. Those live only in Supabase Edge Functions and are never present in this app's memory or
/// persistence layer in the first place, so there is nothing here that could leak them.
enum SpendSmartBackupService {

    static let currentBackupVersion = 1
    static let currentSchemaVersion = 1
    static let appName = "SpendSmart"
    static let appDisplayName = "SpendSmart"
    static let bundleIdentifier = "com.scott.financetrack"

    // MARK: - Decimal wrapper

    /// Encodes/decodes a `Decimal` as a JSON string rather than a JSON number. `JSONDecoder`
    /// decodes numeric literals through `Double` before `Decimal` ever sees them, which silently
    /// corrupts exact cent values (e.g. `19.99` becomes `19.98999999999999488`) — the same trap
    /// this codebase already worked around once for Plaid's backend responses
    /// (`BackendTransactionDTO`). Every Decimal in a backup file goes through this wrapper.
    struct DecimalValue: Codable, Equatable {
        let value: Decimal

        init(_ value: Decimal) { self.value = value }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let decimal = Decimal(string: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(string)\" is not a valid decimal amount")
            }
            value = decimal
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(NSDecimalNumber(decimal: value).stringValue)
        }
    }

    // MARK: - DTOs

    struct AccountDTO: Codable, Equatable {
        let id: UUID
        let name: String
        let type: String
        let currentBalance: DecimalValue
        let institutionName: String?
        let lastFourDigits: String?
        let creditLimit: DecimalValue?
        let availableCredit: DecimalValue?
        let paymentDueDate: Date?
        let minimumPayment: DecimalValue?
        let colorHex: String
        let isArchived: Bool
        let createdAt: Date
        let updatedAt: Date
        let connectionType: String
        let externalIdentifier: String?
        /// Added after the initial backup format shipped — decoded with a `true` fallback (via
        /// `decodeIfPresent`) so a backup file from before this field existed still restores
        /// cleanly, with every account defaulting to the same "counts toward monthly spending"
        /// behavior that was the only behavior before this feature existed.
        let defaultCountsTowardMonthlySpending: Bool

        init(
            id: UUID, name: String, type: String, currentBalance: DecimalValue, institutionName: String?,
            lastFourDigits: String?, creditLimit: DecimalValue?, availableCredit: DecimalValue?,
            paymentDueDate: Date?, minimumPayment: DecimalValue?, colorHex: String, isArchived: Bool,
            createdAt: Date, updatedAt: Date, connectionType: String, externalIdentifier: String?,
            defaultCountsTowardMonthlySpending: Bool
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.currentBalance = currentBalance
            self.institutionName = institutionName
            self.lastFourDigits = lastFourDigits
            self.creditLimit = creditLimit
            self.availableCredit = availableCredit
            self.paymentDueDate = paymentDueDate
            self.minimumPayment = minimumPayment
            self.colorHex = colorHex
            self.isArchived = isArchived
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.connectionType = connectionType
            self.externalIdentifier = externalIdentifier
            self.defaultCountsTowardMonthlySpending = defaultCountsTowardMonthlySpending
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(String.self, forKey: .type)
            currentBalance = try container.decode(DecimalValue.self, forKey: .currentBalance)
            institutionName = try container.decodeIfPresent(String.self, forKey: .institutionName)
            lastFourDigits = try container.decodeIfPresent(String.self, forKey: .lastFourDigits)
            creditLimit = try container.decodeIfPresent(DecimalValue.self, forKey: .creditLimit)
            availableCredit = try container.decodeIfPresent(DecimalValue.self, forKey: .availableCredit)
            paymentDueDate = try container.decodeIfPresent(Date.self, forKey: .paymentDueDate)
            minimumPayment = try container.decodeIfPresent(DecimalValue.self, forKey: .minimumPayment)
            colorHex = try container.decode(String.self, forKey: .colorHex)
            isArchived = try container.decode(Bool.self, forKey: .isArchived)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            connectionType = try container.decode(String.self, forKey: .connectionType)
            externalIdentifier = try container.decodeIfPresent(String.self, forKey: .externalIdentifier)
            defaultCountsTowardMonthlySpending = try container.decodeIfPresent(Bool.self, forKey: .defaultCountsTowardMonthlySpending) ?? true
        }
    }

    struct FinanceTransactionDTO: Codable, Equatable {
        let id: UUID
        let amount: DecimalValue
        let date: Date
        let type: String
        let source: String
        let note: String
        let countsTowardWeeklyBudget: Bool
        /// Added after the initial backup format shipped — decoded with a `true` fallback so a
        /// backup file from before this field existed restores every transaction as still
        /// counting toward monthly spending, matching that format's only actual behavior.
        let countsTowardMonthlySpending: Bool
        let isExcludedFromReports: Bool
        let isPending: Bool
        let createdAt: Date
        let updatedAt: Date
        let externalTransactionId: String?
        let pendingTransactionId: String?
        let merchantName: String?
        let originalDescription: String?
        let plaidAccountId: String?
        let authorizedDate: Date?
        let postedDate: Date?
        let isMatchedToManualExpense: Bool
        let matchedTransactionId: UUID?
        let accountId: UUID?
        let categoryId: UUID?
        let transferDestinationAccountId: UUID?

        init(
            id: UUID, amount: DecimalValue, date: Date, type: String, source: String, note: String,
            countsTowardWeeklyBudget: Bool, countsTowardMonthlySpending: Bool, isExcludedFromReports: Bool,
            isPending: Bool, createdAt: Date, updatedAt: Date, externalTransactionId: String?,
            pendingTransactionId: String?, merchantName: String?, originalDescription: String?,
            plaidAccountId: String?, authorizedDate: Date?, postedDate: Date?, isMatchedToManualExpense: Bool,
            matchedTransactionId: UUID?, accountId: UUID?, categoryId: UUID?, transferDestinationAccountId: UUID?
        ) {
            self.id = id
            self.amount = amount
            self.date = date
            self.type = type
            self.source = source
            self.note = note
            self.countsTowardWeeklyBudget = countsTowardWeeklyBudget
            self.countsTowardMonthlySpending = countsTowardMonthlySpending
            self.isExcludedFromReports = isExcludedFromReports
            self.isPending = isPending
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.externalTransactionId = externalTransactionId
            self.pendingTransactionId = pendingTransactionId
            self.merchantName = merchantName
            self.originalDescription = originalDescription
            self.plaidAccountId = plaidAccountId
            self.authorizedDate = authorizedDate
            self.postedDate = postedDate
            self.isMatchedToManualExpense = isMatchedToManualExpense
            self.matchedTransactionId = matchedTransactionId
            self.accountId = accountId
            self.categoryId = categoryId
            self.transferDestinationAccountId = transferDestinationAccountId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            amount = try container.decode(DecimalValue.self, forKey: .amount)
            date = try container.decode(Date.self, forKey: .date)
            type = try container.decode(String.self, forKey: .type)
            source = try container.decode(String.self, forKey: .source)
            note = try container.decode(String.self, forKey: .note)
            countsTowardWeeklyBudget = try container.decode(Bool.self, forKey: .countsTowardWeeklyBudget)
            countsTowardMonthlySpending = try container.decodeIfPresent(Bool.self, forKey: .countsTowardMonthlySpending) ?? true
            isExcludedFromReports = try container.decode(Bool.self, forKey: .isExcludedFromReports)
            isPending = try container.decode(Bool.self, forKey: .isPending)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            externalTransactionId = try container.decodeIfPresent(String.self, forKey: .externalTransactionId)
            pendingTransactionId = try container.decodeIfPresent(String.self, forKey: .pendingTransactionId)
            merchantName = try container.decodeIfPresent(String.self, forKey: .merchantName)
            originalDescription = try container.decodeIfPresent(String.self, forKey: .originalDescription)
            plaidAccountId = try container.decodeIfPresent(String.self, forKey: .plaidAccountId)
            authorizedDate = try container.decodeIfPresent(Date.self, forKey: .authorizedDate)
            postedDate = try container.decodeIfPresent(Date.self, forKey: .postedDate)
            isMatchedToManualExpense = try container.decode(Bool.self, forKey: .isMatchedToManualExpense)
            matchedTransactionId = try container.decodeIfPresent(UUID.self, forKey: .matchedTransactionId)
            accountId = try container.decodeIfPresent(UUID.self, forKey: .accountId)
            categoryId = try container.decodeIfPresent(UUID.self, forKey: .categoryId)
            transferDestinationAccountId = try container.decodeIfPresent(UUID.self, forKey: .transferDestinationAccountId)
        }
    }

    struct CategoryDTO: Codable, Equatable {
        let id: UUID
        let name: String
        let iconName: String
        let colorName: String
        let isDefault: Bool
        let isArchived: Bool
        let createdAt: Date
    }

    struct BudgetSettingsDTO: Codable, Equatable {
        let id: UUID
        let weeklySpendingLimit: DecimalValue
        let weekStartsOnSunday: Bool
        let includePendingTransactions: Bool
        let hideBalancesByDefault: Bool
        let requireFaceID: Bool
        let monthlyGoal: DecimalValue?
        let warningThreshold: Double
        let autoBackupEnabled: Bool
        /// Added after the initial backup format shipped — decoded with a `true` fallback (via
        /// `decodeIfPresent`) so a backup file from before this field existed still restores
        /// cleanly, with Spend Sense defaulting to the same "on" behavior every other install gets.
        let spendSenseEnabled: Bool
        let updatedAt: Date

        init(
            id: UUID, weeklySpendingLimit: DecimalValue, weekStartsOnSunday: Bool,
            includePendingTransactions: Bool, hideBalancesByDefault: Bool, requireFaceID: Bool,
            monthlyGoal: DecimalValue?, warningThreshold: Double, autoBackupEnabled: Bool,
            spendSenseEnabled: Bool, updatedAt: Date
        ) {
            self.id = id
            self.weeklySpendingLimit = weeklySpendingLimit
            self.weekStartsOnSunday = weekStartsOnSunday
            self.includePendingTransactions = includePendingTransactions
            self.hideBalancesByDefault = hideBalancesByDefault
            self.requireFaceID = requireFaceID
            self.monthlyGoal = monthlyGoal
            self.warningThreshold = warningThreshold
            self.autoBackupEnabled = autoBackupEnabled
            self.spendSenseEnabled = spendSenseEnabled
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            weeklySpendingLimit = try container.decode(DecimalValue.self, forKey: .weeklySpendingLimit)
            weekStartsOnSunday = try container.decode(Bool.self, forKey: .weekStartsOnSunday)
            includePendingTransactions = try container.decode(Bool.self, forKey: .includePendingTransactions)
            hideBalancesByDefault = try container.decode(Bool.self, forKey: .hideBalancesByDefault)
            requireFaceID = try container.decode(Bool.self, forKey: .requireFaceID)
            monthlyGoal = try container.decodeIfPresent(DecimalValue.self, forKey: .monthlyGoal)
            warningThreshold = try container.decode(Double.self, forKey: .warningThreshold)
            autoBackupEnabled = try container.decode(Bool.self, forKey: .autoBackupEnabled)
            spendSenseEnabled = try container.decodeIfPresent(Bool.self, forKey: .spendSenseEnabled) ?? true
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }
    }

    struct MonthlyPlanSettingsDTO: Codable, Equatable {
        let id: UUID
        let monthlySavingsGoal: DecimalValue
        let bufferAmount: DecimalValue?
        let useRecommendedWeeklyBudget: Bool
        let autoUpdateWeeklyBudgetFromPlan: Bool
        let createdAt: Date
        let updatedAt: Date
    }

    struct IncomeSourceDTO: Codable, Equatable {
        let id: UUID
        let name: String
        let amount: DecimalValue
        let frequency: String
        let timing: String
        let dayOfMonth: Int?
        let nextPayDate: Date?
        let isActive: Bool
        let note: String
        let createdAt: Date
        let updatedAt: Date
    }

    struct RecurringExpenseDTO: Codable, Equatable {
        let id: UUID
        let name: String
        let amount: DecimalValue
        let categoryId: UUID?
        let frequency: String
        let timing: String
        let dayOfMonth: Int?
        let dueDate: Date?
        let paymentAccountId: UUID?
        let isEssential: Bool
        let isActive: Bool
        let note: String
        let createdAt: Date
        let updatedAt: Date
    }

    /// The full backup file's root structure.
    struct Document: Codable, Equatable {
        let backupVersion: Int
        let schemaVersion: Int
        let createdAt: Date
        let appName: String
        let appDisplayName: String
        let bundleIdentifier: String
        let accounts: [AccountDTO]
        let transactions: [FinanceTransactionDTO]
        let categories: [CategoryDTO]
        let budgetSettings: [BudgetSettingsDTO]
        let monthlyPlanSettings: [MonthlyPlanSettingsDTO]
        let incomeSources: [IncomeSourceDTO]
        let recurringExpenses: [RecurringExpenseDTO]
    }

    // MARK: - Export: model -> DTO

    static func makeDocument(
        accounts: [Account],
        transactions: [FinanceTransaction],
        categories: [Category],
        budgetSettings: [BudgetSettings],
        monthlyPlanSettings: [MonthlyPlanSettings],
        incomeSources: [IncomeSource],
        recurringExpenses: [RecurringExpense],
        createdAt: Date = .now
    ) -> Document {
        Document(
            backupVersion: currentBackupVersion,
            schemaVersion: currentSchemaVersion,
            createdAt: createdAt,
            appName: appName,
            appDisplayName: appDisplayName,
            bundleIdentifier: bundleIdentifier,
            accounts: accounts.map(AccountDTO.init),
            transactions: transactions.map(FinanceTransactionDTO.init),
            categories: categories.map(CategoryDTO.init),
            budgetSettings: budgetSettings.map(BudgetSettingsDTO.init),
            monthlyPlanSettings: monthlyPlanSettings.map(MonthlyPlanSettingsDTO.init),
            incomeSources: incomeSources.map(IncomeSourceDTO.init),
            recurringExpenses: recurringExpenses.map(RecurringExpenseDTO.init)
        )
    }

    /// Fetches every included model from `context` and builds a `Document` — the one place that
    /// touches SwiftData for export, so both manual export and auto-backup share it.
    @MainActor
    static func fetchAndMakeDocument(context: ModelContext, createdAt: Date = .now) throws -> Document {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let categories = try context.fetch(FetchDescriptor<Category>())
        let budgetSettings = try context.fetch(FetchDescriptor<BudgetSettings>())
        let monthlyPlanSettings = try context.fetch(FetchDescriptor<MonthlyPlanSettings>())
        let incomeSources = try context.fetch(FetchDescriptor<IncomeSource>())
        let recurringExpenses = try context.fetch(FetchDescriptor<RecurringExpense>())
        return makeDocument(
            accounts: accounts,
            transactions: transactions,
            categories: categories,
            budgetSettings: budgetSettings,
            monthlyPlanSettings: monthlyPlanSettings,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            createdAt: createdAt
        )
    }

    static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    // MARK: - Filenames

    private static func filenameFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        return formatter
    }

    static func backupFilename(date: Date = .now) -> String {
        "SpendSmart-Backup-\(filenameFormatter(format: "yyyy-MM-dd-HHmm").string(from: date)).json"
    }

    static let autoBackupFilenamePrefix = "SpendSmart-AutoBackup-"

    static func autoBackupFilename(date: Date = .now) -> String {
        "\(autoBackupFilenamePrefix)\(filenameFormatter(format: "yyyy-MM-dd-HHmmss").string(from: date)).json"
    }

    // MARK: - Import: decode + validate

    enum BackupError: Error, LocalizedError {
        case invalidFile
        case unsupportedVersion(Int)
        case fileSystemError(String)

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "This doesn't look like a valid SpendSmart backup file."
            case .unsupportedVersion(let version):
                return "This backup file (version \(version)) isn't supported by this version of SpendSmart."
            case .fileSystemError(let message):
                return "Couldn't complete the backup operation: \(message)"
            }
        }
    }

    static func decode(_ data: Data) throws -> Document {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw BackupError.invalidFile
        }
        guard document.backupVersion > 0, document.backupVersion <= currentBackupVersion else {
            throw BackupError.unsupportedVersion(document.backupVersion)
        }
        return document
    }

    struct ImportSummary: Equatable {
        let accountsCount: Int
        let transactionsCount: Int
        let categoriesCount: Int
        let incomeSourcesCount: Int
        let recurringExpensesCount: Int
        let createdAt: Date
    }

    static func summary(for document: Document) -> ImportSummary {
        ImportSummary(
            accountsCount: document.accounts.count,
            transactionsCount: document.transactions.count,
            categoriesCount: document.categories.count,
            incomeSourcesCount: document.incomeSources.count,
            recurringExpensesCount: document.recurringExpenses.count,
            createdAt: document.createdAt
        )
    }

    // MARK: - Import: replace-all restore

    /// Deletes every existing record for the seven included models, then recreates them from
    /// `document`, preserving original IDs and re-linking `Account`/`Category` relationships by
    /// those IDs. This is the only restore mode — a full replace, never a merge — so there is no
    /// risk of ending up with duplicate transactions from a previous restore.
    @MainActor
    static func restore(_ document: Document, into context: ModelContext) throws {
        // Delete dependents before the things they reference.
        try context.delete(model: FinanceTransaction.self)
        try context.delete(model: RecurringExpense.self)
        try context.delete(model: Account.self)
        try context.delete(model: Category.self)
        try context.delete(model: IncomeSource.self)
        try context.delete(model: BudgetSettings.self)
        try context.delete(model: MonthlyPlanSettings.self)

        var accountsById: [UUID: Account] = [:]
        for dto in document.accounts {
            guard let type = AccountType(rawValue: dto.type) else { throw BackupError.invalidFile }
            let connectionType = dto.connectionType.isEmpty ? TransactionSource.manual : (TransactionSource(rawValue: dto.connectionType) ?? .manual)
            let account = Account(
                id: dto.id,
                name: dto.name,
                type: type,
                currentBalance: dto.currentBalance.value,
                institutionName: dto.institutionName,
                lastFourDigits: dto.lastFourDigits,
                creditLimit: dto.creditLimit?.value,
                availableCredit: dto.availableCredit?.value,
                paymentDueDate: dto.paymentDueDate,
                minimumPayment: dto.minimumPayment?.value,
                colorHex: dto.colorHex,
                isArchived: dto.isArchived,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt,
                connectionType: connectionType,
                externalIdentifier: dto.externalIdentifier,
                defaultCountsTowardMonthlySpending: dto.defaultCountsTowardMonthlySpending
            )
            context.insert(account)
            accountsById[dto.id] = account
        }

        var categoriesById: [UUID: Category] = [:]
        for dto in document.categories {
            let category = Category(
                id: dto.id,
                name: dto.name,
                iconName: dto.iconName,
                colorName: dto.colorName,
                isDefault: dto.isDefault,
                isArchived: dto.isArchived,
                createdAt: dto.createdAt
            )
            context.insert(category)
            categoriesById[dto.id] = category
        }

        for dto in document.transactions {
            guard let type = TransactionType(rawValue: dto.type) else { throw BackupError.invalidFile }
            let source = TransactionSource(rawValue: dto.source) ?? .manual
            let transaction = FinanceTransaction(
                id: dto.id,
                amount: dto.amount.value,
                date: dto.date,
                type: type,
                source: source,
                note: dto.note,
                countsTowardWeeklyBudget: dto.countsTowardWeeklyBudget,
                countsTowardMonthlySpending: dto.countsTowardMonthlySpending,
                isExcludedFromReports: dto.isExcludedFromReports,
                isPending: dto.isPending,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt,
                externalTransactionId: dto.externalTransactionId,
                pendingTransactionId: dto.pendingTransactionId,
                merchantName: dto.merchantName,
                originalDescription: dto.originalDescription,
                plaidAccountId: dto.plaidAccountId,
                authorizedDate: dto.authorizedDate,
                postedDate: dto.postedDate,
                isMatchedToManualExpense: dto.isMatchedToManualExpense,
                matchedTransactionId: dto.matchedTransactionId,
                account: dto.accountId.flatMap { accountsById[$0] },
                category: dto.categoryId.flatMap { categoriesById[$0] },
                transferDestinationAccount: dto.transferDestinationAccountId.flatMap { accountsById[$0] }
            )
            context.insert(transaction)
        }

        for dto in document.recurringExpenses {
            guard let frequency = PlanFrequency(rawValue: dto.frequency), let timing = PlanTiming(rawValue: dto.timing) else {
                throw BackupError.invalidFile
            }
            let expense = RecurringExpense(
                id: dto.id,
                name: dto.name,
                amount: dto.amount.value,
                category: dto.categoryId.flatMap { categoriesById[$0] },
                frequency: frequency,
                timing: timing,
                dayOfMonth: dto.dayOfMonth,
                dueDate: dto.dueDate,
                paymentAccount: dto.paymentAccountId.flatMap { accountsById[$0] },
                isEssential: dto.isEssential,
                isActive: dto.isActive,
                note: dto.note,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )
            context.insert(expense)
        }

        for dto in document.incomeSources {
            guard let frequency = PlanFrequency(rawValue: dto.frequency), let timing = PlanTiming(rawValue: dto.timing) else {
                throw BackupError.invalidFile
            }
            let source = IncomeSource(
                id: dto.id,
                name: dto.name,
                amount: dto.amount.value,
                frequency: frequency,
                timing: timing,
                dayOfMonth: dto.dayOfMonth,
                nextPayDate: dto.nextPayDate,
                isActive: dto.isActive,
                note: dto.note,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )
            context.insert(source)
        }

        for dto in document.budgetSettings {
            let settings = BudgetSettings(
                id: dto.id,
                weeklySpendingLimit: dto.weeklySpendingLimit.value,
                weekStartsOnSunday: dto.weekStartsOnSunday,
                includePendingTransactions: dto.includePendingTransactions,
                hideBalancesByDefault: dto.hideBalancesByDefault,
                requireFaceID: dto.requireFaceID,
                monthlyGoal: dto.monthlyGoal?.value,
                warningThreshold: dto.warningThreshold,
                autoBackupEnabled: dto.autoBackupEnabled,
                spendSenseEnabled: dto.spendSenseEnabled,
                updatedAt: dto.updatedAt
            )
            context.insert(settings)
        }

        for dto in document.monthlyPlanSettings {
            let settings = MonthlyPlanSettings(
                id: dto.id,
                monthlySavingsGoal: dto.monthlySavingsGoal.value,
                bufferAmount: dto.bufferAmount?.value,
                useRecommendedWeeklyBudget: dto.useRecommendedWeeklyBudget,
                autoUpdateWeeklyBudgetFromPlan: dto.autoUpdateWeeklyBudgetFromPlan,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )
            context.insert(settings)
        }

        try context.save()
    }

    // MARK: - Auto backup: file management (pure, directory-parameterized, unit-testable)

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Writes an auto-backup JSON file for `document` into `directory`, then prunes older
    /// auto-backups so at most `keepingLatest` remain. Never throws on the prune step failing to
    /// remove a file — a stray extra file is harmless, but losing the just-written backup isn't.
    @discardableResult
    static func writeAutoBackup(
        _ document: Document,
        to directory: URL,
        keepingLatest count: Int = 5,
        date: Date = .now
    ) throws -> URL {
        let data = try encode(document)
        let url = directory.appendingPathComponent(autoBackupFilename(date: date))
        try data.write(to: url, options: .atomic)
        try? pruneAutoBackups(in: directory, keepingLatest: count)
        return url
    }

    /// Every auto-backup file in `directory`, newest first.
    static func autoBackupFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(autoBackupFilenamePrefix) && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    static func pruneAutoBackups(in directory: URL, keepingLatest count: Int) throws {
        let files = autoBackupFiles(in: directory)
        guard files.count > count else { return }
        for file in files[count...] {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - Model -> DTO conversions

private extension SpendSmartBackupService.AccountDTO {
    init(_ account: Account) {
        self.init(
            id: account.id,
            name: account.name,
            type: account.type.rawValue,
            currentBalance: .init(account.currentBalance),
            institutionName: account.institutionName,
            lastFourDigits: account.lastFourDigits,
            creditLimit: account.creditLimit.map(SpendSmartBackupService.DecimalValue.init),
            availableCredit: account.availableCredit.map(SpendSmartBackupService.DecimalValue.init),
            paymentDueDate: account.paymentDueDate,
            minimumPayment: account.minimumPayment.map(SpendSmartBackupService.DecimalValue.init),
            colorHex: account.colorHex,
            isArchived: account.isArchived,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt,
            connectionType: account.connectionType.rawValue,
            externalIdentifier: account.externalIdentifier,
            defaultCountsTowardMonthlySpending: account.defaultCountsTowardMonthlySpending
        )
    }
}

private extension SpendSmartBackupService.FinanceTransactionDTO {
    init(_ transaction: FinanceTransaction) {
        self.init(
            id: transaction.id,
            amount: .init(transaction.amount),
            date: transaction.date,
            type: transaction.type.rawValue,
            source: transaction.source.rawValue,
            note: transaction.note,
            countsTowardWeeklyBudget: transaction.countsTowardWeeklyBudget,
            countsTowardMonthlySpending: transaction.countsTowardMonthlySpending,
            isExcludedFromReports: transaction.isExcludedFromReports,
            isPending: transaction.isPending,
            createdAt: transaction.createdAt,
            updatedAt: transaction.updatedAt,
            externalTransactionId: transaction.externalTransactionId,
            pendingTransactionId: transaction.pendingTransactionId,
            merchantName: transaction.merchantName,
            originalDescription: transaction.originalDescription,
            plaidAccountId: transaction.plaidAccountId,
            authorizedDate: transaction.authorizedDate,
            postedDate: transaction.postedDate,
            isMatchedToManualExpense: transaction.isMatchedToManualExpense,
            matchedTransactionId: transaction.matchedTransactionId,
            accountId: transaction.account?.id,
            categoryId: transaction.category?.id,
            transferDestinationAccountId: transaction.transferDestinationAccount?.id
        )
    }
}

private extension SpendSmartBackupService.CategoryDTO {
    init(_ category: Category) {
        self.init(
            id: category.id,
            name: category.name,
            iconName: category.iconName,
            colorName: category.colorName,
            isDefault: category.isDefault,
            isArchived: category.isArchived,
            createdAt: category.createdAt
        )
    }
}

private extension SpendSmartBackupService.BudgetSettingsDTO {
    init(_ settings: BudgetSettings) {
        self.init(
            id: settings.id,
            weeklySpendingLimit: .init(settings.weeklySpendingLimit),
            weekStartsOnSunday: settings.weekStartsOnSunday,
            includePendingTransactions: settings.includePendingTransactions,
            hideBalancesByDefault: settings.hideBalancesByDefault,
            requireFaceID: settings.requireFaceID,
            monthlyGoal: settings.monthlyGoal.map(SpendSmartBackupService.DecimalValue.init),
            warningThreshold: settings.warningThreshold,
            autoBackupEnabled: settings.autoBackupEnabled ?? true,
            spendSenseEnabled: settings.spendSenseEnabled ?? true,
            updatedAt: settings.updatedAt
        )
    }
}

private extension SpendSmartBackupService.MonthlyPlanSettingsDTO {
    init(_ settings: MonthlyPlanSettings) {
        self.init(
            id: settings.id,
            monthlySavingsGoal: .init(settings.monthlySavingsGoal),
            bufferAmount: settings.bufferAmount.map(SpendSmartBackupService.DecimalValue.init),
            useRecommendedWeeklyBudget: settings.useRecommendedWeeklyBudget,
            autoUpdateWeeklyBudgetFromPlan: settings.autoUpdateWeeklyBudgetFromPlan,
            createdAt: settings.createdAt,
            updatedAt: settings.updatedAt
        )
    }
}

private extension SpendSmartBackupService.IncomeSourceDTO {
    init(_ source: IncomeSource) {
        self.init(
            id: source.id,
            name: source.name,
            amount: .init(source.amount),
            frequency: source.frequency.rawValue,
            timing: source.timing.rawValue,
            dayOfMonth: source.dayOfMonth,
            nextPayDate: source.nextPayDate,
            isActive: source.isActive,
            note: source.note,
            createdAt: source.createdAt,
            updatedAt: source.updatedAt
        )
    }
}

private extension SpendSmartBackupService.RecurringExpenseDTO {
    init(_ expense: RecurringExpense) {
        self.init(
            id: expense.id,
            name: expense.name,
            amount: .init(expense.amount),
            categoryId: expense.category?.id,
            frequency: expense.frequency.rawValue,
            timing: expense.timing.rawValue,
            dayOfMonth: expense.dayOfMonth,
            dueDate: expense.dueDate,
            paymentAccountId: expense.paymentAccount?.id,
            isEssential: expense.isEssential,
            isActive: expense.isActive,
            note: expense.note,
            createdAt: expense.createdAt,
            updatedAt: expense.updatedAt
        )
    }
}
