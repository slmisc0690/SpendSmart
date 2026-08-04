import Foundation
import SwiftData

/// LOCAL DATA RESTORE — recovers this device's own Monthly Plan (settings/income sources/
/// recurring expenses) and Manual Accounts (+ transactions) from Supabase after a local wipe
/// (fresh install, new device). Real-world trigger: a fresh reinstall clears the on-device
/// SwiftData store, but anything already synced to the cloud by `MonthlyPlanCloudSyncManager`/
/// `ManualDataCloudSyncManager` is still there — this is the missing "pull it back down" half of
/// that existing push-only sync, mirroring how `ConnectedAccountsView.refreshConnectionStatusFromServer`
/// already recovers Connected Accounts the same way.
///
/// UPSERT-BY-ID, NEVER OVERWRITE: every row this writes is checked against the current local store
/// by `id` first — if a local row with that id already exists, it is left completely untouched
/// (never re-written, never merged). This makes the action safe to run repeatedly (e.g. tapping
/// "Restore from Cloud" a second time is a no-op for anything already restored) and guarantees it
/// can never clobber a local edit made after a partial restore. `MonthlyPlanSettings` is the one
/// singleton exception: if ANY local settings row already exists for this user, it is left alone
/// entirely (never merged field-by-field) rather than risk silently overwriting a real, intentional
/// local change with a possibly-stale cloud snapshot.
///
/// KNOWN GAPS (the cloud schema never captured these fields, so they cannot be restored — the user
/// must re-enter them manually if they were previously set):
/// - `MonthlyPlanSettings.plannedWeeklySpendingOverride` (Custom weekly override) — not a column in
///   `monthly_plan_settings`.
/// - `IncomeSource`'s INCOME SCHEDULING PHASE fields (`dayOfMonth`, `monthlyDepositDayIsLastDay`,
///   `twiceMonthlyFirstDay*`/`twiceMonthlySecondDay*`) — not columns in
///   `monthly_plan_income_sources`; that table predates those fields.
/// - `RecurringExpense.dayOfMonth`/`.timing`/`.paymentAccount` — not carried by
///   `SharedRecurringExpenseDTO` (only `category` survives, matched by name).
enum LocalDataRestoreService {
    struct Summary: Equatable {
        var monthlyPlanRestored = false
        var incomeSourcesRestored = 0
        var recurringExpensesRestored = 0
        var manualAccountsRestored = 0
        var manualTransactionsRestored = 0
    }

    @MainActor
    static func restore(
        context: ModelContext,
        userId: UUID,
        backend: HouseholdSharingService = SupabaseHouseholdSharingService()
    ) async throws -> Summary {
        var summary = Summary()

        let planResponse = try await backend.getSharedMonthlyPlan(ownerUserId: userId)
        if let plan = planResponse.plan {
            summary.monthlyPlanRestored = try restoreMonthlyPlan(plan, context: context, userId: userId)
            summary.incomeSourcesRestored = try restoreIncomeSources(plan.incomeSources, context: context, userId: userId)
            summary.recurringExpensesRestored = try restoreRecurringExpenses(plan.recurringExpenses, context: context, userId: userId)
        }

        let manualAccountsResponse = try await backend.getMyManualAccounts()
        let (accountsRestored, transactionsRestored) = try restoreManualAccounts(manualAccountsResponse.accounts, context: context, userId: userId)
        summary.manualAccountsRestored = accountsRestored
        summary.manualTransactionsRestored = transactionsRestored

        if summary.monthlyPlanRestored || summary.incomeSourcesRestored > 0 || summary.recurringExpensesRestored > 0
            || summary.manualAccountsRestored > 0 || summary.manualTransactionsRestored > 0 {
            try context.save()
        }

        return summary
    }

    private static func restoreMonthlyPlan(_ plan: SharedMonthlyPlanDTO, context: ModelContext, userId: UUID) throws -> Bool {
        let existing = try context.fetch(FetchDescriptor<MonthlyPlanSettings>())
        guard !existing.contains(where: { $0.ownerUserID == userId }) else { return false }

        let settings = MonthlyPlanSettings(
            monthlySavingsGoal: plan.monthlySavingsGoal,
            bufferAmount: plan.bufferAmount,
            autoUpdateWeeklyBudgetFromPlan: plan.autoUpdateWeeklyBudgetFromPlan,
            updatedAt: plan.updatedAt,
            ownerUserID: userId
        )
        context.insert(settings)
        return true
    }

