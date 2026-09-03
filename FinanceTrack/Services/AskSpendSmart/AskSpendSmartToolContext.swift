import Foundation

/// Formats a `Decimal` money value the same plain, locale-independent way
/// `TransactionCSVExportService.amountFormatter` already does — no currency symbol, no grouping
/// separator, always exactly 2 fraction digits — so every Ask SpendSmart tool result reaches the
/// model as an unambiguous decimal string rather than a `Decimal` (FoundationModels' `@Generable`
/// guided generation does not directly support `Decimal`) or a locale-dependent formatted string.
enum AskSpendSmartMoneyFormat {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.negativePrefix = "-"
        return formatter
    }()

    static func string(_ amount: Decimal) -> String {
        formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}

/// TRANSACTION SEARCH RELIABILITY FIX — safe amount comparison for `searchTransactions`. The user
/// always thinks and speaks in positive magnitudes ("$34.75"), and `FinanceTransaction.amount` is
/// ALSO always stored as a positive magnitude — direction comes from `TransactionType`, never the
/// sign of `amount` itself (see `TransactionType.countsAsSpending` and
/// `AskSpendSmartToolContext.merchantSpending`'s own delta computation, which derives sign from
/// `type`, not `amount`) — but this normalizes via `abs` on both sides regardless, so a caller that
/// still passes a negative number (e.g. a literal "-$34.75") matches correctly too. Compares at
/// 2-decimal-place (whole-cent) `Decimal` precision, never binary floating-point equality — a
/// `Double` literal like `34.75` is not exactly representable in binary floating point, so a naive
/// `==` after converting through `Double` would be fragile.
enum AskSpendSmartAmountMatch {
    static func matches(_ transactionAmount: Decimal, _ queryAmount: Decimal) -> Bool {
        roundedToCents(abs(transactionAmount)) == roundedToCents(abs(queryAmount))
    }

    private static func roundedToCents(_ amount: Decimal) -> Decimal {
        var rounded = Decimal()
        var mutableAmount = amount
        NSDecimalRound(&rounded, &mutableAmount, 2, .plain)
        return rounded
    }
}

/// THE DETERMINISTIC DATA/CALCULATION LAYER FOR ASK SPENDSMART — deliberately has no dependency on
/// FoundationModels, `Tool`, or `@Generable` at all, so it compiles and is directly unit-testable on
/// every deployment target this app supports (iOS 17+), independent of whether the on-device model
/// itself is available on a given test/build machine. `AskSpendSmartToolProvider.swift` (iOS 26+
/// only) wraps every method here in a thin `Tool` conformer — this is where the actual math lives.
///
/// EVERY calculation below calls straight into the app's existing, already-tested authoritative
/// calculators (`BudgetCalculator`/`MonthlyPlanCalculator`/`MonthlyPlanScenarioViewModel`) or reads
/// already-cached balances — nothing here re-derives a formula those calculators already own. This
/// is the one and only place Ask SpendSmart's tool layer is allowed to compute anything.
///
/// CONCURRENCY — `Tool.call(arguments:)` is `@concurrent` (FoundationModels may invoke it off the
/// main actor). Every stored property here is captured once, up front, from already-fetched
/// SwiftData arrays and already-cached Plaid balances (the same "fetch via `@Query`, then filter in
/// plain Swift" convention this project already uses everywhere else — see
/// `PlaidLocalDataCleanupService`'s own header). All computation below is pure, synchronous, and
/// touches no live `ModelContext` — so this type is safe to mark `@unchecked Sendable`: every method
/// only ever reads its own captured, immutable value-type arrays, never a shared mutable resource a
/// concurrent caller could race on.
final class AskSpendSmartToolContext: @unchecked Sendable {
    private let transactions: [FinanceTransaction]
    private let accounts: [Account]
    private let plaidConnections: [PlaidConnection]
    private let incomeSources: [IncomeSource]
    private let recurringExpenses: [RecurringExpense]
    private let budgetSettings: BudgetSettings?
    private let monthlyPlanSettings: MonthlyPlanSettings?
    /// FULL VISIBILITY PHASE — needed for `savingsStatus()`'s `SavingsCalculator.savedThisMonth`
    /// call; every other new tool reuses inputs already loaded above.
    private let savingsEntries: [SavingsEntry]
    private let now: Date

    init(
        transactions: [FinanceTransaction],
        accounts: [Account],
        plaidConnections: [PlaidConnection],
        incomeSources: [IncomeSource],
        recurringExpenses: [RecurringExpense],
        budgetSettings: BudgetSettings?,
        monthlyPlanSettings: MonthlyPlanSettings?,
        savingsEntries: [SavingsEntry] = [],
        now: Date = .now
    ) {
        self.transactions = transactions
        self.accounts = accounts
        self.plaidConnections = plaidConnections
        self.incomeSources = incomeSources
        self.recurringExpenses = recurringExpenses
        self.budgetSettings = budgetSettings
        self.monthlyPlanSettings = monthlyPlanSettings
        self.savingsEntries = savingsEntries
        self.now = now
    }

