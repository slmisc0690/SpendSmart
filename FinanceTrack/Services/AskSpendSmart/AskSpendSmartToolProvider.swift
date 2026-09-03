import Foundation
import FoundationModels

/// Parses the plain `"yyyy-MM-dd"` date strings every Ask SpendSmart tool argument uses. Dates are
/// passed as `String`, never `Date`, across the `Tool` boundary — FoundationModels' documented
/// `@Generable` examples only ever show `String`/`Int`/`Double`/`[String]`/nested `@Generable`
/// types, never `Foundation.Date`, so a plain ISO date string is the safe, unambiguous choice here.
@available(iOS 26.0, *)
private enum AskSpendSmartDateParsing {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string)
    }
}

/// TRANSACTION SEARCH RELIABILITY FIX — safely converts the model's `Double` amount argument into
/// the `Decimal` the deterministic layer compares against, via a 2-decimal-place STRING round-trip
/// (`String(format: "%.2f", _:)` → `Decimal(string:)`) rather than `Decimal(aDouble)` directly —
/// binary floating point cannot exactly represent a value like `34.75`, so constructing a `Decimal`
/// straight from the `Double` can carry tiny binary-fraction artifacts into the comparison.
@available(iOS 26.0, *)
private enum AskSpendSmartAmountParsing {
    static func parse(_ value: Double?) -> Decimal? {
        guard let value else { return nil }
        return Decimal(string: String(format: "%.2f", value), locale: Locale(identifier: "en_US_POSIX"))
    }
}

// MARK: - @Generable mirrors of AskSpendSmartToolContext's plain Sendable result types
//
// `AskSpendSmartToolContext.swift` deliberately never imports FoundationModels, so it and its
// result types stay ordinary, iOS-17-compatible, directly-unit-testable Swift with no availability
// gating at all (see that file's own header). The types below are the ONLY place those results are
// translated into the `@Generable` shape `Tool.Output` requires — a mechanical field-for-field
// mirror, never a second calculation.

@available(iOS 26.0, *)
@Generable
struct GeneratedFinancialSummary {
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

