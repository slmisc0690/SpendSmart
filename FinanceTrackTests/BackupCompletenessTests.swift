import XCTest
import SwiftData
@testable import FinanceTrack

/// The backup must carry everything that lives only on the device, restore it exactly, and refuse
/// to let a damaged store overwrite a good backup.
@MainActor
final class BackupCompletenessTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Account.self, FinanceTransaction.self, BudgetSettings.self, Category.self, IncomeSource.self,
            RecurringExpense.self, MonthlyPlanSettings.self, PendingCloudDeletion.self, SavingsEntry.self,
            FavoritesSettings.self, QuickStatsSettings.self, OnboardingSettings.self, ScheduledTransfer.self,
        ])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        return ModelContext(container)
    }

    private let aliasKey = "\(ConnectedAccountAliasStore.keyPrefix).test-backup-account"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: aliasKey)
        super.tearDown()
    }

    // MARK: Round trip of everything device-only

    func testEverythingDeviceOnlySurvivesBackupAndRestore() throws {
        let source = try makeContext()
        let checking = Account(name: "Checking", type: .checking, showsInRecentActivity: false)
        let savings = Account(name: "Savings", type: .savings)
        source.insert(checking); source.insert(savings)
        let bill = RecurringExpense(name: "Mortgage", amount: 2167, timing: .beginningMonth)
        source.insert(bill)
        let payment = FinanceTransaction(amount: 2167, type: .expense, account: checking, linkedRecurringExpense: bill,
                                         isOneTimeBillEntry: true, billTiming: .midMonth, isPaymentConfirmed: true)
        let toChecking = FinanceTransaction(amount: 1000, type: .transferDeposit, account: checking, transferCounterpartyAccount: savings)
        let bankRow = FinanceTransaction(amount: 55, type: .expense, source: .plaid, externalTransactionId: "plaid-123", plaidAccountId: "amex-1")
        [payment, toChecking, bankRow].forEach(source.insert)
        let settings = BudgetSettings()
        settings.autoCalculateConnectedAccountIds = ["amex-1"]
        settings.excludeTransactionsEnabled = true
        settings.excludedTransactionIDs = [bankRow.id]
        settings.cloudBackupRetentionDays = 21
        source.insert(settings)
        source.insert(SavingsEntry(amount: 300))
        source.insert(ScheduledTransfer(amount: 25, timing: .midMonth, sourceAccount: checking, destinationAccount: savings, note: "monthly"))
        source.insert(FavoritesSettings(orderedDestinationIDs: ["monthlyPlan"], checkingRegisterAccountID: checking.id))
        source.insert(QuickStatsSettings(hiddenRawIDs: ["savedThisMonth"]))
        source.insert(OnboardingSettings(hasCompletedOnboarding: true, selectedPathRawValue: "plan"))
        UserDefaults.standard.set("Wells Savings", forKey: aliasKey)
        try source.save()

        let data = try SpendSmartBackupService.encode(try SpendSmartBackupService.fetchAndMakeDocument(context: source))
        UserDefaults.standard.removeObject(forKey: aliasKey)

        let target = try makeContext()
        try SpendSmartBackupService.restore(try SpendSmartBackupService.decode(data), into: target)

        let restoredPayment = try XCTUnwrap(target.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == payment.id })
        XCTAssertEqual(restoredPayment.linkedRecurringExpense?.id, bill.id)
        XCTAssertTrue(restoredPayment.isOneTimeBillEntry)
        XCTAssertEqual(restoredPayment.billTiming, .midMonth)
        XCTAssertTrue(restoredPayment.isPaymentConfirmed)
        let restoredTransfer = try XCTUnwrap(target.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == toChecking.id })
        XCTAssertEqual(restoredTransfer.transferCounterpartyAccount?.id, savings.id)

        let restoredSettings = try XCTUnwrap(target.fetch(FetchDescriptor<BudgetSettings>()).first)
        XCTAssertEqual(restoredSettings.autoCalculateConnectedAccountIds, ["amex-1"])
        XCTAssertEqual(restoredSettings.excludeTransactionsEnabled, true)
        XCTAssertEqual(restoredSettings.excludedTransactionIDs, [bankRow.id])
        XCTAssertEqual(restoredSettings.cloudBackupRetentionDays, 21)

        XCTAssertEqual(try target.fetch(FetchDescriptor<Account>()).first { $0.id == checking.id }?.showsInRecentActivity, false)
        XCTAssertEqual(try target.fetch(FetchDescriptor<SavingsEntry>()).first?.amount, 300)
        let transfer = try XCTUnwrap(target.fetch(FetchDescriptor<ScheduledTransfer>()).first)
        XCTAssertEqual(transfer.sourceAccount?.id, checking.id)
        XCTAssertEqual(transfer.destinationAccount?.id, savings.id)
        XCTAssertEqual(try target.fetch(FetchDescriptor<FavoritesSettings>()).first?.orderedDestinationIDs, ["monthlyPlan"])
        XCTAssertEqual(try target.fetch(FetchDescriptor<QuickStatsSettings>()).first?.hiddenRawIDs, ["savedThisMonth"])
        XCTAssertEqual(try target.fetch(FetchDescriptor<OnboardingSettings>()).first?.hasCompletedOnboarding, true)
        XCTAssertEqual(UserDefaults.standard.string(forKey: aliasKey), "Wells Savings")
    }

    func testExclusionIsRematchedByBankIdWhenTheLocalIdChanged() throws {
        let context = try makeContext()
        let reimported = FinanceTransaction(amount: 40, type: .expense, source: .plaid, externalTransactionId: "plaid-777", plaidAccountId: "amex-1")
        context.insert(reimported)
        let settings = BudgetSettings()
        context.insert(settings)
        try context.save()

        let oldLocalId = UUID()
        var extras = BackupExtras()
        extras.budgetSettings = [BackupExtras.BudgetSettingsExtra(
            id: settings.id, cloudBackupRetentionDays: nil, autoCalculateConnectedAccountIds: nil, excludeTransactionsEnabled: true,
            excludedTransactions: [.init(id: oldLocalId, externalTransactionId: "plaid-777")],
            showMonthlySpendingQuickStat: nil, showSavedThisMonthQuickStat: nil
        )]
        try SpendSmartBackupService.applyExtras(extras, into: context)

        XCTAssertEqual(settings.excludedTransactionIDs, [reimported.id])
    }

    func testOldBackupWithoutExtrasStillDecodesAndKeepsExistingSavedEntries() throws {
        let context = try makeContext()
        context.insert(SavingsEntry(amount: 50))
        try context.save()
        let document = SpendSmartBackupService.makeDocument(
            accounts: [], transactions: [], categories: [], budgetSettings: [], monthlyPlanSettings: [], incomeSources: [], recurringExpenses: []
        )
        XCTAssertNil(document.extras)
        let decoded = try SpendSmartBackupService.decode(try SpendSmartBackupService.encode(document))
        XCTAssertNil(decoded.extras)
        try SpendSmartBackupService.restore(decoded, into: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavingsEntry>()).count, 1)
    }

    // MARK: Safety guard

    private func document(transactions: Int, accounts: Int = 2, settings: Int = 1, extras: Bool = true) -> SpendSmartBackupService.Document {
        let account = Account(name: "A", type: .checking)
        var document = SpendSmartBackupService.makeDocument(
            accounts: (0..<accounts).map { _ in account },
            transactions: (0..<transactions).map { _ in FinanceTransaction(amount: 1, type: .expense) },
            categories: [], budgetSettings: (0..<settings).map { _ in BudgetSettings() },
            monthlyPlanSettings: [], incomeSources: [], recurringExpenses: []
        )
        document.extras = extras ? BackupExtras() : nil
        return document
    }

    func testGuardRejectsAnEmptyStore() {
        XCTAssertFalse(BackupSafetyGuard.evaluate(new: document(transactions: 0, accounts: 0, settings: 0), previous: nil).isAllowed)
        XCTAssertFalse(BackupSafetyGuard.evaluate(new: document(transactions: 0, accounts: 0, settings: 0), previous: document(transactions: 500)).isAllowed)
    }

    func testGuardRejectsABackupThatShrankByMoreThanHalf() {
        XCTAssertFalse(BackupSafetyGuard.evaluate(new: document(transactions: 100), previous: document(transactions: 500)).isAllowed)
    }

    func testGuardRejectsMissingAccountsSettingsOrExtras() {
        let good = document(transactions: 500)
        XCTAssertFalse(BackupSafetyGuard.evaluate(new: document(transactions: 500, accounts: 0), previous: good).isAllowed)
        XCTAssertFalse(BackupSafetyGuard.evaluate(new: document(transactions: 500, settings: 0), previous: good).isAllowed)
        XCTAssertFalse(BackupSafetyGuard.evaluate(new: document(transactions: 500, extras: false), previous: good).isAllowed)
    }

    func testGuardAllowsNormalGrowthAndTheFirstBackup() {
        XCTAssertTrue(BackupSafetyGuard.evaluate(new: document(transactions: 520), previous: document(transactions: 500)).isAllowed)
        XCTAssertTrue(BackupSafetyGuard.evaluate(new: document(transactions: 10), previous: nil).isAllowed)
        XCTAssertTrue(BackupSafetyGuard.evaluate(new: document(transactions: 300), previous: document(transactions: 500)).isAllowed)
    }

    // MARK: Protected copies

    func testDailyBackupsKeepTheRequestedNumberOfDaysAndAreNotAutoRotated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = document(transactions: 5)
        for day in 0..<20 {
            try SpendSmartBackupService.writeDailyBackup(doc, to: directory, retentionDays: 14, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
        }
        let daily = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(SpendSmartBackupService.dailyBackupFilenamePrefix) }
        XCTAssertEqual(daily.count, 14)
        try SpendSmartBackupService.pruneAutoBackups(in: directory, keepingLatest: 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(SpendSmartBackupService.dailyBackupFilenamePrefix) }.count, 14)
    }

    func testPreRestoreBackupIsWrittenBeforeARestore() throws {
        let context = try makeContext()
        context.insert(Account(name: "Checking", type: .checking))
        context.insert(BudgetSettings())
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try SpendSmartBackupService.writePreRestoreBackup(context: context, to: directory)
        XCTAssertTrue(url.lastPathComponent.hasPrefix(SpendSmartBackupService.preRestoreBackupFilenamePrefix))
        XCTAssertEqual(try SpendSmartBackupService.decode(Data(contentsOf: url)).accounts.count, 1)
    }
}