    /// TRANSACTION SEARCH RELIABILITY FIX — exposed so `SystemAskSpendSmartService` can ground its
    /// on-device model's instructions with "today's date," letting the model reliably resolve
    /// relative date phrases ("yesterday", "this week", "last month") into explicit `YYYY-MM-DD`
    /// tool arguments itself. The deterministic layer still performs every actual date-boundary
    /// filter (see `searchTransactions`) — this only tells the model what "today" means when IT
    /// constructs those arguments; it is never itself a filtering input.
    var currentDateForModelGrounding: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: now)
    }

    // MARK: - Shared derived inputs (never re-read from SwiftData — see this type's own header)

    private var weekStartsOnSunday: Bool { budgetSettings?.weekStartsOnSunday ?? true }
    private var includePending: Bool { budgetSettings?.includePendingTransactions ?? true }
    private var warningThreshold: Double { budgetSettings?.warningThreshold ?? 0.70 }
    private var autoTrackedAccountIds: Set<String> { Set(budgetSettings?.autoCalculateConnectedAccountIds ?? []) }
    private var excludedTransactionIDs: Set<UUID> {
        guard budgetSettings?.excludeTransactionsEnabled == true else { return [] }
        return Set(budgetSettings?.excludedTransactionIDs ?? [])
    }
    private var currentMonth: DateInterval { DateRangeHelper.monthRangeContaining(now) }
    private var currentWeek: DateInterval { DateRangeHelper.weekRangeContaining(now, weekStartsOnSunday: weekStartsOnSunday) }

    // MARK: - 1. Financial summary (income, fixed bills, savings goal, flexible/planned/actual/remaining)

    struct FinancialSummaryResult: Sendable, Equatable {
        let monthlyIncome: String
        let fixedBillsTotal: String
        let monthlySavingsGoal: String
        let flexibleSpendingAvailable: String
        let plannedWeeklySpending: String
        let plannedMonthlySpending: String
        let weeklyActualSpending: String
        let weeklyRemaining: String
        let monthlyActualSpending: String
        let monthlyRemaining: String
        let weeklySpendingLimit: String
    }

    func financialSummary() -> FinancialSummaryResult {
        let summary = MonthlyPlanCalculator.summary(
            month: currentMonth,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: monthlyPlanSettings,
            weeklyBudgetLimit: budgetSettings?.weeklySpendingLimit ?? 0,
            transactions: transactions,
            weekInterval: currentWeek,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold,
            autoTrackedAccountIds: autoTrackedAccountIds,
            excludedTransactionIDs: excludedTransactionIDs
        )
        let plannedWeekly = MonthlyPlanCalculator.effectivePlannedWeeklySpending(
            override: monthlyPlanSettings?.plannedWeeklySpendingOverride,
            flexibleSpendingAvailable: summary.flexibleSpendingAvailable
        )
        let weeklyRemaining = BudgetCalculator.remaining(limit: summary.currentManualWeeklyBudget, spent: summary.actualSpentThisWeek)
        let monthlyRemaining = MonthlyPlanCalculator.monthlySpendRemaining(
            monthlySpendingBudget: MonthlyPlanCalculator.monthlySpendingBudget(
                moneyAfterBills: MonthlyPlanCalculator.moneyAfterBills(income: summary.estimatedMonthlyIncome, fixedExpenses: summary.estimatedMonthlyFixedExpenses),
                savingsGoal: summary.monthlySavingsGoal,
                bufferAmount: summary.bufferAmount
            ),
            actualMonthlySpending: summary.actualSpentThisMonth
        )
        return FinancialSummaryResult(
            monthlyIncome: AskSpendSmartMoneyFormat.string(summary.estimatedMonthlyIncome),
            fixedBillsTotal: AskSpendSmartMoneyFormat.string(summary.estimatedMonthlyFixedExpenses),
            monthlySavingsGoal: AskSpendSmartMoneyFormat.string(summary.monthlySavingsGoal),
            flexibleSpendingAvailable: AskSpendSmartMoneyFormat.string(summary.flexibleSpendingAvailable),
            plannedWeeklySpending: AskSpendSmartMoneyFormat.string(plannedWeekly),
            plannedMonthlySpending: AskSpendSmartMoneyFormat.string(MonthlyPlanCalculator.plannedMonthlySpending(plannedWeeklySpending: plannedWeekly)),
            weeklyActualSpending: AskSpendSmartMoneyFormat.string(summary.actualSpentThisWeek),
            weeklyRemaining: AskSpendSmartMoneyFormat.string(weeklyRemaining),
            monthlyActualSpending: AskSpendSmartMoneyFormat.string(summary.actualSpentThisMonth),
            monthlyRemaining: AskSpendSmartMoneyFormat.string(monthlyRemaining),
            weeklySpendingLimit: AskSpendSmartMoneyFormat.string(summary.currentManualWeeklyBudget)
        )
    }

    // MARK: - 2. Account balances (manual + connected)

    struct AccountBalanceResult: Sendable, Equatable {
        let name: String
        let accountType: String
        let isManual: Bool
        let institutionName: String?
        let currentBalance: String
        let availableBalance: String?
        let creditLimit: String?
    }

    func accountBalances() -> [AccountBalanceResult] {
        var results = accounts
            .filter { !$0.isArchived }
            .map { account in
                AccountBalanceResult(
                    name: account.name,
                    accountType: account.type.label,
                    isManual: true,
                    institutionName: account.institutionName,
                    currentBalance: AskSpendSmartMoneyFormat.string(account.currentBalance),
                    availableBalance: account.availableCredit.map(AskSpendSmartMoneyFormat.string),
                    creditLimit: account.creditLimit.map(AskSpendSmartMoneyFormat.string)
                )
            }
        for connection in plaidConnections {
            guard let cached = connection.cachedBalances else { continue }
            for balance in cached.values.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
                results.append(
                    AccountBalanceResult(
                        name: balance.name ?? connection.institutionName,
                        accountType: balance.subtype ?? balance.type ?? "connected",
                        isManual: false,
                        institutionName: connection.institutionName,
                        currentBalance: AskSpendSmartMoneyFormat.string(balance.currentBalance ?? 0),
                        availableBalance: balance.availableBalance.map(AskSpendSmartMoneyFormat.string),
                        creditLimit: balance.creditLimit.map(AskSpendSmartMoneyFormat.string)
                    )
                )
            }
        }
        return results
    }

    // MARK: - 3. Transaction search (date range / exact amount / account / merchant / category / pending)

    struct TransactionResult: Sendable, Equatable {
        let date: String
        let amount: String
        let type: String
        let description: String
        let category: String?
        let accountName: String?
        let isPending: Bool
    }

    /// Wraps the matched transactions together with match-count metadata, so the assistant can
    /// accurately tell the user when there were more matches than were returned — never silently
    /// truncating without saying so.
    struct TransactionSearchResult: Sendable, Equatable {
        let transactions: [TransactionResult]
        /// The number of transactions that matched EVERY filter, before any result-count cap was
        /// applied — always computed against the full local transaction set, never a pre-capped
        /// slice (see this method's own header for the exact prior bug this replaces).
        let totalMatchCount: Int
        let resultsReturned: Int
        let truncated: Bool
    }

    enum PendingFilter: Sendable, Equatable {
        case all
        case pendingOnly
        case postedOnly
    }

    /// TRANSACTION SEARCH RELIABILITY FIX — a deterministic, structured lookup the on-device model
    /// can narrow with real criteria, replacing an architecture that silently failed on Scott's own
    /// real "known transaction not found" report. ROOT CAUSES this fixes (traced in the prior
    /// implementation, not guessed):
    ///
    /// 1. **Date-boundary bug**: the prior filter compared `transaction.date > endDate` against a
    ///    bare parsed `Date` sitting at literal midnight — so for a single-day query (`startDate ==
    ///    endDate`, the natural way to ask "on August 23"), ANY transaction later than midnight on
    ///    that day (i.e., nearly every real transaction) was incorrectly excluded. Fixed by
    ///    normalizing both boundaries through `DateRangeHelper.dayRangeContaining`, so `endDate` is
    ///    always treated as an EXCLUSIVE start-of-the-NEXT-day boundary, never a literal midnight
    ///    upper bound.
    /// 2. **No amount filter existed at all** — the model had no way to narrow "$34.75" at the
    ///    deterministic layer and had to (unreliably) eyeball a list of same-day transactions
    ///    itself. Fixed by adding `exactAmount`, matched via `AskSpendSmartAmountMatch` (sign- and
    ///    decimal-precision-safe, never fragile floating-point equality).
    /// 3. **`isExcludedFromReports` transactions were unconditionally dropped** — breaking parity
    ///    with the Activity screen, which deliberately still shows them (see `ExpenseListView`'s own
    ///    header: "it shows everything that happened, whether or not it counts toward Weekly or
    ///    Monthly spending"). A factual ledger lookup must not hide a real transaction merely
    ///    because it's excluded from budget math — that exclusion is now removed entirely.
    /// 4. **Account filtering only ever checked a Manual `Account.name`** — a connected/Plaid
    ///    transaction (identified by `plaidAccountId`, not the `account` relationship — see
    ///    `Account`'s own header: manual accounts only) could never match an account-name filter at
    ///    all, e.g. "Show me my Chase transactions." Fixed by also resolving through the SAME
    ///    canonical `ConnectedAccountOptionPresenter.label(forAccountId:in:)` the rest of the app
    ///    already uses for this exact lookup, and by also checking `Account.institutionName` for
    ///    manual accounts that have one.
    ///
    /// Filtering ALWAYS happens over the FULL local transaction set first; only the matched subset
    /// is ever capped by `resultLimit` — never a "most recent N, then filter" shortcut (which is
    /// exactly what made an older-than-the-most-recent-50 transaction unfindable before). Every
    /// filter is optional/independently combinable; passing none returns everything (still capped).
    func searchTransactions(
        startDate: Date?,
        endDate: Date?,
        exactAmount: Decimal?,
        accountName: String?,
        merchant: String?,
        category: String?,
        pendingFilter: PendingFilter,
        resultLimit: Int = 50
    ) -> TransactionSearchResult {
        let normalizedStart = startDate.map { DateRangeHelper.dayRangeContaining($0).start }
        let normalizedEnd = endDate.map { DateRangeHelper.dayRangeContaining($0).end }

        let matches = transactions.filter { transaction in
            if let normalizedStart, transaction.date < normalizedStart { return false }
            if let normalizedEnd, transaction.date >= normalizedEnd { return false }
            if let exactAmount, !AskSpendSmartAmountMatch.matches(transaction.amount, exactAmount) { return false }
            if let accountName, !accountName.isEmpty, !matchesAccountFilter(transaction, filter: accountName) { return false }
            if let merchant, !merchant.isEmpty,
               !transaction.displayName.localizedCaseInsensitiveContains(merchant) { return false }
            if let category, !category.isEmpty,
               !(transaction.category?.name.localizedCaseInsensitiveContains(category) ?? false) { return false }
            switch pendingFilter {
            case .all: break
            case .pendingOnly: if !transaction.isPending { return false }
            case .postedOnly: if transaction.isPending { return false }
            }
            return true
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let sorted = matches.sorted { $0.date > $1.date }
        let limited = Array(sorted.prefix(resultLimit))
        let results = limited.map { transaction in
            TransactionResult(
                date: dateFormatter.string(from: transaction.date),
                amount: AskSpendSmartMoneyFormat.string(transaction.amount),
                type: transaction.type.rawValue,
                description: transaction.displayName,
                category: transaction.category?.name,
                accountName: resolvedAccountName(for: transaction),
                isPending: transaction.isPending
            )
        }
        return TransactionSearchResult(
            transactions: results,
            totalMatchCount: matches.count,
            resultsReturned: results.count,
            truncated: matches.count > results.count
        )
    }

    /// TRANSACTION SEARCH RELIABILITY FIX — the DISPLAYED account name for a connected/Plaid
    /// transaction must be its own specific Plaid-reported name (e.g. "Chase Checking"), matching
    /// the same `balance.name ?? connection.institutionName` precedent `getAccountBalances` already
    /// uses above — never `ConnectedAccountOptionPresenter.label`, which is institution-only by
    /// design (built for "Paid With" attribution, where disambiguating between same-institution
    /// accounts by mask matters more than showing each one's own specific name) and would otherwise
    /// under-specify which of a user's several Chase accounts a result actually came from. Manual
    /// accounts resolve directly via their relationship, as before. Matching (`matchesAccountFilter`
    /// below) is unaffected — a search for "Chase" must still match every Chase account regardless
    /// of this display-name fix.
    private func resolvedAccountName(for transaction: FinanceTransaction) -> String? {
        if let name = transaction.account?.name { return name }
        guard let plaidAccountId = transaction.plaidAccountId else { return nil }
        for connection in plaidConnections {
            if let balance = connection.cachedBalances?[plaidAccountId] {
                return balance.name ?? connection.institutionName
            }
        }
        return ConnectedAccountOptionPresenter.label(forAccountId: plaidAccountId, in: plaidConnections)
    }

    /// Matches `filter` against every name a user might plausibly type for this transaction's
    /// account: a Manual Account's own name, its institution name if it has one, or a connected/
    /// Plaid account's resolved institution label (e.g. "Chase", "American Express").
    private func matchesAccountFilter(_ transaction: FinanceTransaction, filter: String) -> Bool {
        if let manualName = transaction.account?.name, manualName.localizedCaseInsensitiveContains(filter) { return true }
        if let institutionName = transaction.account?.institutionName, institutionName.localizedCaseInsensitiveContains(filter) { return true }
        if let connectedLabel = ConnectedAccountOptionPresenter.label(forAccountId: transaction.plaidAccountId, in: plaidConnections),
           connectedLabel.localizedCaseInsensitiveContains(filter) { return true }
        return false
    }

    // MARK: - 4. Spending totals by category

    struct CategoryTotalResult: Sendable, Equatable {
        let categoryName: String
        let total: String
    }

    func categorySpending(startDate: Date, endDate: Date) -> [CategoryTotalResult] {
        let interval = DateInterval(start: startDate, end: max(startDate, endDate))
        return BudgetCalculator.categoryTotals(transactions, in: interval, includePending: includePending, context: .monthly)
            .map { CategoryTotalResult(categoryName: $0.category?.name ?? "Uncategorized", total: AskSpendSmartMoneyFormat.string($0.total)) }
    }

    // MARK: - 5. Spending totals by merchant

    struct MerchantTotalResult: Sendable, Equatable {
        let merchant: String
        let total: String
        let transactionCount: Int
    }

    func merchantSpending(startDate: Date, endDate: Date, merchantFilter: String?) -> [MerchantTotalResult] {
        let interval = DateInterval(start: startDate, end: max(startDate, endDate))
        var totals: [String: (Decimal, Int)] = [:]
        for transaction in transactions {
            guard interval.contains(transaction.date), !transaction.isExcludedFromReports else { continue }
            guard transaction.type == .expense || transaction.type == .refund else { continue }
            let name = transaction.displayName
            if let merchantFilter, !merchantFilter.isEmpty, !name.localizedCaseInsensitiveContains(merchantFilter) { continue }
            let delta = transaction.type == .expense ? transaction.amount : -transaction.amount
            let existing = totals[name] ?? (0, 0)
            totals[name] = (existing.0 + delta, existing.1 + 1)
        }
        return totals
            .map { MerchantTotalResult(merchant: $0.key, total: AskSpendSmartMoneyFormat.string($0.value.0), transactionCount: $0.value.1) }
            .sorted { ($0.total as NSString).doubleValue > ($1.total as NSString).doubleValue }
    }

    // MARK: - 6. Spending comparison between two periods

    struct PeriodComparisonResult: Sendable, Equatable {
        let periodASpent: String
        let periodBSpent: String
        let difference: String
        let categoryChanges: [CategoryChangeResult]
    }

    struct CategoryChangeResult: Sendable, Equatable {
        let categoryName: String
        let periodAAmount: String
        let periodBAmount: String
        let change: String
    }

    func comparePeriods(periodAStart: Date, periodAEnd: Date, periodBStart: Date, periodBEnd: Date) -> PeriodComparisonResult {
        let periodA = DateInterval(start: periodAStart, end: max(periodAStart, periodAEnd))
        let periodB = DateInterval(start: periodBStart, end: max(periodBStart, periodBEnd))
        let spentA = BudgetCalculator.monthlySpent(transactions, in: periodA, includePending: includePending)
        let spentB = BudgetCalculator.monthlySpent(transactions, in: periodB, includePending: includePending)

        var byCategory: [String: (Decimal, Decimal)] = [:]
        for total in BudgetCalculator.categoryTotals(transactions, in: periodA, includePending: includePending, context: .monthly) {
            byCategory[total.category?.name ?? "Uncategorized", default: (0, 0)].0 = total.total
        }
        for total in BudgetCalculator.categoryTotals(transactions, in: periodB, includePending: includePending, context: .monthly) {
            byCategory[total.category?.name ?? "Uncategorized", default: (0, 0)].1 = total.total
        }
        let changes = byCategory
            .map { name, amounts in
                CategoryChangeResult(
                    categoryName: name,
                    periodAAmount: AskSpendSmartMoneyFormat.string(amounts.0),
                    periodBAmount: AskSpendSmartMoneyFormat.string(amounts.1),
                    change: AskSpendSmartMoneyFormat.string(amounts.1 - amounts.0)
                )
            }
            .sorted { abs(($0.change as NSString).doubleValue) > abs(($1.change as NSString).doubleValue) }

        return PeriodComparisonResult(
            periodASpent: AskSpendSmartMoneyFormat.string(spentA),
            periodBSpent: AskSpendSmartMoneyFormat.string(spentB),
            difference: AskSpendSmartMoneyFormat.string(spentB - spentA),
            categoryChanges: changes
        )
    }

    // MARK: - 7. Hypothetical: change the monthly savings goal

    struct HypotheticalSavingsGoalResult: Sendable, Equatable {
        let hypotheticalSavingsGoal: String
        let currentFlexibleSpendingAvailable: String
        let hypotheticalFlexibleSpendingAvailable: String
        let hypotheticalRecommendedWeeklySpending: String
    }

    /// Reuses `MonthlyPlanScenarioViewModel` — the SAME non-persistent "what if" sandbox the real
    /// Monthly Plan Scenario Builder uses — never a second, competing what-if calculation. This
    /// view model is structurally incapable of writing to SwiftData (see its own header comment),
    /// so calling it here for a one-off AI-assistant query is safe by construction.
    func hypotheticalSavingsGoal(_ newGoal: Decimal) -> HypotheticalSavingsGoalResult {
        let viewModel = MonthlyPlanScenarioViewModel(
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: monthlyPlanSettings,
            weeklyBudgetLimit: budgetSettings?.weeklySpendingLimit ?? 0,
            transactions: transactions,
            month: currentMonth,
            weekInterval: currentWeek,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold
        )
        let clampedGoal = max(0, newGoal)
        viewModel.changeMonthlySavingsGoal(clampedGoal)
        return HypotheticalSavingsGoalResult(
            hypotheticalSavingsGoal: AskSpendSmartMoneyFormat.string(clampedGoal),
            currentFlexibleSpendingAvailable: AskSpendSmartMoneyFormat.string(viewModel.currentSummary.flexibleSpendingAvailable),
            hypotheticalFlexibleSpendingAvailable: AskSpendSmartMoneyFormat.string(viewModel.scenarioSummary.flexibleSpendingAvailable),
            hypotheticalRecommendedWeeklySpending: AskSpendSmartMoneyFormat.string(viewModel.scenarioSummary.recommendedWeeklySpendingLimit)
        )
    }

    // MARK: - 8. Hypothetical: change the weekly spending limit

    struct HypotheticalWeeklySpendingResult: Sendable, Equatable {
        let hypotheticalWeeklyLimit: String
        let actualSpentThisWeek: String
        let remaining: String
        let isOverBudget: Bool
        let overBudgetAmount: String
    }

    /// Uses the SAME authoritative `BudgetCalculator` weekly math the real Weekly Budget screen
    /// uses, applied to a hypothetical limit against this week's REAL actual spending — never a
    /// separate estimate.
    func hypotheticalWeeklySpending(limit: Decimal) -> HypotheticalWeeklySpendingResult {
        let clampedLimit = max(0, limit)
        let spent = BudgetCalculator.weeklyActualSpending(
            transactions,
            in: currentWeek,
            includePending: includePending,
            autoTrackedAccountIds: autoTrackedAccountIds,
            excludedTransactionIDs: excludedTransactionIDs
        )
        let status = BudgetCalculator.status(spent: spent, limit: clampedLimit, warningThreshold: warningThreshold)
        return HypotheticalWeeklySpendingResult(
            hypotheticalWeeklyLimit: AskSpendSmartMoneyFormat.string(clampedLimit),
            actualSpentThisWeek: AskSpendSmartMoneyFormat.string(spent),
            remaining: AskSpendSmartMoneyFormat.string(BudgetCalculator.remaining(limit: clampedLimit, spent: spent)),
            isOverBudget: status == .over,
            overBudgetAmount: AskSpendSmartMoneyFormat.string(BudgetCalculator.overBudgetAmount(spent: spent, limit: clampedLimit))
        )
    }

    // MARK: - 9. Budget Exclusions — FULL VISIBILITY PHASE
    //
    // ROOT-CAUSE FIX for Scott's reported failure: "how many Budget Exclusions do I have checked"
    // routed into Monthly Plan because NO dedicated tool existed for this domain at all — the only
    // broad tool (getFinancialSummary) doesn't touch `excludedTransactionIDs`, so the model fell
    // back to what it did have. This is the required, explicit fix: a tool whose name/description
    // can ONLY be about Budget Exclusions. Reuses the exact canonical
    // `BudgetSettings.excludeTransactionsEnabled`/`excludedTransactionIDs` architecture every other
    // Budget Exclusions consumer (`ExcludeTransactionsView`, `BudgetCalculator.excludeTransactions`)
    // already reads — never a parallel exclusion system.

    struct ExcludedTransactionResult: Sendable, Equatable {
        let date: String
        let amount: String
        let type: String
        let description: String
        let category: String?
        let accountName: String?
        let isPending: Bool
    }

    struct BudgetExclusionsResult: Sendable, Equatable {
        let isEnabled: Bool
        /// The number of transactions the user has literally CHECKED in Budget Exclusions —
        /// `excludedTransactionIDs.count` itself, never filtered by whether each id still resolves
        /// to a live transaction (a stale/missing id is still something the user "checked"; see
        /// `totalAmount`'s own note for how a stale id is handled there instead).
        let count: Int
        /// DECISION (Part 4): a SIGNED NET total using the exact same expense-negative/income-
        /// positive display convention already established elsewhere in this app (Activity's own
        /// `signedActivityAmount`, `TransactionCSVExportService.signedAmount(for:)`) — never a raw
        /// magnitude sum, which would misleadingly combine unlike-signed transaction types into one
        /// number, and never a newly-invented convention. A stale/missing excluded id (no longer
        /// matches any transaction) is silently skipped from this total — there is nothing safe to
        /// total for a transaction that no longer exists — but never fabricated or guessed at.
        let totalAmount: String
        let transactions: [ExcludedTransactionResult]
        let totalMatchCount: Int
        let truncated: Bool
    }

    /// The app-wide signed DISPLAY convention (expense/transfer-out negative, income/refund/
    /// transfer-in positive) — same mapping `ExpenseListView.signedActivityAmount` and
    /// `TransactionCSVExportService.signedAmount(for:)` already use. Duplicated here (a 3rd private
    /// copy of the same tiny switch) rather than factored into one shared helper, matching this
    /// app's own existing precedent of two independent private copies already — not introducing a
    /// new cross-file dependency for a single switch statement.
    private func signedDisplayAmount(for transaction: FinanceTransaction) -> Decimal {
        switch transaction.type {
        case .expense, .transferWithdrawal, .transferToSavings: return -transaction.amount
        case .refund, .income, .transfer, .creditCardPayment, .balanceAdjustment, .transferDeposit: return transaction.amount
        }
    }

    /// RUNTIME RELIABILITY PHASE — `dateRange` is optional (default `nil` = all-time, the exact
    /// pre-existing behavior every current caller/test relies on) so a natural-language request
    /// like "the total of excluded transactions in the past two weeks" can be answered with a
    /// SINGLE deterministic call rather than the model trying to filter/re-sum an all-time list
    /// itself. Filter order is fixed and mandatory, never reordered: (1) read
    /// `excludeTransactionsEnabled`, (2) read `excludedTransactionIDs`, (3) resolve those ids to
    /// live transactions, (4) apply `dateRange` if given, (5) count, (6) total, (7) bounded
    /// details — an ordinary non-excluded transaction is never considered at any step. When
    /// `dateRange` is supplied, `count`/`totalAmount`/`transactions` all reflect the DATE-FILTERED
    /// subset (e.g. 7 of 10 checked exclusions in range), not the raw all-time checked-id count.
    func budgetExclusions(resultLimit: Int = 50, dateRange: DateInterval? = nil) -> BudgetExclusionsResult {
        let isEnabled = budgetSettings?.excludeTransactionsEnabled == true
        let checkedIDs = Set(budgetSettings?.excludedTransactionIDs ?? [])
        guard isEnabled, !checkedIDs.isEmpty else {
            return BudgetExclusionsResult(
                isEnabled: isEnabled, count: isEnabled ? checkedIDs.count : 0,
                totalAmount: AskSpendSmartMoneyFormat.string(0), transactions: [], totalMatchCount: 0, truncated: false
            )
        }
        var matched = transactions.filter { checkedIDs.contains($0.id) }
        if let dateRange {
            matched = matched.filter { dateRange.contains($0.date) }
        }
        let total = matched.reduce(Decimal(0)) { $0 + signedDisplayAmount(for: $1) }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let sorted = matched.sorted { $0.date > $1.date }
        let limited = Array(sorted.prefix(resultLimit))
        let details = limited.map { transaction in
            ExcludedTransactionResult(
                date: dateFormatter.string(from: transaction.date),
                amount: AskSpendSmartMoneyFormat.string(transaction.amount),
                type: transaction.type.rawValue,
                description: transaction.displayName,
                category: transaction.category?.name,
                accountName: resolvedAccountName(for: transaction),
                isPending: transaction.isPending
            )
        }
        return BudgetExclusionsResult(
            isEnabled: isEnabled,
            count: dateRange == nil ? checkedIDs.count : matched.count,
            totalAmount: AskSpendSmartMoneyFormat.string(total),
            transactions: details,
            totalMatchCount: matched.count,
            truncated: matched.count > details.count
        )
    }

    // MARK: - 10. Budget Settings — FULL VISIBILITY PHASE

    struct BudgetSettingsResult: Sendable, Equatable {
        let includePendingTransactions: Bool
        let excludeTransactionsEnabled: Bool
        let excludedTransactionsCount: Int
        let warningThresholdPercent: Int
        let weekStartsOnSunday: Bool
        let autoCalculateAccountNames: [String]
    }

    func budgetSettingsStatus() -> BudgetSettingsResult {
        let autoNames: [String] = autoTrackedAccountIds.compactMap { plaidAccountId in
            for connection in plaidConnections {
                if let balance = connection.cachedBalances?[plaidAccountId] { return balance.name ?? connection.institutionName }
            }
            return nil
        }.sorted()
        return BudgetSettingsResult(
            includePendingTransactions: includePending,
            excludeTransactionsEnabled: budgetSettings?.excludeTransactionsEnabled == true,
            excludedTransactionsCount: budgetSettings?.excludedTransactionIDs?.count ?? 0,
            warningThresholdPercent: Int((warningThreshold * 100).rounded()),
            weekStartsOnSunday: weekStartsOnSunday,
            autoCalculateAccountNames: autoNames
        )
    }

    // MARK: - 11. Weekly status — FULL VISIBILITY PHASE
    //
    // Reuses the EXACT SAME `MonthlyPlanCalculator.summary` call `financialSummary()` above already
    // makes, extracting only the weekly-scoped fields — guarantees byte-identical results with the
    // Weekly Budget screen and `financialSummary`, never a second calculation. A dedicated tool
    // exists purely for ROUTING clarity (a "Weekly" question should reach a tool literally named
    // for Weekly), not because the math differs.

    struct WeeklyStatusResult: Sendable, Equatable {
        let weekStartDate: String
        let weekEndDate: String
        let weeklyLimit: String
        let actualSpentThisWeek: String
        let remaining: String
        let isOverBudget: Bool
        let overBudgetAmount: String
    }

    func weeklyStatus() -> WeeklyStatusResult {
        let summary = MonthlyPlanCalculator.summary(
            month: currentMonth,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            planSettings: monthlyPlanSettings,
            weeklyBudgetLimit: budgetSettings?.weeklySpendingLimit ?? 0,
            transactions: transactions,
            weekInterval: currentWeek,
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: includePending,
            warningThreshold: warningThreshold,
            autoTrackedAccountIds: autoTrackedAccountIds,
            excludedTransactionIDs: excludedTransactionIDs
        )
        let status = BudgetCalculator.status(spent: summary.actualSpentThisWeek, limit: summary.currentManualWeeklyBudget, warningThreshold: warningThreshold)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        return WeeklyStatusResult(
            weekStartDate: dateFormatter.string(from: currentWeek.start),
            weekEndDate: dateFormatter.string(from: currentWeek.end),
            weeklyLimit: AskSpendSmartMoneyFormat.string(summary.currentManualWeeklyBudget),
            actualSpentThisWeek: AskSpendSmartMoneyFormat.string(summary.actualSpentThisWeek),
            remaining: AskSpendSmartMoneyFormat.string(BudgetCalculator.remaining(limit: summary.currentManualWeeklyBudget, spent: summary.actualSpentThisWeek)),
            isOverBudget: status == .over,
            overBudgetAmount: AskSpendSmartMoneyFormat.string(BudgetCalculator.overBudgetAmount(spent: summary.actualSpentThisWeek, limit: summary.currentManualWeeklyBudget))
        )
    }

    // MARK: - 12. Manual Register visibility — FULL VISIBILITY PHASE

    struct ManualRegisterResult: Sendable, Equatable {
        let accountName: String
        let currentBalance: String
        let transactionCount: Int
        let depositsTotal: String
        let expensesTotal: String
        let transfersTotal: String
    }

    /// `accountNameFilter` narrows to accounts whose name contains it (case-insensitive); `nil`/
    /// empty or a filter matching nothing returns every non-archived Manual Account.
    func manualRegisterStatus(accountNameFilter: String?) -> [ManualRegisterResult] {
        let manualAccounts = accounts.filter { !$0.isArchived }
        let filtered: [Account] = {
            guard let accountNameFilter, !accountNameFilter.isEmpty else { return manualAccounts }
            let matches = manualAccounts.filter { $0.name.localizedCaseInsensitiveContains(accountNameFilter) }
            return matches.isEmpty ? manualAccounts : matches
        }()

        return filtered.map { account in
            let accountTransactions = transactions.filter { $0.account?.id == account.id }
            let deposits = accountTransactions.filter { $0.type == .income || $0.type == .refund }
            let expenses = accountTransactions.filter { $0.type == .expense }
            let transferTypes: Set<TransactionType> = [.transfer, .transferWithdrawal, .transferDeposit, .transferToSavings, .creditCardPayment]
            let transfers = accountTransactions.filter { transferTypes.contains($0.type) }
            return ManualRegisterResult(
                accountName: account.name,
                currentBalance: AskSpendSmartMoneyFormat.string(account.currentBalance),
                transactionCount: accountTransactions.count,
                depositsTotal: AskSpendSmartMoneyFormat.string(deposits.reduce(Decimal(0)) { $0 + $1.amount }),
                expensesTotal: AskSpendSmartMoneyFormat.string(expenses.reduce(Decimal(0)) { $0 + $1.amount }),
                transfersTotal: AskSpendSmartMoneyFormat.string(transfers.reduce(Decimal(0)) { $0 + $1.amount })
            )
        }
    }

    // MARK: - 13. Bills status — FULL VISIBILITY PHASE
    //
    // Reuses `MonthlyPlanCalculator.billPaymentVarianceBreakdown` — the SAME "which bill has at
    // least one linked payment transaction dated this month" logic Pay Bills' own planned-vs-actual
    // comparison already uses — as the paid/unpaid determination, never an independent one. Never
    // marks a bill paid/unpaid; strictly read-only.

    struct BillStatusResult: Sendable, Equatable {
        let name: String
        let plannedAmount: String
        let isPaidThisMonth: Bool
        let actualAmountPaid: String?
    }

    struct BillsStatusResult: Sendable, Equatable {
        let bills: [BillStatusResult]
        let unpaidCount: Int
        let unpaidTotal: String
        let paidCount: Int
        let paidTotal: String
    }

    func billsStatus() -> BillsStatusResult {
        let activeBills = recurringExpenses.filter(\.isActive)
        let breakdown = MonthlyPlanCalculator.billPaymentVarianceBreakdown(recurringExpenses: activeBills, transactions: transactions, in: currentMonth)
        let actualByBillID = Dictionary(uniqueKeysWithValues: breakdown.map { ($0.bill.id, $0.actual) })

        var results: [BillStatusResult] = []
        var unpaidTotal = Decimal(0)
        var paidTotal = Decimal(0)
        for bill in activeBills.sorted(by: { $0.name < $1.name }) {
            let planned = FixedBillsTimingFilter.displayAmount(for: bill)
            if let actual = actualByBillID[bill.id] {
                results.append(BillStatusResult(name: bill.name, plannedAmount: AskSpendSmartMoneyFormat.string(planned), isPaidThisMonth: true, actualAmountPaid: AskSpendSmartMoneyFormat.string(actual)))
                paidTotal += actual
            } else {
                results.append(BillStatusResult(name: bill.name, plannedAmount: AskSpendSmartMoneyFormat.string(planned), isPaidThisMonth: false, actualAmountPaid: nil))
                unpaidTotal += planned
            }
        }
        return BillsStatusResult(
            bills: results,
            unpaidCount: results.filter { !$0.isPaidThisMonth }.count,
            unpaidTotal: AskSpendSmartMoneyFormat.string(unpaidTotal),
            paidCount: actualByBillID.count,
            paidTotal: AskSpendSmartMoneyFormat.string(paidTotal)
        )
    }

    // MARK: - 14. Savings status — FULL VISIBILITY PHASE
    //
    // Reuses `SavingsCalculator`/`SavedViaTransferCalculator` exactly as Quick Stats' own
    // `.savedThisMonth`/`.savedViaTransfer` tiles do — never a duplicate savings calculation.

    struct SavingsStatusResult: Sendable, Equatable {
        let savedThisMonthManualEntries: String
        let savedViaTransferThisMonth: String
        let monthlySavingsGoal: String
        let totalSavingsToDate: String
    }

    func savingsStatus() -> SavingsStatusResult {
        SavingsStatusResult(
            savedThisMonthManualEntries: AskSpendSmartMoneyFormat.string(SavingsCalculator.savedThisMonth(savingsEntries, in: currentMonth)),
            savedViaTransferThisMonth: AskSpendSmartMoneyFormat.string(SavedViaTransferCalculator.savedThisMonth(transactions, in: currentMonth)),
            monthlySavingsGoal: AskSpendSmartMoneyFormat.string(monthlyPlanSettings?.monthlySavingsGoal ?? 0),
            totalSavingsToDate: AskSpendSmartMoneyFormat.string(SavingsCalculator.totalSavingsToDate(savingsEntries))
        )
    }

    // MARK: - 15. App feature knowledge — FULL VISIBILITY PHASE
    //
    // A small, static, code-defined description source (Part 14) — the model must never guess
    // product functionality from a feature's name alone. Keyword-matched rather than requiring an
    // exact feature name, since a user's real phrasing varies ("what's Auto Calculate" / "what does
    // auto calculate do" / "explain auto calculate").

    struct AppFeatureInfoResult: Sendable, Equatable {
        let found: Bool
        let featureName: String?
        let description: String?
    }

    private static let featureDescriptions: [(keys: [String], name: String, description: String)] = [
        (["budget exclusion", "exclude transaction", "excluded transaction"], "Budget Exclusions",
         "Budget Exclusions lets you check off specific transactions to leave them out of your Weekly and Monthly spending totals, without deleting them — they still show up in Activity and your account history, they just don't count toward your budget."),
        (["auto calculate", "autocalculate"], "Auto Calculate",
         "Auto Calculate automatically counts a connected (bank-linked) account's real transactions toward your Weekly/Monthly spending, so you don't have to enter them by hand. You choose exactly which connected accounts are turned on for this in Settings."),
        (["monthly plan"], "Monthly Plan",
         "Monthly Plan is where you set your income, fixed bills, and savings goal for the month. From those, SpendSmart calculates how much flexible spending you have available, and your recommended weekly spending limit."),
        (["quick stat"], "Quick Stats",
         "Quick Stats are the small summary tiles on your Dashboard — Planned Weekly Spending, Spent This Week, Planned Monthly Spending, Projected Available After Spend, Saved This Month, and Saved (via transfer). You can choose which ones show in Settings."),
        (["manual register", "manual account"], "Manual Accounts / Register",
         "A Manual Account is a register you track by hand — like a checking account, cash wallet, or any account you don't connect through Plaid. You add deposits, expenses, and transfers yourself, and SpendSmart keeps a running balance."),
        (["activity"], "Activity",
         "Activity is the full list of your transactions — both from connected (bank-linked) accounts and your own Manual Accounts — with filtering by account, date, pending/posted status, and more. It's a factual record of everything that happened, independent of budget totals."),
        (["weekly budget", "weekly spending"], "Weekly Budget",
         "Weekly Budget shows how much you've spent this week against your weekly spending limit (derived from Monthly Plan), and how much you have left."),
        (["saving"], "Savings",
         "SpendSmart tracks savings two ways: money you manually log as saved this month, and money you transfer into a savings-type account (Saved via Transfer). Your Monthly Plan savings goal is the target amount you're aiming to save each month."),
        (["bill", "pay bills"], "Bills / Pay Bills",
         "Fixed Bills are the recurring bills you set up in Monthly Plan. Pay Bills lets you record a bill as paid by linking it to a Manual Account transaction — SpendSmart then tracks whether each bill has been paid yet this month.")
    ]

    func appFeatureInfo(topic: String) -> AppFeatureInfoResult {
        let normalized = topic.lowercased()
        for entry in Self.featureDescriptions {
            if entry.keys.contains(where: { normalized.contains($0) }) {
                return AppFeatureInfoResult(found: true, featureName: entry.name, description: entry.description)
            }
        }
        return AppFeatureInfoResult(found: false, featureName: nil, description: nil)
    }
}

