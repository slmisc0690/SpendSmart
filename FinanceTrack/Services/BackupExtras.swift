import Foundation
import SwiftData

/// Everything the original backup format left out: the settings, lists and links that live only on
/// this device. Stored as one optional section of the backup file, so older backups still decode
/// (they simply have no extras) and older app builds ignore it.
struct BackupExtras: Codable, Equatable {
    typealias DecimalValue = SpendSmartBackupService.DecimalValue

    struct TransactionExtra: Codable, Equatable {
        let id: UUID
        let linkedRecurringExpenseId: UUID?
        let isOneTimeBillEntry: Bool
        let billTiming: String?
        let transferCounterpartyAccountId: UUID?
        let transferCounterpartyPlaidAccountId: String?
        let isPaymentConfirmed: Bool
    }

    struct AccountExtra: Codable, Equatable {
        let id: UUID
        let showsInRecentActivity: Bool
    }

    struct IncomeSourceExtra: Codable, Equatable {
        let id: UUID
        let monthlyDepositDayIsLastDay: Bool
        let twiceMonthlyFirstDayNumber: Int?
        let twiceMonthlyFirstDayIsLastDay: Bool
        let twiceMonthlySecondDayNumber: Int?
        let twiceMonthlySecondDayIsLastDay: Bool
    }

    /// An exclusion keeps the transaction's stable bank id next to its local id, so it can still be
    /// matched after a re-import gives the same transaction a new local id.
    struct ExcludedTransaction: Codable, Equatable {
        let id: UUID
        let externalTransactionId: String?
    }

    struct BudgetSettingsExtra: Codable, Equatable {
        let id: UUID
        let cloudBackupRetentionDays: Int?
        let autoCalculateConnectedAccountIds: [String]?
        let excludeTransactionsEnabled: Bool?
        let excludedTransactions: [ExcludedTransaction]
        let showMonthlySpendingQuickStat: Bool?
        let showSavedThisMonthQuickStat: Bool?
    }

    struct SavingsEntryDTO: Codable, Equatable {
        let id: UUID
        let amount: DecimalValue
        let date: Date
        let createdAt: Date
        let updatedAt: Date
    }

    struct ScheduledTransferDTO: Codable, Equatable {
        let id: UUID
        let amount: DecimalValue
        let timing: String
        let sourceAccountId: UUID?
        let sourceConnectedAccountId: String?
        let destinationAccountId: UUID?
        let destinationConnectedAccountId: String?
        let isActive: Bool
        let note: String
        let createdAt: Date
        let updatedAt: Date
        let lastPostedMonth: Date?
    }

    struct FavoritesDTO: Codable, Equatable {
        let id: UUID
        let orderedDestinationIDs: [String]
        let updatedAt: Date
        let checkingRegisterAccountID: UUID?
    }

    struct QuickStatsDTO: Codable, Equatable {
        let id: UUID
        let hiddenRawIDs: [String]
        let updatedAt: Date
    }

    struct OnboardingDTO: Codable, Equatable {
        let id: UUID
        let hasCompletedOnboarding: Bool
        let selectedPathRawValue: String?
        let updatedAt: Date
    }

    var transactions: [TransactionExtra]
    var accounts: [AccountExtra]
    var incomeSources: [IncomeSourceExtra]
    var budgetSettings: [BudgetSettingsExtra]
    var savingsEntries: [SavingsEntryDTO]
    var scheduledTransfers: [ScheduledTransferDTO]
    var favorites: [FavoritesDTO]
    var quickStats: [QuickStatsDTO]
    var onboarding: [OnboardingDTO]
    /// Connected-account display names, keyed by their full `UserDefaults` key.
    var connectedAccountAliases: [String: String]
    /// Remembered Add Expense option choices per account and type, keyed by their full `UserDefaults` key.
    var transactionEntryPreferences: [String: Data]