    private static func restoreIncomeSources(_ sources: [SharedIncomeSourceDTO], context: ModelContext, userId: UUID) throws -> Int {
        let existingIds = Set(try context.fetch(FetchDescriptor<IncomeSource>()).map(\.id))
        var restoredCount = 0
        for source in sources where !existingIds.contains(source.id) {
            let restored = IncomeSource(
                id: source.id,
                name: source.name,
                amount: source.amount,
                frequency: PlanFrequency(rawValue: source.frequency) ?? .monthly,
                nextPayDate: source.nextPayDate,
                isActive: source.isActive,
                note: source.note ?? "",
                ownerUserID: userId
            )
            context.insert(restored)
            restoredCount += 1
        }
        return restoredCount
    }

    private static func restoreRecurringExpenses(_ expenses: [SharedRecurringExpenseDTO], context: ModelContext, userId: UUID) throws -> Int {
        let existingIds = Set(try context.fetch(FetchDescriptor<RecurringExpense>()).map(\.id))
        let existingCategories = try context.fetch(FetchDescriptor<Category>())
        var restoredCount = 0
        for expense in expenses where !existingIds.contains(expense.id) {
            let matchedCategory = expense.categoryName.flatMap { name in
                existingCategories.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            }
            let restored = RecurringExpense(
                id: expense.id,
                name: expense.name,
                amount: expense.amount,
                category: matchedCategory,
                frequency: PlanFrequency(rawValue: expense.frequency) ?? .monthly,
                dueDate: expense.dueDate,
                isEssential: expense.isEssential,
                isActive: expense.isActive,
                note: expense.note ?? "",
                ownerUserID: userId
            )
            context.insert(restored)
            restoredCount += 1
        }
        return restoredCount
    }

    private static func restoreManualAccounts(
        _ accounts: [SharedManualAccountDetailDTO],
        context: ModelContext,
        userId: UUID
    ) throws -> (accounts: Int, transactions: Int) {
        // Fetch-then-filter in plain Swift, not #Predicate — matching this codebase's own
        // established convention (see ManualDataCloudSyncManager.performSync's identical note).
        let existingAccountsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Account>()).map { ($0.id, $0) })
        let existingTransactionIds = Set(try context.fetch(FetchDescriptor<FinanceTransaction>()).map(\.id))
        var restoredAccounts = 0
        var restoredTransactions = 0

        for accountDTO in accounts {
            let localAccount: Account
            if let match = existingAccountsByID[accountDTO.id] {
                // Already present locally — never overwritten, but still needed below so this
                // account's own restored transactions can attach to the correct local Account.
                localAccount = match
            } else {
                let restored = Account(
                    id: accountDTO.id,
                    name: accountDTO.name,
                    type: AccountType(rawValue: accountDTO.accountType) ?? .other,
                    currentBalance: accountDTO.currentBalance ?? 0,
                    institutionName: accountDTO.institutionName,
                    lastFourDigits: accountDTO.lastFourDigits,
                    updatedAt: accountDTO.updatedAt,
                    connectionType: .manual,
                    showsInRecentActivity: accountDTO.showsInRecentActivity
                )
                restored.ownerUserID = userId
                context.insert(restored)
                localAccount = restored
                restoredAccounts += 1
            }

            for transactionDTO in accountDTO.transactions where !existingTransactionIds.contains(transactionDTO.id) {
                let restoredTransaction = FinanceTransaction(
                    id: transactionDTO.id,
                    amount: transactionDTO.amount,
                    date: transactionDTO.transactionDate ?? transactionDTO.updatedAt,
                    type: TransactionType(rawValue: transactionDTO.transactionType) ?? .expense,
                    source: .manual,
                    note: transactionDTO.note,
                    isPending: transactionDTO.isPending,
                    updatedAt: transactionDTO.updatedAt,
                    account: localAccount,
                    ownerUserID: userId
                )
                context.insert(restoredTransaction)
                restoredTransactions += 1
            }
        }

        return (restoredAccounts, restoredTransactions)
    }
}
