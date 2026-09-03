import Foundation

/// PHASE J — a deterministic, app-generated sentence for EVERY `SpendAIQueryResult` case, used
/// two ways: (1) as the immediate answer for whatever wasn't sent through Apple's wording step
/// at all, and (2) as the required fallback when Apple's final-wording call fails AFTER the
/// registry already produced a verified result — the result itself is never discarded (Part 5's
/// own "STEP 4" requirement). Deliberately plain Foundation — same testability rationale as
/// `SpendAIQueryPlan.swift`.
enum SpendAIResultFormatter {
    static func format(_ result: SpendAIQueryResult) -> String {
        switch result {
        case .budgetExclusions(let exclusions, let dateRangeLabel):
            return formatBudgetExclusions(exclusions, dateRangeLabel: dateRangeLabel)
        case .budgetSettings(let settings):
            return formatBudgetSettings(settings)
        case .weeklyStatus(let weekly):
            return formatWeeklyStatus(weekly)
        case .monthlyPlanStatus(let summary):
            return formatMonthlyPlanStatus(summary)
        case .transactionList(let search):
            return formatTransactionList(search)
        case .accountBalances(let balances):
            return formatAccountBalances(balances)
        case .manualRegisters(let registers):
            return formatManualRegisters(registers)
        case .billsStatus(let bills):
            return formatBillsStatus(bills)
        case .savingsStatus(let savings):
            return formatSavingsStatus(savings)
        case .categoryTotals(let totals, let dateRangeLabel):
            return formatCategoryTotals(totals, dateRangeLabel: dateRangeLabel)
        case .periodComparison(let comparison):
            return formatPeriodComparison(comparison)
        case .featureExplanation(let name, let description):
            return "\(name): \(description)"
        case .hypotheticalSavingsGoal(let hypothetical):
            return formatHypotheticalSavingsGoal(hypothetical)
        case .calculateTransactionsExplanation(let text):
            return text
        case .noMatches(let message):
            return message
        case .unsupported(let message):
            return message
        }
    }

    // MARK: - Budget Exclusions (reuses the exact wording already proven in AskSpendSmartFallbackRouter)

    private static func formatBudgetExclusions(_ result: AskSpendSmartToolContext.BudgetExclusionsResult, dateRangeLabel: String) -> String {
        AskSpendSmartFallbackRouter.formatBudgetExclusionsAnswer(result: result, operation: .both, dateRangeLabel: dateRangeLabel)
    }

    // MARK: - Budget Settings

    private static func formatBudgetSettings(_ settings: AskSpendSmartToolContext.BudgetSettingsResult) -> String {
        let pending = settings.includePendingTransactions ? "included" : "not included"
        let exclusions = settings.excludeTransactionsEnabled ? "on (\(settings.excludedTransactionsCount) transaction\(settings.excludedTransactionsCount == 1 ? "" : "s") excluded)" : "off"
        let autoCalc = settings.autoCalculateAccountNames.isEmpty ? "no connected accounts" : settings.autoCalculateAccountNames.joined(separator: ", ")
        return "Pending transactions are \(pending) in your budget totals. Budget Exclusions is \(exclusions). Your warning threshold is \(settings.warningThresholdPercent)%. Auto Calculate is using: \(autoCalc)."
    }

    // MARK: - Weekly

    private static func formatWeeklyStatus(_ weekly: AskSpendSmartToolContext.WeeklyStatusResult) -> String {
        let overOrUnder = weekly.isOverBudget ? "You are over budget by \(money(weekly.overBudgetAmount))." : "You have \(money(weekly.remaining)) remaining."
        return "You have spent \(money(weekly.actualSpentThisWeek)) this week out of a \(money(weekly.weeklyLimit)) limit. \(overOrUnder)"
    }

    // MARK: - Monthly Plan

    private static func formatMonthlyPlanStatus(_ summary: AskSpendSmartToolContext.FinancialSummaryResult) -> String {
        "This month: \(money(summary.monthlyIncome)) income, \(money(summary.fixedBillsTotal)) in fixed bills, and a \(money(summary.monthlySavingsGoal)) savings goal, leaving \(money(summary.flexibleSpendingAvailable)) flexible spending available. You've spent \(money(summary.monthlyActualSpending)) so far, with \(money(summary.monthlyRemaining)) remaining."
    }

    // MARK: - Transactions