    init(
        transactions: [TransactionExtra] = [], accounts: [AccountExtra] = [],
        incomeSources: [IncomeSourceExtra] = [], budgetSettings: [BudgetSettingsExtra] = [],
        savingsEntries: [SavingsEntryDTO] = [], scheduledTransfers: [ScheduledTransferDTO] = [],
        favorites: [FavoritesDTO] = [], quickStats: [QuickStatsDTO] = [], onboarding: [OnboardingDTO] = [],
        connectedAccountAliases: [String: String] = [:],
        transactionEntryPreferences: [String: Data] = [:]
    ) {
        self.transactions = transactions
        self.accounts = accounts
        self.incomeSources = incomeSources
        self.budgetSettings = budgetSettings
        self.savingsEntries = savingsEntries
        self.scheduledTransfers = scheduledTransfers
        self.favorites = favorites
        self.quickStats = quickStats
        self.onboarding = onboarding
        self.connectedAccountAliases = connectedAccountAliases
        self.transactionEntryPreferences = transactionEntryPreferences
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transactions = try c.decodeIfPresent([TransactionExtra].self, forKey: .transactions) ?? []
        accounts = try c.decodeIfPresent([AccountExtra].self, forKey: .accounts) ?? []
        incomeSources = try c.decodeIfPresent([IncomeSourceExtra].self, forKey: .incomeSources) ?? []
        budgetSettings = try c.decodeIfPresent([BudgetSettingsExtra].self, forKey: .budgetSettings) ?? []
        savingsEntries = try c.decodeIfPresent([SavingsEntryDTO].self, forKey: .savingsEntries) ?? []
        scheduledTransfers = try c.decodeIfPresent([ScheduledTransferDTO].self, forKey: .scheduledTransfers) ?? []
        favorites = try c.decodeIfPresent([FavoritesDTO].self, forKey: .favorites) ?? []
        quickStats = try c.decodeIfPresent([QuickStatsDTO].self, forKey: .quickStats) ?? []
        onboarding = try c.decodeIfPresent([OnboardingDTO].self, forKey: .onboarding) ?? []
        connectedAccountAliases = try c.decodeIfPresent([String: String].self, forKey: .connectedAccountAliases) ?? [:]
        transactionEntryPreferences = try c.decodeIfPresent([String: Data].self, forKey: .transactionEntryPreferences) ?? [:]
    }
}

extension SpendSmartBackupService {

    // MARK: - Export

