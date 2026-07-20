import Foundation
import SwiftData

/// Copies every existing local SwiftData row from the pre-Phase-3 "legacy" (unscoped) store into
/// a specific authenticated user's newly isolated per-user store, exactly once per destination.
///
/// Record-level, not file-level: this repository has no `VersionedSchema`/`SchemaMigrationPlan`
/// infrastructure to lean on (confirmed by inspection — none exists anywhere in this codebase),
/// and a raw store-file/sidecar copy risks WAL/shm corruption with zero existing precedent to
/// build on. The legacy source context is only ever read from here — never inserted into, never
/// saved — so a failed or interrupted call can never lose or corrupt the legacy data.
///
/// Idempotent by construction: every row is matched into the destination by its own stable `id`,
/// never duplicated. `ownerUserID` is set only on rows this call itself inserts, on the 5
/// owner-eligible types (`Account`, `FinanceTransaction`, `IncomeSource`, `RecurringExpense`,
/// `MonthlyPlanSettings`) — an already-present destination row (from a prior successful run, or
/// created directly in the per-user store some other way) is never touched or overwritten.
enum LegacyDataMigrator {

    /// Copies all 7 model types from `legacyContext` into `destinationContext`. Relationships
    /// (`Account.transactions`/`FinanceTransaction.account`/`.category`/`.transferDestinationAccount`,
    /// `RecurringExpense.category`/`.paymentAccount`) are rewired against the newly created
    /// destination-context objects — a legacy-context object instance must never leak into
    /// `destinationContext`. Throws only if the final `destinationContext.save()` fails; a caller
    /// that catches an error and retries later is safe, since already-inserted-but-unsaved objects
    /// simply get saved on the next successful attempt and the id-based skip-if-present check
    /// prevents any duplicate on top of whatever a prior partial attempt already committed.
    static func migrate(
        from legacyContext: ModelContext,
        into destinationContext: ModelContext,
        ownerUserID userID: UUID
    ) throws {
        let categoryMap = try copyCategories(from: legacyContext, into: destinationContext)
        let accountMap = try copyAccounts(from: legacyContext, into: destinationContext, ownerUserID: userID)
        try copyFinanceTransactions(
            from: legacyContext,
            into: destinationContext,
            ownerUserID: userID,
            accountMap: accountMap,
            categoryMap: categoryMap
        )
        try copyRecurringExpenses(
            from: legacyContext,
            into: destinationContext,
            ownerUserID: userID,
            accountMap: accountMap,
            categoryMap: categoryMap
        )
        try copyIncomeSources(from: legacyContext, into: destinationContext, ownerUserID: userID)
        try copyBudgetSettings(from: legacyContext, into: destinationContext)
        try copyMonthlyPlanSettings(from: legacyContext, into: destinationContext, ownerUserID: userID)

        try destinationContext.save()
    }

