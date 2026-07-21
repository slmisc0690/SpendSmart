import XCTest
import SwiftData
@testable import FinanceTrack

/// Phase 3 — per-user local SwiftData isolation, ownerUserID backfill, legacy-data migration,
/// and per-user Plaid UserDefaults namespacing. Every test here uses either an in-memory SwiftData
/// store or a throwaway temp-directory-backed store, and a uniquely-suited `UserDefaults` — never
/// this device's real Application Support directory or `UserDefaults.standard`.
@MainActor
final class UserDataIsolationTests: XCTestCase {

    // MARK: - Shared test helpers

    private static let schema = Schema([
        Account.self,
        FinanceTransaction.self,
        BudgetSettings.self,
        Category.self,
        IncomeSource.self,
        RecurringExpense.self,
        MonthlyPlanSettings.self,
    ])

    private func makeInMemoryContext() -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Self.schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeInMemoryContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: Self.schema, configurations: [config])
    }

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserDataIsolationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTestDefaults() -> UserDefaults {
        UserDefaults(suiteName: "UserDataIsolationTests.\(UUID().uuidString)")!
    }

    // MARK: - Per-user store path

    func testStoreURLIsStableForSameUserAndDistinctForDifferentUsers() throws {
        let manager = UserDataStoreManager(
            defaults: makeTestDefaults(),
            userStoresBaseDirectoryOverride: makeTempDirectory()
        )
        let userA = UUID()
        let userB = UUID()

        let firstCallForA = try manager.storeURL(for: userA)
        let secondCallForA = try manager.storeURL(for: userA)
        let callForB = try manager.storeURL(for: userB)

        XCTAssertEqual(firstCallForA, secondCallForA, "the same UID must always resolve to the same store URL")
        XCTAssertNotEqual(firstCallForA, callForB, "different UIDs must resolve to different store URLs")
    }

    // MARK: - Full resolve() isolation / user switching / detach

    func testResolveCreatesIsolatedStoresPerUser() async throws {
        let manager = UserDataStoreManager(
            defaults: makeTestDefaults(),
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: { self.makeInMemoryContainer() }
        )
        let userA = UUID()
        let userB = UUID()

        await manager.resolve(for: userA)
        let containerA = try XCTUnwrap(manager.modelContainer)
        let contextA = ModelContext(containerA)
        contextA.insert(Account(name: "User A's Checking", type: .checking, currentBalance: 500))
        try contextA.save()

        manager.detach()
        await manager.resolve(for: userB)
        let containerB = try XCTUnwrap(manager.modelContainer)

        let accountsInB = try ModelContext(containerB).fetch(FetchDescriptor<Account>())
        XCTAssertTrue(accountsInB.isEmpty, "User B must not see any row from User A's isolated store")

        manager.detach()
        await manager.resolve(for: userA)
        let containerAAgain = try XCTUnwrap(manager.modelContainer)
        let accountsInAAgain = try ModelContext(containerAAgain).fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accountsInAAgain.count, 1, "returning to User A must find their data intact")
        XCTAssertEqual(accountsInAAgain.first?.name, "User A's Checking")
    }

    func testUserSwitchDoesNotReuseModelContainer() async throws {
        let manager = UserDataStoreManager(
            defaults: makeTestDefaults(),
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: { self.makeInMemoryContainer() }
        )
        let userA = UUID()
        let userB = UUID()

        await manager.resolve(for: userA)
        let containerA = try XCTUnwrap(manager.modelContainer)

        manager.detach()
        await manager.resolve(for: userB)
        let containerB = try XCTUnwrap(manager.modelContainer)

        XCTAssertTrue(containerA !== containerB, "switching users must never reuse the previous user's ModelContainer instance")
    }

    func testDetachClearsInMemoryStateWithoutDeletingStoreFile() async throws {
        let manager = UserDataStoreManager(
            defaults: makeTestDefaults(),
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: { self.makeInMemoryContainer() }
        )
        let userA = UUID()

        await manager.resolve(for: userA)
        let storeURL = try manager.storeURL(for: userA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path), "the store file must exist after a successful resolve")

        manager.detach()

        XCTAssertNil(manager.modelContainer)
        XCTAssertNil(manager.plaidConnectionManager)
        XCTAssertNil(manager.resolvedUserId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path), "sign-out (detach) must never delete the user's on-disk store")
    }

    // MARK: - Legacy claim marker: single-claim, no re-claim by a second user, no premature success

    func testResolveClaimsLegacyDataOnceForFirstUser() async throws {
        let legacyContext = makeInMemoryContext()
        legacyContext.insert(Account(name: "Legacy Checking", type: .checking, currentBalance: 250))
        try legacyContext.save()
        let legacyContainer = legacyContext.container

        let defaults = makeTestDefaults()
        let manager = UserDataStoreManager(
            defaults: defaults,
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: { legacyContainer }
        )
        let userA = UUID()

        await manager.resolve(for: userA)

        let container = try XCTUnwrap(manager.modelContainer)
        let accounts = try ModelContext(container).fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.name, "Legacy Checking")
        XCTAssertEqual(accounts.first?.ownerUserID, userA)
        XCTAssertEqual(defaults.string(forKey: "legacyMigration.claimedByUserID"), userA.uuidString)
    }

    func testResolveDoesNotReclaimLegacyDataForSecondUser() async throws {
        let legacyContext = makeInMemoryContext()
        legacyContext.insert(Account(name: "Legacy Checking", type: .checking, currentBalance: 250))
        try legacyContext.save()
        let legacyContainer = legacyContext.container

        let defaults = makeTestDefaults()
        let manager = UserDataStoreManager(
            defaults: defaults,
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: { legacyContainer }
        )
        let userA = UUID()
        let userB = UUID()

        await manager.resolve(for: userA)
        manager.detach()
        await manager.resolve(for: userB)

        let container = try XCTUnwrap(manager.modelContainer)
        let accounts = try ModelContext(container).fetch(FetchDescriptor<Account>())
        XCTAssertTrue(accounts.isEmpty, "a second user must never receive the first user's already-claimed legacy data")
        XCTAssertEqual(defaults.string(forKey: "legacyMigration.claimedByUserID"), userA.uuidString, "the claim marker must still name the original claiming user")
    }

    func testFailedLegacyClaimDoesNotMarkCompletionPrematurelyAndRetriesSucceed() async throws {
        struct InjectedFailure: Error {}
        let defaults = makeTestDefaults()
        var shouldFail = true
        let manager = UserDataStoreManager(
            defaults: defaults,
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: {
                if shouldFail { throw InjectedFailure() }
                return self.makeInMemoryContainer()
            }
        )
        let userA = UUID()

        await manager.resolve(for: userA)
        XCTAssertNil(defaults.string(forKey: "legacyMigration.claimedByUserID"), "an interrupted/failed migration must never mark the claim as complete")
        XCTAssertNotNil(manager.lastResolutionError)
        XCTAssertNil(manager.modelContainer)

        shouldFail = false
        await manager.resolve(for: userA)
        XCTAssertEqual(defaults.string(forKey: "legacyMigration.claimedByUserID"), userA.uuidString, "a later successful retry must complete normally")
        XCTAssertNotNil(manager.modelContainer)
    }

    // MARK: - LegacyDataMigrator (pure, direct)

    func testLegacyDataMigratorCopiesAllModelTypesAndSetsOwnerOnlyOnEligibleTypes() throws {
        let legacy = makeInMemoryContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        let category = Category(name: "Groceries")
        legacy.insert(account)
        legacy.insert(category)
        legacy.insert(FinanceTransaction(amount: 42, note: "Trader Joe's", account: account, category: category))
        legacy.insert(IncomeSource(name: "Paycheck", amount: 2000))
        legacy.insert(RecurringExpense(name: "Rent", amount: 1200, category: category, paymentAccount: account))
        legacy.insert(BudgetSettings(weeklySpendingLimit: 300))
        legacy.insert(MonthlyPlanSettings(monthlySavingsGoal: 500))
        try legacy.save()

        let destination = makeInMemoryContext()
        let userId = UUID()
        try LegacyDataMigrator.migrate(from: legacy, into: destination, ownerUserID: userId)

        XCTAssertEqual(try destination.fetch(FetchDescriptor<Account>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<FinanceTrack.Category>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<FinanceTransaction>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<IncomeSource>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<RecurringExpense>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<BudgetSettings>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<MonthlyPlanSettings>()).count, 1)

        XCTAssertEqual(try destination.fetch(FetchDescriptor<Account>()).first?.ownerUserID, userId)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<FinanceTransaction>()).first?.ownerUserID, userId)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<IncomeSource>()).first?.ownerUserID, userId)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<RecurringExpense>()).first?.ownerUserID, userId)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<MonthlyPlanSettings>()).first?.ownerUserID, userId)

        // BudgetSettings/Category have no ownerUserID field at all — this simply confirms the
        // migrator didn't crash/skip them, their absence of the field is enforced by the compiler.
        XCTAssertNotNil(try destination.fetch(FetchDescriptor<BudgetSettings>()).first)
        XCTAssertNotNil(try destination.fetch(FetchDescriptor<FinanceTrack.Category>()).first)
    }

    func testLegacyDataMigratorPreservesRelationships() throws {
        let legacy = makeInMemoryContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        let category = Category(name: "Groceries")
        let transaction = FinanceTransaction(amount: 42, note: "Trader Joe's", account: account, category: category)
        legacy.insert(account)
        legacy.insert(category)
        legacy.insert(transaction)
        try legacy.save()

        let destination = makeInMemoryContext()
        try LegacyDataMigrator.migrate(from: legacy, into: destination, ownerUserID: UUID())

        let copiedTransaction = try XCTUnwrap(destination.fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertEqual(copiedTransaction.account?.id, account.id)
        XCTAssertEqual(copiedTransaction.category?.id, category.id)
        XCTAssertTrue(copiedTransaction.account !== account, "the copied transaction must reference the NEW destination-context Account, never the legacy-context instance")
    }

    func testLegacyDataMigratorIsIdempotentNoDuplicatesOnSecondRun() throws {
        let legacy = makeInMemoryContext()
        legacy.insert(Account(name: "Checking", type: .checking, currentBalance: 100))
        try legacy.save()

        let destination = makeInMemoryContext()
        let userId = UUID()
        try LegacyDataMigrator.migrate(from: legacy, into: destination, ownerUserID: userId)
        try LegacyDataMigrator.migrate(from: legacy, into: destination, ownerUserID: userId)

        XCTAssertEqual(try destination.fetch(FetchDescriptor<Account>()).count, 1, "running the migrator twice must never duplicate rows")
    }

    // MARK: - OwnerUserIDBackfill

    func testOwnerUserIDBackfillAssignsOwnerOnlyToNilOwnerRows() throws {
        let context = makeInMemoryContext()
        let alreadyOwned = Account(name: "Already Owned", type: .checking, currentBalance: 1)
        let existingOwner = UUID()
        alreadyOwned.ownerUserID = existingOwner
        let nilOwned = Account(name: "Needs Backfill", type: .checking, currentBalance: 2)
        context.insert(alreadyOwned)
        context.insert(nilOwned)
        try context.save()

        let currentUser = UUID()
        try OwnerUserIDBackfill.run(in: context, ownerUserID: currentUser)

        XCTAssertEqual(alreadyOwned.ownerUserID, existingOwner, "a row that already carries an owner must never be reassigned")
        XCTAssertEqual(nilOwned.ownerUserID, currentUser, "a nil-owner row must be backfilled to the current authenticated user")
    }

    func testOwnerUserIDBackfillIsIdempotent() throws {
        let context = makeInMemoryContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 1)
        context.insert(account)
        try context.save()

        let userId = UUID()
        try OwnerUserIDBackfill.run(in: context, ownerUserID: userId)
        try OwnerUserIDBackfill.run(in: context, ownerUserID: userId)

        XCTAssertEqual(account.ownerUserID, userId)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Account>()).count, 1)
    }

    // MARK: - PlaidConnectionManager per-user namespacing

    func testPlaidConnectionManagerNamespacesIndependentlyByUserId() {
        let defaults = makeTestDefaults()
        let userA = UUID()
        let userB = UUID()

        let managerA = PlaidConnectionManager(defaults: defaults, userId: userA)
        managerA.addOrUpdate(connectionId: "conn-a", institutionId: nil, institutionName: "User A's Bank")

        let managerB = PlaidConnectionManager(defaults: defaults, userId: userB)

        XCTAssertEqual(managerA.connections.count, 1)
        XCTAssertTrue(managerB.connections.isEmpty, "a different user's namespace must start empty even though the same UserDefaults suite is shared")

        // Re-loading User A's manager from the same defaults must still see their own data.
        let managerAReloaded = PlaidConnectionManager(defaults: defaults, userId: userA)
        XCTAssertEqual(managerAReloaded.connections.count, 1)
        XCTAssertEqual(managerAReloaded.connections.first?.institutionName, "User A's Bank")
    }

    func testMigrateFlatConnectionsIfNeededCopiesOnceAndIsIdempotent() {
        let defaults = makeTestDefaults()
        // Simulate the pre-Phase-3 flat (un-namespaced) state via a manager constructed with no
        // userId, exactly as the app always did before this phase.
        let flatManager = PlaidConnectionManager(defaults: defaults)
        flatManager.addOrUpdate(connectionId: "conn-legacy", institutionId: nil, institutionName: "American Express")

        let userA = UUID()
        let didCopy = PlaidConnectionManager.migrateFlatConnectionsIfNeeded(defaults: defaults, userId: userA)
        XCTAssertTrue(didCopy)

        let managerA = PlaidConnectionManager(defaults: defaults, userId: userA)
        XCTAssertEqual(managerA.connections.count, 1)
        XCTAssertEqual(managerA.connections.first?.institutionName, "American Express")

        // Mutate User A's namespaced copy, then attempt the copy again — must be a no-op and must
        // not clobber what's already there.
        managerA.addOrUpdate(connectionId: "conn-new", institutionId: nil, institutionName: "New Bank")
        let didCopyAgain = PlaidConnectionManager.migrateFlatConnectionsIfNeeded(defaults: defaults, userId: userA)
        XCTAssertFalse(didCopyAgain)

        let managerAReloaded = PlaidConnectionManager(defaults: defaults, userId: userA)
        XCTAssertEqual(managerAReloaded.connections.count, 2, "a second migration attempt must never overwrite data already in the namespaced key")
    }

    func testMigrateFlatConnectionsIfNeededDoesNotLeakToASecondUser() {
        let defaults = makeTestDefaults()
        let flatManager = PlaidConnectionManager(defaults: defaults)
        flatManager.addOrUpdate(connectionId: "conn-legacy", institutionId: nil, institutionName: "American Express")

        let userA = UUID()
        PlaidConnectionManager.migrateFlatConnectionsIfNeeded(defaults: defaults, userId: userA)

        // A second user's namespace must never be auto-populated just because the flat key has
        // data — only the caller-authorized (claim-marker-gated) first user may ever receive it.
        let userB = UUID()
        let managerB = PlaidConnectionManager(defaults: defaults, userId: userB)
        XCTAssertTrue(managerB.connections.isEmpty)
    }

    // MARK: - Local (network-free) Plaid stale-date repair on store resolve

    private func staleUTCMidnightJuly18() -> Date {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 18
        return utcCalendar.date(from: components)!
    }

    func testResolveRepairsStalePlaidDatesLocallyWithoutAnySync() async throws {
        // Proves the repair introduced for the "Dashboard Refresh never triggers a transaction
        // sync" gap: a stale-dated Plaid transaction already sitting in a user's store — exactly
        // the real-world shape (persisted BEFORE the local-midnight parser fix shipped, and
        // BEFORE this user's first resolve() under the new code) — must be corrected the moment
        // `resolve(for:)` attaches that store, with no `applySync`/network call anywhere in this
        // test. Seeded directly against the on-disk store URL, not via a first `resolve()` call —
        // seeding through `resolve()` itself would mark the user as already swept (even with zero
        // rows to repair) before the stale row ever existed, which would defeat the point of this
        // test (see `testResolveDoesNotReRepairAlreadySweptUser` for that scenario instead).
        let manager = UserDataStoreManager(
            defaults: makeTestDefaults(),
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: { self.makeInMemoryContainer() }
        )
        let userA = UUID()

        let storeURL = try manager.storeURL(for: userA)
        let seedConfig = ModelConfiguration(schema: Self.schema, url: storeURL)
        let seedContainer = try ModelContainer(for: Self.schema, configurations: [seedConfig])
        let seedContext = ModelContext(seedContainer)
        let staleDate = staleUTCMidnightJuly18()
        let stale = FinanceTransaction(
            amount: 25, date: staleDate, source: .plaid, externalTransactionId: "stale-resolve-row",
            authorizedDate: staleDate, postedDate: staleDate
        )
        seedContext.insert(stale)
        try seedContext.save()

        await manager.resolve(for: userA)

        let container = try XCTUnwrap(manager.modelContainer)
        let reloaded = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<FinanceTransaction>())
                .first { $0.externalTransactionId == "stale-resolve-row" }
        )
        XCTAssertEqual(Calendar.current.component(.day, from: reloaded.date), 18, "resolve(for:) must repair a stale Plaid date on its own, without any transaction sync")
    }

    func testResolveDoesNotReRepairAlreadySweptUser() async throws {
        let defaults = makeTestDefaults()
        let manager = UserDataStoreManager(
            defaults: defaults,
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: { self.makeInMemoryContainer() }
        )
        let userA = UUID()

        await manager.resolve(for: userA)
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "localPlaidDateRepair.completedUserIDs") ?? []),
            [userA.uuidString],
            "the first resolve must record this user as swept"
        )

        // Insert a stale row AFTER the one-time marker has already been set for this user — the
        // marker means resolve() won't sweep again, so this row is deliberately left uncorrected
        // by this test; it only exists to prove the second resolve() truly skips the sweep rather
        // than happening to find nothing to repair.
        let container = try XCTUnwrap(manager.modelContainer)
        let context = ModelContext(container)
        let staleDate = staleUTCMidnightJuly18()
        let stale = FinanceTransaction(
            amount: 25, date: staleDate, source: .plaid, externalTransactionId: "post-marker-stale-row",
            authorizedDate: staleDate, postedDate: staleDate
        )
        context.insert(stale)
        try context.save()

        manager.detach()
        await manager.resolve(for: userA)

        let reattachedContainer = try XCTUnwrap(manager.modelContainer)
        let reloaded = try XCTUnwrap(
            try ModelContext(reattachedContainer).fetch(FetchDescriptor<FinanceTransaction>())
                .first { $0.externalTransactionId == "post-marker-stale-row" }
        )
        XCTAssertEqual(reloaded.date, staleDate, "a user already recorded as swept must not be re-swept on a later resolve — the marker must actually gate the work")
    }

    func testLocalPlaidDateRepairMarkerIsPerUserNotGlobal() async throws {
        let manager = UserDataStoreManager(
            defaults: makeTestDefaults(),
            userStoresBaseDirectoryOverride: makeTempDirectory(),
            legacyContainerProvider: { self.makeInMemoryContainer() }
        )
        let userA = UUID()
        let userB = UUID()

        // User A resolves (and gets marked swept) FIRST, before User B's stale row even exists —
        // proves the marker set is genuinely keyed per-user, not a single "device has been swept"
        // flag that would incorrectly also cover User B.
        await manager.resolve(for: userA)
        manager.detach()

        let storeURLB = try manager.storeURL(for: userB)
        let seedConfig = ModelConfiguration(schema: Self.schema, url: storeURLB)
        let seedContainer = try ModelContainer(for: Self.schema, configurations: [seedConfig])
        let seedContext = ModelContext(seedContainer)
        let staleDate = staleUTCMidnightJuly18()
        let stale = FinanceTransaction(
            amount: 25, date: staleDate, source: .plaid, externalTransactionId: "user-b-stale-row",
            authorizedDate: staleDate, postedDate: staleDate
        )
        seedContext.insert(stale)
        try seedContext.save()

        // User B has never been swept, even though User A already has been — resolving B for the
        // first time must still repair B's own stale row.
        await manager.resolve(for: userB)

        let containerB = try XCTUnwrap(manager.modelContainer)
        let reloaded = try XCTUnwrap(
            try ModelContext(containerB).fetch(FetchDescriptor<FinanceTransaction>())
                .first { $0.externalTransactionId == "user-b-stale-row" }
        )
        XCTAssertEqual(Calendar.current.component(.day, from: reloaded.date), 18, "each user must get their own one-time repair sweep, independent of any other user already swept on this device")
    }
}