    @MainActor
    static func makeExtras(context: ModelContext, defaults: UserDefaults = .standard) throws -> BackupExtras {
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let externalIdById = Dictionary(
            transactions.compactMap { transaction in transaction.externalTransactionId.map { (transaction.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        var extras = BackupExtras()
        extras.transactions = transactions.map {
            BackupExtras.TransactionExtra(
                id: $0.id,
                linkedRecurringExpenseId: $0.linkedRecurringExpense?.id,
                isOneTimeBillEntry: $0.isOneTimeBillEntry,
                billTiming: $0.billTiming?.rawValue,
                transferCounterpartyAccountId: $0.transferCounterpartyAccount?.id,
                transferCounterpartyPlaidAccountId: $0.transferCounterpartyPlaidAccountId,
                isPaymentConfirmed: $0.isPaymentConfirmed
            )
        }
        extras.accounts = try context.fetch(FetchDescriptor<Account>()).map {
            BackupExtras.AccountExtra(id: $0.id, showsInRecentActivity: $0.showsInRecentActivity)
        }
        extras.incomeSources = try context.fetch(FetchDescriptor<IncomeSource>()).map {
            BackupExtras.IncomeSourceExtra(
                id: $0.id,
                monthlyDepositDayIsLastDay: $0.monthlyDepositDayIsLastDay,
                twiceMonthlyFirstDayNumber: $0.twiceMonthlyFirstDayNumber,
                twiceMonthlyFirstDayIsLastDay: $0.twiceMonthlyFirstDayIsLastDay,
                twiceMonthlySecondDayNumber: $0.twiceMonthlySecondDayNumber,
                twiceMonthlySecondDayIsLastDay: $0.twiceMonthlySecondDayIsLastDay
            )
        }
        extras.budgetSettings = try context.fetch(FetchDescriptor<BudgetSettings>()).map { settings in
            BackupExtras.BudgetSettingsExtra(
                id: settings.id,
                cloudBackupRetentionDays: settings.cloudBackupRetentionDays,
                autoCalculateConnectedAccountIds: settings.autoCalculateConnectedAccountIds,
                excludeTransactionsEnabled: settings.excludeTransactionsEnabled,
                excludedTransactions: (settings.excludedTransactionIDs ?? []).map {
                    BackupExtras.ExcludedTransaction(id: $0, externalTransactionId: externalIdById[$0])
                },
                showMonthlySpendingQuickStat: settings.showMonthlySpendingQuickStat,
                showSavedThisMonthQuickStat: settings.showSavedThisMonthQuickStat
            )
        }
        extras.savingsEntries = try context.fetch(FetchDescriptor<SavingsEntry>()).map {
            BackupExtras.SavingsEntryDTO(id: $0.id, amount: .init($0.amount), date: $0.date, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        extras.scheduledTransfers = try context.fetch(FetchDescriptor<ScheduledTransfer>()).map {
            BackupExtras.ScheduledTransferDTO(
                id: $0.id, amount: .init($0.amount), timing: $0.timing.rawValue,
                sourceAccountId: $0.sourceAccount?.id, sourceConnectedAccountId: $0.sourceConnectedAccountId,
                destinationAccountId: $0.destinationAccount?.id, destinationConnectedAccountId: $0.destinationConnectedAccountId,
                isActive: $0.isActive, note: $0.note, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                lastPostedMonth: $0.lastPostedMonth
            )
        }
        extras.favorites = try context.fetch(FetchDescriptor<FavoritesSettings>()).map {
            BackupExtras.FavoritesDTO(id: $0.id, orderedDestinationIDs: $0.orderedDestinationIDs, updatedAt: $0.updatedAt, checkingRegisterAccountID: $0.checkingRegisterAccountID)
        }
        extras.quickStats = try context.fetch(FetchDescriptor<QuickStatsSettings>()).map {
            BackupExtras.QuickStatsDTO(id: $0.id, hiddenRawIDs: $0.hiddenRawIDs, updatedAt: $0.updatedAt)
        }
        extras.onboarding = try context.fetch(FetchDescriptor<OnboardingSettings>()).map {
            BackupExtras.OnboardingDTO(id: $0.id, hasCompletedOnboarding: $0.hasCompletedOnboarding, selectedPathRawValue: $0.selectedPathRawValue, updatedAt: $0.updatedAt)
        }
        extras.connectedAccountAliases = defaults.dictionaryRepresentation().reduce(into: [:]) { result, entry in
            if entry.key.hasPrefix(ConnectedAccountAliasStore.keyPrefix), let value = entry.value as? String {
                result[entry.key] = value
            }
        }
        extras.transactionEntryPreferences = defaults.dictionaryRepresentation().reduce(into: [:]) { result, entry in
            if entry.key.hasPrefix(TransactionPreferenceStore.keyPrefix), let value = entry.value as? Data {
                result[entry.key] = value
            }
        }
        return extras
    }

    // MARK: - Restore

    /// Applies the extras onto records the main restore has already recreated and saved: re-links
    /// bills and transfer accounts, restores settings and exclusions, and recreates the models the
    /// original format never carried. Replace-all, like the main restore.
    @MainActor
    static func applyExtras(_ extras: BackupExtras, into context: ModelContext, defaults: UserDefaults = .standard) throws {
        try context.delete(model: SavingsEntry.self)
        try context.delete(model: ScheduledTransfer.self)
        try context.delete(model: FavoritesSettings.self)
        try context.delete(model: QuickStatsSettings.self)
        try context.delete(model: OnboardingSettings.self)

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let accountsById = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let transactionsById = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let transactionsByExternalId = Dictionary(
            transactions.compactMap { transaction in transaction.externalTransactionId.map { ($0, transaction) } },
            uniquingKeysWith: { first, _ in first }
        )
        let expenses = try context.fetch(FetchDescriptor<RecurringExpense>())
        let expensesById = Dictionary(expenses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for extra in extras.accounts {
            accountsById[extra.id]?.showsInRecentActivity = extra.showsInRecentActivity
        }
        for extra in extras.transactions {
            guard let transaction = transactionsById[extra.id] else { continue }
            transaction.linkedRecurringExpense = extra.linkedRecurringExpenseId.flatMap { expensesById[$0] }
            transaction.isOneTimeBillEntry = extra.isOneTimeBillEntry
            transaction.billTiming = extra.billTiming.flatMap(PlanTiming.init(rawValue:))
            transaction.transferCounterpartyAccount = extra.transferCounterpartyAccountId.flatMap { accountsById[$0] }
            transaction.transferCounterpartyPlaidAccountId = extra.transferCounterpartyPlaidAccountId
            transaction.isPaymentConfirmed = extra.isPaymentConfirmed
        }

        let incomeSources = try context.fetch(FetchDescriptor<IncomeSource>())
        let incomeById = Dictionary(incomeSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for extra in extras.incomeSources {
            guard let source = incomeById[extra.id] else { continue }
            source.monthlyDepositDayIsLastDay = extra.monthlyDepositDayIsLastDay
            source.twiceMonthlyFirstDayNumber = extra.twiceMonthlyFirstDayNumber
            source.twiceMonthlyFirstDayIsLastDay = extra.twiceMonthlyFirstDayIsLastDay
            source.twiceMonthlySecondDayNumber = extra.twiceMonthlySecondDayNumber
            source.twiceMonthlySecondDayIsLastDay = extra.twiceMonthlySecondDayIsLastDay
        }

        let settingsList = try context.fetch(FetchDescriptor<BudgetSettings>())
        let settingsById = Dictionary(settingsList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for extra in extras.budgetSettings {
            guard let settings = settingsById[extra.id] else { continue }
            settings.cloudBackupRetentionDays = extra.cloudBackupRetentionDays
            settings.autoCalculateConnectedAccountIds = extra.autoCalculateConnectedAccountIds
            settings.excludeTransactionsEnabled = extra.excludeTransactionsEnabled
            settings.showMonthlySpendingQuickStat = extra.showMonthlySpendingQuickStat
            settings.showSavedThisMonthQuickStat = extra.showSavedThisMonthQuickStat
            settings.excludedTransactionIDs = extra.excludedTransactions.map { excluded in
                if transactionsById[excluded.id] != nil { return excluded.id }
                if let external = excluded.externalTransactionId, let match = transactionsByExternalId[external] { return match.id }
                return excluded.id
            }
        }

        for dto in extras.savingsEntries {
            context.insert(SavingsEntry(id: dto.id, amount: dto.amount.value, date: dto.date, createdAt: dto.createdAt, updatedAt: dto.updatedAt))
        }
        for dto in extras.scheduledTransfers {
            context.insert(ScheduledTransfer(
                id: dto.id, amount: dto.amount.value, timing: PlanTiming(rawValue: dto.timing) ?? .beginningMonth,
                sourceAccount: dto.sourceAccountId.flatMap { accountsById[$0] }, sourceConnectedAccountId: dto.sourceConnectedAccountId,
                destinationAccount: dto.destinationAccountId.flatMap { accountsById[$0] }, destinationConnectedAccountId: dto.destinationConnectedAccountId,
                isActive: dto.isActive, note: dto.note, createdAt: dto.createdAt, updatedAt: dto.updatedAt, lastPostedMonth: dto.lastPostedMonth
            ))
        }
        for dto in extras.favorites {
            context.insert(FavoritesSettings(id: dto.id, orderedDestinationIDs: dto.orderedDestinationIDs, updatedAt: dto.updatedAt, checkingRegisterAccountID: dto.checkingRegisterAccountID))
        }
        for dto in extras.quickStats {
            context.insert(QuickStatsSettings(id: dto.id, hiddenRawIDs: dto.hiddenRawIDs, updatedAt: dto.updatedAt))
        }
        for dto in extras.onboarding {
            context.insert(OnboardingSettings(id: dto.id, hasCompletedOnboarding: dto.hasCompletedOnboarding, selectedPathRawValue: dto.selectedPathRawValue, updatedAt: dto.updatedAt))
        }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(ConnectedAccountAliasStore.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in extras.connectedAccountAliases where key.hasPrefix(ConnectedAccountAliasStore.keyPrefix) {
            defaults.set(value, forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(TransactionPreferenceStore.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in extras.transactionEntryPreferences where key.hasPrefix(TransactionPreferenceStore.keyPrefix) {
            defaults.set(value, forKey: key)
        }

        try context.save()
    }
}