    init(_ result: AskSpendSmartToolContext.FinancialSummaryResult) {
        monthlyIncome = result.monthlyIncome
        fixedBillsTotal = result.fixedBillsTotal
        monthlySavingsGoal = result.monthlySavingsGoal
        flexibleSpendingAvailable = result.flexibleSpendingAvailable
        plannedWeeklySpending = result.plannedWeeklySpending
        plannedMonthlySpending = result.plannedMonthlySpending
        weeklyActualSpending = result.weeklyActualSpending
        weeklyRemaining = result.weeklyRemaining
        monthlyActualSpending = result.monthlyActualSpending
        monthlyRemaining = result.monthlyRemaining
        weeklySpendingLimit = result.weeklySpendingLimit
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedAccountBalance {
    let name: String
    let accountType: String
    let isManual: Bool
    let institutionName: String?
    let currentBalance: String
    let availableBalance: String?
    let creditLimit: String?

    init(_ result: AskSpendSmartToolContext.AccountBalanceResult) {
        name = result.name
        accountType = result.accountType
        isManual = result.isManual
        institutionName = result.institutionName
        currentBalance = result.currentBalance
        availableBalance = result.availableBalance
        creditLimit = result.creditLimit
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedTransaction {
    let date: String
    let amount: String
    let type: String
    let description: String
    let category: String?
    let accountName: String?
    let isPending: Bool

    init(_ result: AskSpendSmartToolContext.TransactionResult) {
        date = result.date
        amount = result.amount
        type = result.type
        description = result.description
        category = result.category
        accountName = result.accountName
        isPending = result.isPending
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedCategoryTotal {
    let categoryName: String
    let total: String

    init(_ result: AskSpendSmartToolContext.CategoryTotalResult) {
        categoryName = result.categoryName
        total = result.total
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedMerchantTotal {
    let merchant: String
    let total: String
    let transactionCount: Int

    init(_ result: AskSpendSmartToolContext.MerchantTotalResult) {
        merchant = result.merchant
        total = result.total
        transactionCount = result.transactionCount
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedCategoryChange {
    let categoryName: String
    let periodAAmount: String
    let periodBAmount: String
    let change: String

    init(_ result: AskSpendSmartToolContext.CategoryChangeResult) {
        categoryName = result.categoryName
        periodAAmount = result.periodAAmount
        periodBAmount = result.periodBAmount
        change = result.change
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedPeriodComparison {
    let periodASpent: String
    let periodBSpent: String
    let difference: String
    let categoryChanges: [GeneratedCategoryChange]

    init(_ result: AskSpendSmartToolContext.PeriodComparisonResult) {
        periodASpent = result.periodASpent
        periodBSpent = result.periodBSpent
        difference = result.difference
        categoryChanges = result.categoryChanges.map(GeneratedCategoryChange.init)
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedHypotheticalSavingsGoal {
    let hypotheticalSavingsGoal: String
    let currentFlexibleSpendingAvailable: String
    let hypotheticalFlexibleSpendingAvailable: String
    let hypotheticalRecommendedWeeklySpending: String

    init(_ result: AskSpendSmartToolContext.HypotheticalSavingsGoalResult) {
        hypotheticalSavingsGoal = result.hypotheticalSavingsGoal
        currentFlexibleSpendingAvailable = result.currentFlexibleSpendingAvailable
        hypotheticalFlexibleSpendingAvailable = result.hypotheticalFlexibleSpendingAvailable
        hypotheticalRecommendedWeeklySpending = result.hypotheticalRecommendedWeeklySpending
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedHypotheticalWeeklySpending {
    let hypotheticalWeeklyLimit: String
    let actualSpentThisWeek: String
    let remaining: String
    let isOverBudget: Bool
    let overBudgetAmount: String

    init(_ result: AskSpendSmartToolContext.HypotheticalWeeklySpendingResult) {
        hypotheticalWeeklyLimit = result.hypotheticalWeeklyLimit
        actualSpentThisWeek = result.actualSpentThisWeek
        remaining = result.remaining
        isOverBudget = result.isOverBudget
        overBudgetAmount = result.overBudgetAmount
    }
}

// MARK: - 1. Financial summary

@available(iOS 26.0, *)
struct GetFinancialSummaryTool: Tool {
    let name = "getFinancialSummary"
    let description = """
        Gets the user's MONTHLY PLAN status: current real monthly income, fixed bills total, \
        savings goal, flexible spending available, planned weekly/monthly spending, actual \
        weekly/monthly spending so far, and weekly/monthly remaining — all authoritative, \
        already-computed figures from the app's own Monthly Plan and Budget calculators. Use this \
        for Monthly Plan questions: income, fixed bills, savings goal, flexible spending, "this \
        month". Do NOT use this for Budget Exclusions (use getBudgetExclusions), a Weekly-only \
        question (use getWeeklyStatus), Bills paid/unpaid status (use getBillsStatus), or savings \
        details (use getSavingsStatus) — this tool does not cover those domains.
        """

    @Generable
    struct Arguments {}

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedFinancialSummary {
        GeneratedFinancialSummary(context.current.financialSummary())
    }
}

// MARK: - 2. Account balances

@available(iOS 26.0, *)
struct GetAccountBalancesTool: Tool {
    let name = "getAccountBalances"
    let description = """
        Gets the current balance of every manual and connected (bank-linked) account the user has, \
        including credit limits and available balances where applicable. Use this for any question \
        about how much money is in an account or across all accounts.
        """

    @Generable
    struct Arguments {}

    @Generable
    struct Output {
        let accounts: [GeneratedAccountBalance]
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> Output {
        Output(accounts: context.current.accountBalances().map(GeneratedAccountBalance.init))
    }
}

// MARK: - 3. Transaction search

@available(iOS 26.0, *)
struct SearchTransactionsTool: Tool {
    let name = "searchTransactions"
    let description = """
        Finds individual real transactions matching any combination of a date (or date range), an \
        exact dollar amount, account/institution name, merchant/description text, category name, \
        and/or pending-vs-posted state. ALWAYS pass exactAmount when the user mentions a specific \
        dollar figure (e.g. "$34.75") — this is the most reliable way to pin down one exact \
        transaction, especially combined with a date. ALWAYS pass startDate/endDate (set both to \
        the SAME date for "on August 23") when the user mentions a specific day, "yesterday", \
        "this week", "last week", "this month", or "last month" — resolve relative phrases using \
        today's date, given in your instructions. Returns totalMatchCount (how many transactions \
        actually matched) and resultsReturned/truncated so you can tell the user if there were more \
        matches than were shown. If zero transactions are returned, tell the user none were found —
        never invent one. Use this for ANY question about a specific purchase, "what was my \
        transaction for $X", "did I have a transaction on DATE", an account's recent activity, or \
        pending charges — a summary/total tool alone cannot answer these.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Start of the date range, as YYYY-MM-DD. For a single specific day (e.g. \"on August 23\"), set this AND endDate to that same date. Omit to not filter by date at all.")
        var startDate: String?
        @Guide(description: "End of the date range, as YYYY-MM-DD, inclusive of the whole day. For a single specific day, set this AND startDate to that same date. Omit to not filter by end date.")
        var endDate: String?
        @Guide(description: "The exact transaction amount in dollars if the user mentioned one, e.g. 34.75. Always a positive number, regardless of whether it was an expense or a deposit/refund. Omit if the user did not mention a specific amount.")
        var exactAmount: Double?
        @Guide(description: "Account or institution name to filter by, e.g. 'Chase', 'American Express', or 'Everyday Checking'. Omit to include every account.")
        var accountName: String?
        @Guide(description: "Merchant or description text to filter by, e.g. 'Amazon'. Omit to include every merchant.")
        var merchant: String?
        @Guide(description: "Category name to filter by, e.g. 'Groceries'. Omit to include every category.")
        var category: String?
        @Guide(description: "Set to true ONLY if the user specifically asked about pending (not yet posted) transactions.")
        var pendingOnly: Bool
        @Guide(description: "Set to true ONLY if the user specifically asked about already-posted (settled, not pending) transactions.")
        var postedOnly: Bool
    }

    @Generable
    struct Output {
        let transactions: [GeneratedTransaction]
        /// How many transactions matched every filter, BEFORE any result-count cap — always
        /// computed against the full local transaction set, never a pre-capped slice.
        let totalMatchCount: Int
        let resultsReturned: Int
        let truncated: Bool
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> Output {
        // A model that sets BOTH flags true (a genuine possibility, not just a theoretical one)
        // must never silently produce a permanently-empty, self-contradictory filter — only an
        // UNAMBIGUOUS single flag narrows the search; both-true or both-false both mean "no
        // pending/posted restriction," matching the natural default of searching everything.
        let pendingFilter: AskSpendSmartToolContext.PendingFilter
        switch (arguments.pendingOnly, arguments.postedOnly) {
        case (true, false): pendingFilter = .pendingOnly
        case (false, true): pendingFilter = .postedOnly
        default: pendingFilter = .all
        }
        let result = context.current.searchTransactions(
            startDate: AskSpendSmartDateParsing.parse(arguments.startDate),
            endDate: AskSpendSmartDateParsing.parse(arguments.endDate),
            exactAmount: AskSpendSmartAmountParsing.parse(arguments.exactAmount),
            accountName: arguments.accountName,
            merchant: arguments.merchant,
            category: arguments.category,
            pendingFilter: pendingFilter
        )
        return Output(
            transactions: result.transactions.map(GeneratedTransaction.init),
            totalMatchCount: result.totalMatchCount,
            resultsReturned: result.resultsReturned,
            truncated: result.truncated
        )
    }
}

// MARK: - 4. Category spending totals

@available(iOS 26.0, *)
struct GetCategorySpendingTool: Tool {
    let name = "getCategorySpending"
    let description = """
        Gets total spending broken down by category (e.g. Groceries, Dining, Entertainment) for a \
        given date range. Use this for questions like "how much have I spent on restaurants this \
        month" or "what are my biggest spending categories."
        """

    @Generable
    struct Arguments {
        @Guide(description: "Start of the date range, as YYYY-MM-DD.")
        var startDate: String
        @Guide(description: "End of the date range, as YYYY-MM-DD.")
        var endDate: String
    }

    @Generable
    struct Output {
        let categories: [GeneratedCategoryTotal]
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> Output {
        guard let start = AskSpendSmartDateParsing.parse(arguments.startDate),
              let end = AskSpendSmartDateParsing.parse(arguments.endDate) else {
            return Output(categories: [])
        }
        return Output(categories: context.current.categorySpending(startDate: start, endDate: end).map(GeneratedCategoryTotal.init))
    }
}

// MARK: - 5. Merchant spending totals

@available(iOS 26.0, *)
struct GetMerchantSpendingTool: Tool {
    let name = "getMerchantSpending"
    let description = """
        Gets total spending broken down by merchant/description for a given date range, optionally \
        filtered to one merchant. Use this for questions like "how much did I spend at Amazon over \
        the last 90 days" or "which merchant do I spend the most at."
        """

    @Generable
    struct Arguments {
        @Guide(description: "Start of the date range, as YYYY-MM-DD.")
        var startDate: String
        @Guide(description: "End of the date range, as YYYY-MM-DD.")
        var endDate: String
        @Guide(description: "A specific merchant name to filter by, e.g. 'Amazon'. Omit to get every merchant.")
        var merchantFilter: String?
    }

    @Generable
    struct Output {
        let merchants: [GeneratedMerchantTotal]
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> Output {
        guard let start = AskSpendSmartDateParsing.parse(arguments.startDate),
              let end = AskSpendSmartDateParsing.parse(arguments.endDate) else {
            return Output(merchants: [])
        }
        return Output(merchants: context.current.merchantSpending(startDate: start, endDate: end, merchantFilter: arguments.merchantFilter).map(GeneratedMerchantTotal.init))
    }
}

// MARK: - 6. Compare two periods

@available(iOS 26.0, *)
struct ComparePeriodsTool: Tool {
    let name = "compareSpendingPeriods"
    let description = """
        Compares total spending and per-category spending between two date ranges (period A vs. \
        period B). Use this for questions like "what changed the most between this month and last \
        month" or "compare my spending this week to last week."
        """

    @Generable
    struct Arguments {
        @Guide(description: "Start of period A, as YYYY-MM-DD.")
        var periodAStart: String
        @Guide(description: "End of period A, as YYYY-MM-DD.")
        var periodAEnd: String
        @Guide(description: "Start of period B, as YYYY-MM-DD.")
        var periodBStart: String
        @Guide(description: "End of period B, as YYYY-MM-DD.")
        var periodBEnd: String
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedPeriodComparison {
        guard let aStart = AskSpendSmartDateParsing.parse(arguments.periodAStart),
              let aEnd = AskSpendSmartDateParsing.parse(arguments.periodAEnd),
              let bStart = AskSpendSmartDateParsing.parse(arguments.periodBStart),
              let bEnd = AskSpendSmartDateParsing.parse(arguments.periodBEnd) else {
            return GeneratedPeriodComparison(AskSpendSmartToolContext.PeriodComparisonResult(periodASpent: "0.00", periodBSpent: "0.00", difference: "0.00", categoryChanges: []))
        }
        return GeneratedPeriodComparison(context.current.comparePeriods(periodAStart: aStart, periodAEnd: aEnd, periodBStart: bStart, periodBEnd: bEnd))
    }
}

// MARK: - 7. Hypothetical savings goal

@available(iOS 26.0, *)
struct HypotheticalSavingsGoalTool: Tool {
    let name = "runHypotheticalSavingsGoal"
    let description = """
        Calculates what Flexible Spending Available and the recommended weekly spending would be \
        IF the user's Monthly Savings Goal were changed to a hypothetical amount — using the same \
        Monthly Plan formulas the real app uses, without changing anything real. Use this for \
        "what if I saved $X this month" style questions. This is advisory only — it never changes \
        the user's real savings goal.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The hypothetical monthly savings goal amount, in dollars.")
        var monthlySavingsGoal: Double
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedHypotheticalSavingsGoal {
        GeneratedHypotheticalSavingsGoal(context.current.hypotheticalSavingsGoal(Decimal(arguments.monthlySavingsGoal)))
    }
}

// MARK: - 8. Hypothetical weekly spending limit

@available(iOS 26.0, *)
struct HypotheticalWeeklySpendingTool: Tool {
    let name = "runHypotheticalWeeklySpendingLimit"
    let description = """
        Calculates whether the user would be over or under budget THIS WEEK if their weekly \
        spending limit were a hypothetical amount, compared against their real actual spending so \
        far this week. Use this for "what if I changed my weekly spending limit to $X" style \
        questions. This is advisory only — it never changes the user's real weekly spending limit.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The hypothetical weekly spending limit, in dollars.")
        var weeklyLimit: Double
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedHypotheticalWeeklySpending {
        GeneratedHypotheticalWeeklySpending(context.current.hypotheticalWeeklySpending(limit: Decimal(arguments.weeklyLimit)))
    }
}

// MARK: - FULL VISIBILITY PHASE — @Generable mirrors for the 7 new domains

@available(iOS 26.0, *)
@Generable
struct GeneratedExcludedTransaction {
    let date: String
    let amount: String
    let type: String
    let description: String
    let category: String?
    let accountName: String?
    let isPending: Bool

    init(_ result: AskSpendSmartToolContext.ExcludedTransactionResult) {
        date = result.date
        amount = result.amount
        type = result.type
        description = result.description
        category = result.category
        accountName = result.accountName
        isPending = result.isPending
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedBudgetExclusions {
    let isEnabled: Bool
    let count: Int
    let totalAmount: String
    let transactions: [GeneratedExcludedTransaction]
    let totalMatchCount: Int
    let truncated: Bool

    init(_ result: AskSpendSmartToolContext.BudgetExclusionsResult) {
        isEnabled = result.isEnabled
        count = result.count
        totalAmount = result.totalAmount
        transactions = result.transactions.map(GeneratedExcludedTransaction.init)
        totalMatchCount = result.totalMatchCount
        truncated = result.truncated
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedBudgetSettings {
    let includePendingTransactions: Bool
    let excludeTransactionsEnabled: Bool
    let excludedTransactionsCount: Int
    let warningThresholdPercent: Int
    let weekStartsOnSunday: Bool
    let autoCalculateAccountNames: [String]

    init(_ result: AskSpendSmartToolContext.BudgetSettingsResult) {
        includePendingTransactions = result.includePendingTransactions
        excludeTransactionsEnabled = result.excludeTransactionsEnabled
        excludedTransactionsCount = result.excludedTransactionsCount
        warningThresholdPercent = result.warningThresholdPercent
        weekStartsOnSunday = result.weekStartsOnSunday
        autoCalculateAccountNames = result.autoCalculateAccountNames
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedWeeklyStatus {
    let weekStartDate: String
    let weekEndDate: String
    let weeklyLimit: String
    let actualSpentThisWeek: String
    let remaining: String
    let isOverBudget: Bool
    let overBudgetAmount: String

    init(_ result: AskSpendSmartToolContext.WeeklyStatusResult) {
        weekStartDate = result.weekStartDate
        weekEndDate = result.weekEndDate
        weeklyLimit = result.weeklyLimit
        actualSpentThisWeek = result.actualSpentThisWeek
        remaining = result.remaining
        isOverBudget = result.isOverBudget
        overBudgetAmount = result.overBudgetAmount
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedManualRegister {
    let accountName: String
    let currentBalance: String
    let transactionCount: Int
    let depositsTotal: String
    let expensesTotal: String
    let transfersTotal: String

    init(_ result: AskSpendSmartToolContext.ManualRegisterResult) {
        accountName = result.accountName
        currentBalance = result.currentBalance
        transactionCount = result.transactionCount
        depositsTotal = result.depositsTotal
        expensesTotal = result.expensesTotal
        transfersTotal = result.transfersTotal
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedBillStatus {
    let name: String
    let plannedAmount: String
    let isPaidThisMonth: Bool
    let actualAmountPaid: String?

    init(_ result: AskSpendSmartToolContext.BillStatusResult) {
        name = result.name
        plannedAmount = result.plannedAmount
        isPaidThisMonth = result.isPaidThisMonth
        actualAmountPaid = result.actualAmountPaid
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedBillsStatus {
    let bills: [GeneratedBillStatus]
    let unpaidCount: Int
    let unpaidTotal: String
    let paidCount: Int
    let paidTotal: String

    init(_ result: AskSpendSmartToolContext.BillsStatusResult) {
        bills = result.bills.map(GeneratedBillStatus.init)
        unpaidCount = result.unpaidCount
        unpaidTotal = result.unpaidTotal
        paidCount = result.paidCount
        paidTotal = result.paidTotal
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedSavingsStatus {
    let savedThisMonthManualEntries: String
    let savedViaTransferThisMonth: String
    let monthlySavingsGoal: String
    let totalSavingsToDate: String

    init(_ result: AskSpendSmartToolContext.SavingsStatusResult) {
        savedThisMonthManualEntries = result.savedThisMonthManualEntries
        savedViaTransferThisMonth = result.savedViaTransferThisMonth
        monthlySavingsGoal = result.monthlySavingsGoal
        totalSavingsToDate = result.totalSavingsToDate
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedAppFeatureInfo {
    let found: Bool
    let featureName: String?
    let description: String?

    init(_ result: AskSpendSmartToolContext.AppFeatureInfoResult) {
        found = result.found
        featureName = result.featureName
        description = result.description
    }
}

// MARK: - 9. Budget Exclusions — REQUIRED FIX for the Monthly-Plan-misroute failure

@available(iOS 26.0, *)
struct GetBudgetExclusionsTool: Tool {
    let name = "getBudgetExclusions"
    let description = """
        Gets the user's Budget Exclusions — transactions they have specifically checked to leave \
        OUT of their Weekly/Monthly spending totals. Returns whether Budget Exclusions is enabled, \
        the EXACT count of currently-excluded transactions, their exact signed total dollar amount, \
        and the excluded transactions themselves (date, amount, merchant, category, account, \
        pending status). ALWAYS use this tool — never getFinancialSummary or getMonthlyPlanStatus — \
        for any question containing the words "exclude", "excluded", "exclusion", or "Budget \
        Exclusions", including "how many Budget Exclusions do I have", "what is the total of my \
        excluded transactions", and "which transactions are excluded from my budget". \
        DATE-RANGE PHASE: pass startDate/endDate (both YYYY-MM-DD) to restrict the count/total to \
        just excluded transactions in that range — e.g. for "the past two weeks" or "last 14 days," \
        resolve to the 14 calendar days ending today (inclusive) using today's date from your \
        instructions, and pass that as startDate/endDate. Omit both to get the all-time total.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Start of the date range, as YYYY-MM-DD. Resolve relative phrases like \"past two weeks\"/\"last 14 days\" using today's date from your instructions. Omit to get the all-time total with no date filter.")
        var startDate: String?
        @Guide(description: "End of the date range, as YYYY-MM-DD, inclusive of the whole day. Normally today for a \"past N days/weeks\" phrase. Omit to get the all-time total with no date filter.")
        var endDate: String?
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedBudgetExclusions {
        let start = AskSpendSmartDateParsing.parse(arguments.startDate)
        let end = AskSpendSmartDateParsing.parse(arguments.endDate)
        let dateRange: DateInterval? = {
            guard let start, let end else { return nil }
            return DateInterval(start: DateRangeHelper.dayRangeContaining(start).start, end: DateRangeHelper.dayRangeContaining(end).end)
        }()
        return GeneratedBudgetExclusions(context.current.budgetExclusions(dateRange: dateRange))
    }
}

// MARK: - 10. Budget Settings

@available(iOS 26.0, *)
struct GetBudgetSettingsTool: Tool {
    let name = "getBudgetSettings"
    let description = """
        Gets the user's current Budget Settings: whether pending (not-yet-posted) transactions are \
        included in spending totals, whether Budget Exclusions is turned on and how many \
        transactions are excluded, the spending warning threshold percentage, whether the week \
        starts on Sunday, and which connected accounts are enabled for Auto Calculate. Use this for \
        questions like "do I have pending transactions included in my budget", "what is my warning \
        threshold", or "which accounts are used for Auto Calculate". For the excluded transactions \
        THEMSELVES (count/total/details), use getBudgetExclusions instead.
        """

    @Generable
    struct Arguments {}

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedBudgetSettings {
        GeneratedBudgetSettings(context.current.budgetSettingsStatus())
    }
}

// MARK: - 11. Weekly status

@available(iOS 26.0, *)
struct GetWeeklyStatusTool: Tool {
    let name = "getWeeklyStatus"
    let description = """
        Gets the user's CURRENT WEEK spending status: the current week's date range, their weekly \
        spending limit, actual amount spent so far this week, remaining amount, and whether they \
        are over budget. Use this for any Weekly question: "how much have I spent this week", "am \
        I over budget this week", "how much do I have left this week", "what is my weekly budget". \
        Do NOT use getFinancialSummary or getMonthlyPlanStatus for a Weekly-specific question — use \
        this tool instead.
        """

    @Generable
    struct Arguments {}

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedWeeklyStatus {
        GeneratedWeeklyStatus(context.current.weeklyStatus())
    }
}

// MARK: - 12. Manual Register visibility

@available(iOS 26.0, *)
struct GetManualRegisterTool: Tool {
    let name = "getManualRegister"
    let description = """
        Gets Manual Account register information: current balance, total number of transactions, \
        and totals for deposits, expenses, and transfers in that register. Use this for questions \
        about a Manual Account/register specifically — "what is my checking register balance", \
        "what deposits have I added", "what transfers are in my register". Optionally filter by \
        account name; omit to get every Manual Account. This is DIFFERENT from getAccountBalances \
        (which covers both manual AND connected accounts, balance only) — use this tool when the \
        question is about register activity (deposits/expenses/transfers/transaction count), not \
        just a balance.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Optional Manual Account name to filter to a single register (e.g. \"Checking\"). Leave empty to get every Manual Account.")
        var accountName: String?
    }

    @Generable
    struct Output {
        let registers: [GeneratedManualRegister]
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> Output {
        Output(registers: context.current.manualRegisterStatus(accountNameFilter: arguments.accountName).map(GeneratedManualRegister.init))
    }
}

// MARK: - 13. Bills status

@available(iOS 26.0, *)
struct GetBillsStatusTool: Tool {
    let name = "getBillsStatus"
    let description = """
        Gets the status of the user's active Fixed Bills for the CURRENT month: which bills have \
        already been paid this month (with the actual amount paid) and which are still unpaid (with \
        the planned amount), plus paid/unpaid counts and totals. Use this for "what bills do I still \
        have left this month", "how much do I have left to pay in bills", "what bills have I already \
        paid". This is READ ONLY — it never marks a bill paid or executes Pay Bills.
        """

    @Generable
    struct Arguments {}

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedBillsStatus {
        GeneratedBillsStatus(context.current.billsStatus())
    }
}

// MARK: - 14. Savings status

@available(iOS 26.0, *)
struct GetSavingsStatusTool: Tool {
    let name = "getSavingsStatus"
    let description = """
        Gets the user's savings information: money manually logged as saved this month, money saved \
        via transfer to a savings account this month, their Monthly Plan savings goal, and total \
        savings logged to date. Use this for "how much have I saved this month", "what is my savings \
        goal", "how much more do I need to save".
        """

    @Generable
    struct Arguments {}

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedSavingsStatus {
        GeneratedSavingsStatus(context.current.savingsStatus())
    }
}

// MARK: - 15. App feature knowledge

@available(iOS 26.0, *)
struct GetAppFeatureInfoTool: Tool {
    let name = "getAppFeatureInfo"
    let description = """
        Explains what a SpendSmart FEATURE does — factual, app-accurate descriptions of Budget \
        Exclusions, Auto Calculate, Monthly Plan, Quick Stats, Manual Accounts/Register, Activity, \
        Weekly Budget, Savings, and Bills/Pay Bills. Use this ONLY for "what does X do" / "what is \
        X" / "explain X" questions about a FEATURE NAME — never for the user's own actual numbers, \
        settings, or transactions (use the specific data tool for those instead). If the topic isn't \
        recognized, `found` will be false — tell the user you don't have information on that.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The feature name or topic the user is asking about, e.g. \"Budget Exclusions\", \"Auto Calculate\", \"Quick Stats\".")
        var topic: String
    }

    let context: AskSpendSmartToolContextBox

    func call(arguments: Arguments) async throws -> GeneratedAppFeatureInfo {
        GeneratedAppFeatureInfo(context.current.appFeatureInfo(topic: arguments.topic))
    }
}

// MARK: - Error classification

/// RUNTIME RELIABILITY PHASE — maps a `LanguageModelSession.GenerationError` (the ONLY error type
/// `session.respond(to:)` documents throwing, per the installed FoundationModels SDK's own
/// `swiftinterface` — inspected directly, not assumed) onto the plain, FoundationModels-agnostic
/// `AskSpendSmartError` the rest of this feature already understands. Lives here (not in
/// `AskSpendSmartService.swift`) specifically so that file keeps its zero-`FoundationModels`-import
/// guarantee.
@available(iOS 26.0, *)
extension AskSpendSmartError {
    static func map(_ error: LanguageModelSession.GenerationError) -> AskSpendSmartError {
        switch error {
        case .exceededContextWindowSize(_):
            return .contextSizeExceeded
        case .guardrailViolation(_), .refusal(_, _):
            return .guardrailViolation
        case .unsupportedLanguageOrLocale(_):
            return .unsupportedLanguage
        case .rateLimited(_), .concurrentRequests(_):
            return .modelBusy
        case .assetsUnavailable(_), .unsupportedGuide(_), .decodingFailure(_):
            return .localDataAccessFailure
        @unknown default:
            return .other(String(describing: error))
        }
    }
}

// MARK: - GENERALIZED ORCHESTRATOR PHASE — Apple on-device model as the typed planner/wording layer
//
// Replaces "the model voluntarily decides whether/which of 15 tools to call" with two narrow,
// separately-purposed guided-generation calls: (1) classify the question into a validated
// `SpendAIQueryPlan` (or `nil` for non-factual chat), (2) once `SpendAIDataRegistry` has executed
// that plan deterministically, turn the VERIFIED result into natural wording. Neither call
// registers/uses a `FoundationModels.Tool` — guided generation (`respond(to:generating:)`) is a
// SEPARATE API from tool-calling and does not invoke `Tool.call(arguments:)` at all, which is what
// actually eliminates the "`@concurrent` tool call touching a live SwiftData array" risk this
// phase's own audit flagged, rather than merely relying on `AskSpendSmartToolContextBox`'s lock.

@available(iOS 26.0, *)
@Generable
enum GeneratedSpendAIDomain: String, Sendable {
    case budgetExclusions, budgetSettings, weekly, monthlyPlan, transactions, connectedAccounts
    case manualAccounts, bills, savings, quickStats, categories, autoCalculate, calculateTransactions
    case appFeatureInformation, hypotheticalScenario
    /// Not a real domain — the model's own explicit "this isn't about the user's data" signal.
    case none
}

@available(iOS 26.0, *)
@Generable
enum GeneratedSpendAIOperation: String, Sendable {
    case count, total, both, list, search, summary, status, compare, explanation, hypothetical
}

@available(iOS 26.0, *)
@Generable
struct GeneratedQueryPlan {
    @Guide(description: "true if this question asks about the user's own real SpendSmart data — transactions, balances, registers, budget, Budget Exclusions, settings, bills, savings, categories, Quick Stats, Auto Calculate, or a hypothetical scenario. false ONLY for greetings, small talk, or anything unrelated to the user's own app data.")
    var isFactualSpendSmartQuestion: Bool
    @Guide(description: "The single most relevant domain. Meaningless when isFactualSpendSmartQuestion is false — use .none in that case.")
    var domain: GeneratedSpendAIDomain
    var operation: GeneratedSpendAIOperation
    @Guide(description: "Start of the date range, as YYYY-MM-DD, resolved from today's date given in your instructions (e.g. \"the past two weeks\" → 14 days ending today). Omit entirely for an all-time question.")
    var startDate: String?
    @Guide(description: "End of the date range, as YYYY-MM-DD, inclusive. Omit entirely for an all-time question.")
    var endDate: String?
    @Guide(description: "Account or institution name mentioned, e.g. \"Chase\", \"American Express\", \"Checking\". Omit if none.")
    var accountName: String?
    @Guide(description: "Merchant/description text mentioned, e.g. \"Amazon\". Omit if none.")
    var merchant: String?
    @Guide(description: "Category name mentioned, e.g. \"Groceries\". Omit if none.")
    var category: String?
    @Guide(description: "An exact dollar amount the user mentioned for a transaction search, e.g. 34.75. Omit if none.")
    var exactAmount: Double?
    @Guide(description: "The hypothetical dollar amount for a .hypotheticalScenario question, e.g. 1000 for \"if I save $1,000\". Omit for every other domain.")
    var hypotheticalAmount: Double?
    @Guide(description: "The feature/topic name for an .appFeatureInformation question, e.g. \"Budget Exclusions\", \"Auto Calculate\". Omit for every other domain.")
    var featureTopic: String?
}

@available(iOS 26.0, *)
extension GeneratedQueryPlan {
    /// `nil` when the model marked this as non-factual, OR named an unrecognized/`.none` domain —
    /// both are treated identically by the orchestrator: safe to answer directly, ungrounded.
    func toPlan(now: Date, calendar: Calendar = .current) -> SpendAIQueryPlan? {
        guard isFactualSpendSmartQuestion, domain != .none, let mappedDomain = SpendAIDomain(rawValue: domain.rawValue) else {
            return nil
        }
        let mappedOperation = SpendAIOperation(rawValue: operation.rawValue) ?? .summary
        let start = AskSpendSmartDateParsing.parse(startDate)
        let end = AskSpendSmartDateParsing.parse(endDate)
        let dateRange: DateInterval?
        let label: String
        if let start, let end {
            dateRange = DateInterval(
                start: DateRangeHelper.dayRangeContaining(start, calendar: calendar).start,
                end: DateRangeHelper.dayRangeContaining(end, calendar: calendar).end
            )
            label = "that range"
        } else {
            dateRange = nil
            label = "all time"
        }
        return SpendAIQueryPlan(
            domain: mappedDomain,
            operation: mappedOperation,
            dateRange: dateRange,
            dateRangeLabel: label,
            accountFilter: accountName,
            merchantFilter: merchant,
            categoryFilter: category,
            exactAmount: AskSpendSmartAmountParsing.parse(exactAmount),
            hypotheticalAmount: AskSpendSmartAmountParsing.parse(hypotheticalAmount),
            featureTopic: featureTopic
        )
    }
}

/// Production `SpendAIQueryPlanning` conformer — the ONLY place a `SpendAIQueryPlan` is produced
/// from an on-device model call. Registers no tools; a plain guided-generation call.
@available(iOS 26.0, *)
struct AppleFoundationModelQueryPlanner: SpendAIQueryPlanning {
    let session: LanguageModelSession

    func makePlan(for question: String, now: Date, followUp: SpendAIFollowUpContext?) async throws -> SpendAIQueryPlan? {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        let followUpHint = followUp.map {
            "The user's PREVIOUS question was about the \($0.domain.rawValue) domain" +
            ($0.dateRangeLabel == "all time" ? "" : ", for \($0.dateRangeLabel)") +
            ". If this new question is a short follow-up (e.g. \"what was the total?\", \"how much are they?\"), keep that SAME domain/date range unless the new wording clearly changes them."
        } ?? ""
        let prompt = """
            Today's date is \(dateFormatter.string(from: now)). \(followUpHint)

            Classify this question about the SpendSmart budgeting app and produce a structured \
            query plan: "\(question)"
            """
        let response = try await session.respond(to: prompt, generating: GeneratedQueryPlan.self)
        return response.content.toPlan(now: now)
    }
}

/// Production `SpendAIWordingGenerating` conformer. Receives ONLY the already-verified, already
/// app-formatted result sentence — never raw transactions/accounts — per Phase I's own "do not
/// send the complete database" requirement.
@available(iOS 26.0, *)
struct AppleFoundationModelWordingService: SpendAIWordingGenerating {
    let session: LanguageModelSession

    func word(question: String, result: SpendAIQueryResult) async throws -> String {
        let verified = SpendAIResultFormatter.format(result)
        let prompt = """
            The user asked: "\(question)"
            The verified SpendSmart result is: \(verified)

            Rephrase this naturally and conversationally for the user. Do NOT change, add to, or \
            invent any number, date, account, or fact beyond exactly what is stated above.
            """
        let response = try await session.respond(to: prompt)
        return response.content
    }

    func plainReply(to question: String) async throws -> String {
        let response = try await session.respond(to: question)
        return response.content
    }
}

// MARK: - System (on-device) service

/// The on-device Apple Foundation Models-backed `AskSpendSmartServicing` conformer — the only
/// place in this feature that imports/touches `LanguageModelSession` directly. Holds ONE session
/// for the lifetime of one Ask SpendSmart presentation so multi-turn context (what the user asked
/// earlier in the same conversation) is retained by the framework itself — see
/// `LanguageModelSession`'s own documented "reuse the same session" multi-turn guidance — rather
/// than this type re-sending prior messages itself.
///
/// USER-FACING BRANDING CORRECTION — the assistant's own self-identification below now says
/// "SpendAI" (the active user-facing brand), matching the visible launcher label/screen title
/// everywhere else in the app. Internal Swift type names (`AskSpendSmartService`,
/// `AskSpendSmartToolContext`, this class, etc.) deliberately stay unchanged — renaming them would
/// carry real regression risk for zero user-visible benefit, since a user never sees a Swift type
/// name.
@available(iOS 26.0, *)
final class SystemAskSpendSmartService: AskSpendSmartServicing {
    private static let baseInstructions = """
        You are SpendAI, a friendly financial assistant built into the SpendSmart budgeting app. \
        Answer the user's questions about their own real income, bills, spending, accounts, \
        budget, Budget Exclusions, Manual Account registers, savings, and Fixed Bills using ONLY \
        the provided tools — never estimate, guess, or invent a dollar amount, account, \
        transaction, exclusion, bill, or setting yourself. Every tool result already reflects the \
        app's own authoritative calculations (including the user's own settings for pending \
        transactions, excluded transactions, and auto-tracked connected accounts), so simply read \
        and explain those results conversationally — do not recompute or second-guess the numbers \
        a tool returns.

        USE THE MOST SPECIFIC TOOL FOR THE DOMAIN — never substitute a broader tool for a specific \
        question just because it happens to be available:
        - Any question containing "exclude"/"excluded"/"exclusion"/"Budget Exclusions" → \
          getBudgetExclusions. This is a real, previously-reported failure mode: NEVER answer a \
          Budget Exclusions question using getFinancialSummary or by talking about Monthly Plan — \
          Budget Exclusions and Monthly Plan are completely different domains. If the question \
          mentions a time period ("the past two weeks," "last 14 days," "this month"), ALWAYS pass \
          startDate/endDate to getBudgetExclusions so the count/total it returns is already \
          correctly filtered to that period — never try to filter or re-add the all-time list \
          yourself.
        - Pending-transaction preference, warning threshold, Auto Calculate account selection → \
          getBudgetSettings.
        - "This week" / weekly budget/spending/remaining → getWeeklyStatus.
        - Income, fixed bills total, savings goal, flexible spending, "this month" → \
          getFinancialSummary (Monthly Plan).
        - A specific Manual Account/register's balance, deposits, expenses, transfers, or \
          transaction count → getManualRegister.
        - Which bills are paid/unpaid this month → getBillsStatus.
        - How much has been saved / the savings goal → getSavingsStatus.
        - "What does X do" / "what is X" about a FEATURE NAME (not the user's own data) → \
          getAppFeatureInfo.
        - A specific transaction/merchant/date/amount lookup → searchTransactions (see below).

        NEVER GUESS OR HALLUCINATE: if no tool covers what's being asked, or a tool returns no \
        value for it, say plainly "I can't find that information in SpendSmart" — do not answer \
        with an unrelated domain's explanation, do not fabricate a number, and do not infer a \
        setting or value from a different one.

        searchTransactions is a factual, complete ledger lookup — it deliberately includes \
        transactions excluded from budget totals, since the user is asking "did this transaction \
        happen," not "does it count toward my budget." If a question requires several pieces of \
        information, call multiple tools rather than guessing at any of them. If searchTransactions \
        returns zero transactions, tell the user none were found — never claim one exists that \
        wasn't returned, and never claim one doesn't exist without having actually called the tool. \
        If a follow-up question refers back to a previous answer (e.g. "what is the total amount?" \
        right after asking about Budget Exclusions, or "which one was on Amex?"), use the \
        conversation you already have to know which domain/tool that follow-up still refers to — \
        call the same tool again with narrower criteria if that helps confirm the answer, rather \
        than switching to an unrelated domain.

        Keep answers concise and plain-English, using dollar amounts formatted like $1,234.56. You \
        are advisory only: you cannot and must not change any budget, goal, transaction, account, \
        exclusion, bill, or setting — if asked to make a real change, explain what the effect would \
        be using a hypothetical tool if one applies, and clearly state that you cannot make the \
        change yourself.
        """

    /// `var`, not `let` — `recreateSession(...)` reassigns this after an unrecoverable
    /// context-size error (Part 11); `LanguageModelSession` itself exposes no "clear the
    /// transcript" API, so a fresh instance is the only supported way to reset it.
    private var session: LanguageModelSession
    /// The exact tool list `session` was built with — kept so `recreateSession(...)` can rebuild an
    /// identical session (`LanguageModelSession` does not expose its own `tools` back out).
    private let tools: [any FoundationModels.Tool]
    /// The exact instructions string `session` was built with — same reuse rationale as `tools`.
    private let instructions: String
    /// FRESH SNAPSHOT PHASE — every registered tool reads through this box rather than holding a
    /// fixed `AskSpendSmartToolContext` captured once at session creation. `updateToolContext(_:)`
    /// swaps its contents immediately before every `send`, so a long-lived session (kept for
    /// multi-turn conversational memory) still answers each new question against CURRENT local
    /// SwiftData/Plaid-cache data — never a stale snapshot from when the conversation started.
    private let contextBox: AskSpendSmartToolContextBox

    /// PHASE 2 — `screenContext` only ever appends ONE extra descriptive sentence to the model's
    /// instructions (see `AskSpendSmartScreenContext.contextHint`'s own header) — the tool list
    /// passed to `LanguageModelSession` below is IDENTICAL regardless of context, so a
    /// Weekly-opened conversation can still answer a Monthly Plan or merchant question exactly
    /// like a Dashboard-opened one. Screen context is a hint about WHERE the conversation started,
    /// never a restriction on WHAT it can be asked, and never itself a financial figure.
    ///
    /// TRANSACTION SEARCH RELIABILITY FIX — also grounds "today's date" (from
    /// `toolContext.currentDateForModelGrounding`) so the model can reliably resolve relative date
    /// phrases ("yesterday", "this week", "last month") into the explicit `YYYY-MM-DD` tool
    /// arguments the deterministic layer requires — never left for the model to guess "now" on its
    /// own, and never a case where the model itself computes a financial value.
    /// GENERALIZED ORCHESTRATOR PHASE — the last unanswered question's domain/date range, for
    /// resolving a short follow-up ("what was the total?") without Scott re-stating them (Phase L).
    /// Deliberately just this one small struct, never a growing raw transcript copy.
    private var followUpContext: SpendAIFollowUpContext?

    /// MODEL-FACING TOOL CONSOLIDATION (Phase O) — the live session registers ZERO
    /// `FoundationModels.Tool`s. The 15 `GetXTool`/`SearchTransactionsTool`/etc. structs above
    /// remain in this file, fully defined and gated, as PROVEN internal adapters — each one's
    /// `call(arguments:)` body is exactly what `SpendAIDataRegistry.execute(_:using:)` now calls
    /// directly (via the same underlying `AskSpendSmartToolContext` methods) — but none of them is
    /// ever registered for the model to voluntarily choose between. This is what actually reduces
    /// routing ambiguity to zero for factual questions: the model no longer picks from competing
    /// tools at all, it only ever classifies into ONE typed plan (`GeneratedQueryPlan`, via guided
    /// generation, itself not a `Tool` call) which `SpendAIDataRegistry` alone executes.
    init(toolContext: AskSpendSmartToolContext, screenContext: AskSpendSmartScreenContext) {
        let contextBox = AskSpendSmartToolContextBox(toolContext)
        let instructions = Self.baseInstructions
            + "\n\nToday's date is \(toolContext.currentDateForModelGrounding)."
            + "\n\n" + screenContext.contextHint
        self.contextBox = contextBox
        self.tools = []
        self.instructions = instructions
        self.session = LanguageModelSession(tools: [], instructions: instructions)
    }

    /// FRESH SNAPSHOT PHASE — see `contextBox`'s own header. Called by
    /// `AskSpendSmartConversationModel.send` immediately before every `send(_:)` below.
    func updateToolContext(_ context: AskSpendSmartToolContext) {
        contextBox.update(context)
    }

    /// GENERALIZED ORCHESTRATOR PHASE — every message goes through
    /// `SpendAIQueryOrchestrator.handle(...)`: the local router tries first, then Apple's model
    /// produces a typed plan, `SpendAIDataRegistry` executes it deterministically, and Apple's
    /// model (or the deterministic formatter, on wording failure) produces the final sentence.
    /// There is no remaining path where a factual question reaches an ungrounded
    /// `session.respond(originalQuestion)` (Phase H).
    ///
    /// ERROR CLASSIFICATION — a `LanguageModelSession.GenerationError` from EITHER the planning or
    /// wording call is mapped to a distinct `AskSpendSmartError` (Part 13). `exceededContextWindowSize`
    /// gets ONE automatic recovery attempt: a fresh session, same instructions, no prior transcript,
    /// retries the SAME question once before giving up (Part 11).
    func send(_ userMessage: String) async throws -> String {
        do {
            return try await runOrchestrator(userMessage)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .contextSizeExceeded = AskSpendSmartError.map(error) else {
                throw AskSpendSmartError.map(error)
            }
            recreateSession()
            do {
                return try await runOrchestrator(userMessage)
            } catch {
                throw AskSpendSmartError.contextSizeExceeded
            }
        } catch let error as AskSpendSmartError {
            throw error
        } catch {
            throw AskSpendSmartError.other(String(describing: error))
        }
    }

    private func runOrchestrator(_ userMessage: String) async throws -> String {
        let outcome = try await SpendAIQueryOrchestrator.handle(
            question: userMessage,
            context: contextBox.current,
            now: Date(),
            followUp: followUpContext,
            planner: AppleFoundationModelQueryPlanner(session: session),
            wording: AppleFoundationModelWordingService(session: session)
        )
        followUpContext = outcome.followUp
        return outcome.answer
    }

    /// Rebuilds the session from scratch — same (empty) tools/instructions, but a brand-new, empty
    /// transcript — so a context-size failure gets one clean retry rather than staying permanently
    /// stuck (Part 11). `LanguageModelSession` exposes no API to trim/reset an existing transcript,
    /// so a fresh instance (this is why `session` is `var`, not `let`) is the supported way.
    private func recreateSession() {
        session = LanguageModelSession(tools: tools, instructions: instructions)
    }

    @MainActor
    static func currentAvailability() -> AskSpendSmartAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailableDeviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailableAppleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .unavailableModelNotReady
        case .unavailable(let other):
            return .unavailableOther(String(describing: other))
        }
    }
}