/// FRESH SNAPSHOT PHASE — a mutable, thread-safe holder for the CURRENT `AskSpendSmartToolContext`,
/// so every registered `Tool` (see `AskSpendSmartToolProvider.swift`) reads through this box rather
/// than each holding its own snapshot fixed at session-creation time. Deliberately plain
/// Foundation, no `FoundationModels` import — like `AskSpendSmartToolContext` itself, this is
/// directly unit-testable on every deployment target this app supports.
///
/// WHY A LOCK, NOT A PLAIN `var`: `Tool.call(arguments:)` is `@concurrent` (FoundationModels may
/// invoke tool calls off the main actor, and possibly concurrently with each other), while
/// `update(_:)` is called from `@MainActor` code (`SystemAskSpendSmartService.updateToolContext`,
/// itself called from `AskSpendSmartConversationModel.send`) right before every new question. A
/// plain stored `var` mutated from one actor and read from another is a data race; the lock makes
/// both directions safe without requiring every tool to become `async`.
final class AskSpendSmartToolContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: AskSpendSmartToolContext

    init(_ context: AskSpendSmartToolContext) {
        self._current = context
    }

    var current: AskSpendSmartToolContext {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    func update(_ context: AskSpendSmartToolContext) {
        lock.lock()
        _current = context
        lock.unlock()
    }
}