    private static func formatTransactionList(_ search: AskSpendSmartToolContext.TransactionSearchResult) -> String {
        guard !search.transactions.isEmpty else {
            return "I found no matching transactions."
        }
        let lines = search.transactions.prefix(5).map { "\($0.description) — \(money($0.amount)) on \($0.date)" }.joined(separator: "; ")
        let more = search.truncated ? " (showing \(search.resultsReturned) of \(search.totalMatchCount))" : ""
        return "I found \(search.totalMatchCount) matching transaction\(search.totalMatchCount == 1 ? "" : "s"): \(lines)\(more)."
    }

    // MARK: - Account balances (connected + manual)

    private static func formatAccountBalances(_ balances: [AskSpendSmartToolContext.AccountBalanceResult]) -> String {
        guard !balances.isEmpty else {
            return "I couldn't find that account."
        }
        if balances.count == 1, let only = balances.first {
            return "Your \(only.name) balance is \(money(only.currentBalance))."
        }
        let lines = balances.map { "\($0.name): \(money($0.currentBalance))" }.joined(separator: "; ")
        return "Here are your account balances: \(lines)."
    }

    // MARK: - Manual registers

    private static func formatManualRegisters(_ registers: [AskSpendSmartToolContext.ManualRegisterResult]) -> String {
        guard !registers.isEmpty else {
            return "I couldn't find that Manual Account."
        }
        if registers.count == 1, let only = registers.first {
            return "Your \(only.accountName) balance is \(money(only.currentBalance)), across \(only.transactionCount) transaction\(only.transactionCount == 1 ? "" : "s")."
        }
        let lines = registers.map { "\($0.accountName): \(money($0.currentBalance))" }.joined(separator: "; ")
        return "Here are your Manual Account balances: \(lines)."
    }

    // MARK: - Bills

    private static func formatBillsStatus(_ bills: AskSpendSmartToolContext.BillsStatusResult) -> String {
        guard bills.unpaidCount > 0 else {
            return "All of your bills are paid this month."
        }
        return "You have \(bills.unpaidCount) unpaid bill\(bills.unpaidCount == 1 ? "" : "s") remaining this month, totaling \(money(bills.unpaidTotal))."
    }

    // MARK: - Savings

    private static func formatSavingsStatus(_ savings: AskSpendSmartToolContext.SavingsStatusResult) -> String {
        "You've saved \(money(savings.savedThisMonthManualEntries)) this month manually, plus \(money(savings.savedViaTransferThisMonth)) via transfer, toward a \(money(savings.monthlySavingsGoal)) goal."
    }

    // MARK: - Categories

    private static func formatCategoryTotals(_ totals: [AskSpendSmartToolContext.CategoryTotalResult], dateRangeLabel: String) -> String {
        guard !totals.isEmpty else {
            return "I found no category spending for \(dateRangeLabel)."
        }
        let rangePhrase = dateRangeLabel == "all time" ? "" : " for \(dateRangeLabel)"
        let lines = totals.prefix(5).map { "\($0.categoryName): \(money($0.total))" }.joined(separator: "; ")
        return "Category spending\(rangePhrase): \(lines)."
    }

    // MARK: - Period comparison

    private static func formatPeriodComparison(_ comparison: AskSpendSmartToolContext.PeriodComparisonResult) -> String {
        "Period A: \(money(comparison.periodASpent)), Period B: \(money(comparison.periodBSpent)), a difference of \(money(comparison.difference))."
    }

    // MARK: - Hypothetical

    private static func formatHypotheticalSavingsGoal(_ hypothetical: AskSpendSmartToolContext.HypotheticalSavingsGoalResult) -> String {
        "If your monthly savings goal were \(money(hypothetical.hypotheticalSavingsGoal)), you'd have \(money(hypothetical.hypotheticalFlexibleSpendingAvailable)) flexible spending available, with a recommended weekly spending limit of \(money(hypothetical.hypotheticalRecommendedWeeklySpending))."
    }

    // MARK: - Money

    /// `amountString` is already an `AskSpendSmartMoneyFormat`-style plain decimal string
    /// ("482.19" or "-482.19") — this renders it the same way `CurrencyFormat` does everywhere
    /// else in the app, never a second money-formatting convention.
    private static func money(_ amountString: String) -> String {
        guard let decimal = Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) else { return amountString }
        return CurrencyFormat.string(from: decimal)
    }
}