    /// Fetches every existing row of `T` already in `context`, keyed by `id` — used both to know
    /// which legacy rows are already migrated (skip) and, for relationship-bearing types, as the
    /// rewiring target for later passes (covers both previously-migrated and newly-copied rows).
    private static func existingMap<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext,
        id: (T) -> UUID
    ) throws -> [UUID: T] {
        let rows = try context.fetch(FetchDescriptor<T>())
        var map: [UUID: T] = [:]
        for row in rows { map[id(row)] = row }
        return map
    }

    private static func copyCategories(
        from legacyContext: ModelContext,
        into destinationContext: ModelContext
    ) throws -> [UUID: Category] {
        var map = try existingMap(Category.self, in: destinationContext, id: \.id)
        let legacyRows = try legacyContext.fetch(FetchDescriptor<Category>())
        for legacy in legacyRows where map[legacy.id] == nil {
            let copy = Category(
                id: legacy.id,
                name: legacy.name,
                iconName: legacy.iconName,
                colorName: legacy.colorName,
                isDefault: legacy.isDefault,
                isArchived: legacy.isArchived,
                createdAt: legacy.createdAt
            )
            destinationContext.insert(copy)
            map[legacy.id] = copy
        }
        return map
    }

    private static func copyAccounts(
        from legacyContext: ModelContext,
        into destinationContext: ModelContext,
        ownerUserID userID: UUID
    ) throws -> [UUID: Account] {
        var map = try existingMap(Account.self, in: destinationContext, id: \.id)
        let legacyRows = try legacyContext.fetch(FetchDescriptor<Account>())
        for legacy in legacyRows where map[legacy.id] == nil {
            let copy = Account(
                id: legacy.id,
                name: legacy.name,
                type: legacy.type,
                currentBalance: legacy.currentBalance,
                institutionName: legacy.institutionName,
                lastFourDigits: legacy.lastFourDigits,
                creditLimit: legacy.creditLimit,
                availableCredit: legacy.availableCredit,
                paymentDueDate: legacy.paymentDueDate,
                minimumPayment: legacy.minimumPayment,
                colorHex: legacy.colorHex,
                isArchived: legacy.isArchived,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                connectionType: legacy.connectionType,
                externalIdentifier: legacy.externalIdentifier,
                defaultCountsTowardMonthlySpending: legacy.defaultCountsTowardMonthlySpending,
                showsInRecentActivity: legacy.showsInRecentActivity
            )
            copy.ownerUserID = userID
            destinationContext.insert(copy)
            map[legacy.id] = copy
        }
        return map
    }

    private static func copyFinanceTransactions(
        from legacyContext: ModelContext,
        into destinationContext: ModelContext,
        ownerUserID userID: UUID,
        accountMap: [UUID: Account],
        categoryMap: [UUID: Category]
    ) throws {
        var map = try existingMap(FinanceTransaction.self, in: destinationContext, id: \.id)
        let legacyRows = try legacyContext.fetch(FetchDescriptor<FinanceTransaction>())
        for legacy in legacyRows where map[legacy.id] == nil {
            let copy = FinanceTransaction(
                id: legacy.id,
                amount: legacy.amount,
                date: legacy.date,
                type: legacy.type,
                source: legacy.source,
                note: legacy.note,
                countsTowardWeeklyBudget: legacy.countsTowardWeeklyBudget,
                countsTowardMonthlySpending: legacy.countsTowardMonthlySpending,
                isExcludedFromReports: legacy.isExcludedFromReports,
                isPending: legacy.isPending,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                externalTransactionId: legacy.externalTransactionId,
                pendingTransactionId: legacy.pendingTransactionId,
                merchantName: legacy.merchantName,
                originalDescription: legacy.originalDescription,
                plaidAccountId: legacy.plaidAccountId,
                authorizedDate: legacy.authorizedDate,
                postedDate: legacy.postedDate,
                isMatchedToManualExpense: legacy.isMatchedToManualExpense,
                matchedTransactionId: legacy.matchedTransactionId,
                account: legacy.account.flatMap { accountMap[$0.id] },
                category: legacy.category.flatMap { categoryMap[$0.id] },
                transferDestinationAccount: legacy.transferDestinationAccount.flatMap { accountMap[$0.id] },
                ownerUserID: userID
            )
            destinationContext.insert(copy)
            map[legacy.id] = copy
        }
    }

    private static func copyRecurringExpenses(
        from legacyContext: ModelContext,
        into destinationContext: ModelContext,
        ownerUserID userID: UUID,
        accountMap: [UUID: Account],
        categoryMap: [UUID: Category]
    ) throws {
        var map = try existingMap(RecurringExpense.self, in: destinationContext, id: \.id)
        let legacyRows = try legacyContext.fetch(FetchDescriptor<RecurringExpense>())
        for legacy in legacyRows where map[legacy.id] == nil {
            let copy = RecurringExpense(
                id: legacy.id,
                name: legacy.name,
                amount: legacy.amount,
                category: legacy.category.flatMap { categoryMap[$0.id] },
                frequency: legacy.frequency,
                timing: legacy.timing,
                dayOfMonth: legacy.dayOfMonth,
                dueDate: legacy.dueDate,
                paymentAccount: legacy.paymentAccount.flatMap { accountMap[$0.id] },
                isEssential: legacy.isEssential,
                isActive: legacy.isActive,
                note: legacy.note,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                ownerUserID: userID
            )
            destinationContext.insert(copy)
            map[legacy.id] = copy
        }
    }

    private static func copyIncomeSources(
        from legacyContext: ModelContext,
        into destinationContext: ModelContext,
        ownerUserID userID: UUID
    ) throws {
        var map = try existingMap(IncomeSource.self, in: destinationContext, id: \.id)
        let legacyRows = try legacyContext.fetch(FetchDescriptor<IncomeSource>())
        for legacy in legacyRows where map[legacy.id] == nil {
            let copy = IncomeSource(
                id: legacy.id,
                name: legacy.name,
                amount: legacy.amount,
                frequency: legacy.frequency,
                timing: legacy.timing,
                dayOfMonth: legacy.dayOfMonth,
                nextPayDate: legacy.nextPayDate,
                isActive: legacy.isActive,
                note: legacy.note,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                ownerUserID: userID
            )
            destinationContext.insert(copy)
            map[legacy.id] = copy
        }
    }

    private static func copyBudgetSettings(
        from legacyContext: ModelContext,
        into destinationContext: ModelContext
    ) throws {
        var map = try existingMap(BudgetSettings.self, in: destinationContext, id: \.id)
        let legacyRows = try legacyContext.fetch(FetchDescriptor<BudgetSettings>())
        for legacy in legacyRows where map[legacy.id] == nil {
            let copy = BudgetSettings(
                id: legacy.id,
                weeklySpendingLimit: legacy.weeklySpendingLimit,
                weekStartsOnSunday: legacy.weekStartsOnSunday,
                includePendingTransactions: legacy.includePendingTransactions,
                hideBalancesByDefault: legacy.hideBalancesByDefault,
                requireFaceID: legacy.requireFaceID,
                monthlyGoal: legacy.monthlyGoal,
                warningThreshold: legacy.warningThreshold,
                autoBackupEnabled: legacy.autoBackupEnabled ?? true,
                spendSenseEnabled: legacy.spendSenseEnabled ?? true,
                updatedAt: legacy.updatedAt
            )
            destinationContext.insert(copy)
            map[legacy.id] = copy
        }
    }

    private static func copyMonthlyPlanSettings(
        from legacyContext: ModelContext,
        into destinationContext: ModelContext,
        ownerUserID userID: UUID
    ) throws {
        var map = try existingMap(MonthlyPlanSettings.self, in: destinationContext, id: \.id)
        let legacyRows = try legacyContext.fetch(FetchDescriptor<MonthlyPlanSettings>())
        for legacy in legacyRows where map[legacy.id] == nil {
            let copy = MonthlyPlanSettings(
                id: legacy.id,
                monthlySavingsGoal: legacy.monthlySavingsGoal,
                bufferAmount: legacy.bufferAmount,
                useRecommendedWeeklyBudget: legacy.useRecommendedWeeklyBudget,
                autoUpdateWeeklyBudgetFromPlan: legacy.autoUpdateWeeklyBudgetFromPlan,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                ownerUserID: userID
            )
            destinationContext.insert(copy)
            map[legacy.id] = copy
        }
    }
}

/// Backfills `ownerUserID` on any of the 5 owner-eligible rows already sitting in a per-user
/// context with a `nil` owner — covers rows `LegacyDataMigrator` just copied (which already set
/// it directly, so this is a no-op for them) and, defensively, any other nil-owner row from any
/// other source. Idempotent: only rows with `ownerUserID == nil` are touched or saved; a row that
/// already carries an owner (including a *different* owner, left alone rather than reassigned) is
/// never rewritten. Safe to call on every app launch/user-resolution.
enum OwnerUserIDBackfill {
    static func run(in context: ModelContext, ownerUserID userID: UUID) throws {
        var didChange = false

        let accounts = try context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.ownerUserID == nil }))
        for row in accounts { row.ownerUserID = userID; didChange = true }

        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>(predicate: #Predicate { $0.ownerUserID == nil }))
        for row in transactions { row.ownerUserID = userID; didChange = true }

        let incomeSources = try context.fetch(FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.ownerUserID == nil }))
        for row in incomeSources { row.ownerUserID = userID; didChange = true }

        let recurringExpenses = try context.fetch(FetchDescriptor<RecurringExpense>(predicate: #Predicate { $0.ownerUserID == nil }))
        for row in recurringExpenses { row.ownerUserID = userID; didChange = true }

        let monthlyPlanSettings = try context.fetch(FetchDescriptor<MonthlyPlanSettings>(predicate: #Predicate { $0.ownerUserID == nil }))
        for row in monthlyPlanSettings { row.ownerUserID = userID; didChange = true }

        if didChange {
            try context.save()
        }
    }
}
