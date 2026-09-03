import Foundation

/// PHASE F — the ONE authoritative execution path for a validated `SpendAIQueryPlan`. Every
/// domain maps to an EXISTING `AskSpendSmartToolContext` method — the same deterministic layer the
/// original 15 model-facing tools already called — never a duplicated formula, never a second
/// calculation path. This is deliberately a thin dispatch table: `AskSpendSmartToolContext` still
/// owns 100% of the actual math (which itself calls straight into `BudgetCalculator`/
/// `MonthlyPlanCalculator`, as it always has).
///
/// CONCURRENCY NOTE (Phase B's own "do not treat NSLock as proof live SwiftData objects can safely
/// cross concurrency boundaries" caution, addressed directly): this function is a plain,
/// synchronous, non-`@concurrent` call — it is never registered as a `FoundationModels.Tool` and
/// is therefore never invoked by the framework's own concurrent tool-dispatch machinery. It is
/// only ever called from `SpendAIQueryOrchestrator.handle(...)`, itself only ever called from
/// `SystemAskSpendSmartService.send(_:)`, which runs on the SAME actor as the `@MainActor`
/// `AskSpendSmartConversationModel.send` that kicked it off — the live `[FinanceTransaction]`/
/// `[Account]` arrays `AskSpendSmartToolContext` wraps are read exactly once, synchronously, on
/// that single actor, then this function returns a plain, fully Sendable `SpendAIQueryResult` —
/// nothing containing a `@Model` reference or `ModelContext` ever crosses an actor boundary.
enum SpendAIDataRegistry {
    static func execute(_ plan: SpendAIQueryPlan, using context: AskSpendSmartToolContext) -> SpendAIQueryResult {
        switch plan.domain {
        case .budgetExclusions:
            return .budgetExclusions(context.budgetExclusions(dateRange: plan.dateRange), dateRangeLabel: plan.dateRangeLabel)

        case .budgetSettings, .autoCalculate:
            return .budgetSettings(context.budgetSettingsStatus())

        case .weekly:
            return .weeklyStatus(context.weeklyStatus())

        case .monthlyPlan, .quickStats:
            return .monthlyPlanStatus(context.financialSummary())

        case .transactions:
            let (startDate, endDate) = searchBounds(for: plan.dateRange)
            let result = context.searchTransactions(
                startDate: startDate,
                endDate: endDate,
                exactAmount: plan.exactAmount,
                accountName: plan.accountFilter,
                merchant: plan.merchantFilter,
                category: plan.categoryFilter,
                pendingFilter: contextPendingFilter(plan.pendingFilter),
                resultLimit: plan.resultLimit
            )
            return .transactionList(result)

        case .connectedAccounts:
            return .accountBalances(filteredAccounts(context.accountBalances(), isManual: false, nameFilter: plan.accountFilter))

        case .manualAccounts:
            if plan.operation == .status || plan.operation == .summary {
                return .manualRegisters(context.manualRegisterStatus(accountNameFilter: plan.accountFilter))
            }
            return .accountBalances(filteredAccounts(context.accountBalances(), isManual: true, nameFilter: plan.accountFilter))

        case .bills:
            return .billsStatus(context.billsStatus())

        case .savings:
            return .savingsStatus(context.savingsStatus())

        case .categories:
            let (start, end) = plan.dateRange.map { ($0.start, $0.end) } ?? (.distantPast, .distantFuture)
            return .categoryTotals(context.categorySpending(startDate: start, endDate: end), dateRangeLabel: plan.dateRangeLabel)

        case .calculateTransactions:
            return .calculateTransactionsExplanation(Self.calculateTransactionsExplanation)

        case .appFeatureInformation:
            let info = context.appFeatureInfo(topic: plan.featureTopic ?? "")
            guard info.found, let name = info.featureName, let description = info.description else {
                return .unsupported("That information is not available to SpendAI yet.")
            }
            return .featureExplanation(name: name, description: description)

        case .hypotheticalScenario:
            // HONEST SCOPE NOTE: this phase wires up the required "change my monthly savings
            // goal" scenario (the one in this phase's own required end-to-end test list). The
            // pre-existing `runHypotheticalWeeklySpendingLimit` tool/method remains available and
            // unaffected for a weekly-limit hypothetical — it is just not yet reachable through
            // this generalized plan/registry path, since the plan schema doesn't yet distinguish
            // WHICH hypothetical a user meant. Flagged here rather than silently narrowed.
            guard let amount = plan.hypotheticalAmount else {
                return .unsupported("I need a dollar amount to run that scenario.")
            }
            return .hypotheticalSavingsGoal(context.hypotheticalSavingsGoal(amount))
        }
    }

    /// Converts a half-open `[start, end)` plan date range into the inclusive start/end `Date?`
    /// pair `searchTransactions` already expects (that method re-normalizes both through
    /// `DateRangeHelper.dayRangeContaining` itself) — subtracting one second from the exclusive
    /// upper bound keeps it inside the intended final calendar day.
    private static func searchBounds(for dateRange: DateInterval?) -> (Date?, Date?) {
        guard let dateRange else { return (nil, nil) }
        return (dateRange.start, dateRange.end.addingTimeInterval(-1))
    }

    private static func contextPendingFilter(_ spec: SpendAIQueryPlan.PendingFilterSpec) -> AskSpendSmartToolContext.PendingFilter {
        switch spec {
        case .all: return .all
        case .pendingOnly: return .pendingOnly
        case .postedOnly: return .postedOnly
        }
    }

    private static func filteredAccounts(_ all: [AskSpendSmartToolContext.AccountBalanceResult], isManual: Bool, nameFilter: String?) -> [AskSpendSmartToolContext.AccountBalanceResult] {
        let scoped = all.filter { $0.isManual == isManual }
        guard let nameFilter, !nameFilter.isEmpty else { return scoped }
        let named = scoped.filter { $0.name.localizedCaseInsensitiveContains(nameFilter) }
        return named.isEmpty ? scoped : named
    }

    private static let calculateTransactionsExplanation = """
        Calculate Transactions (Settings ▸ Tools) lets you pick an account, check off individual \
        transactions, and see a running subtotal for that account plus one combined grand total \
        across every selected transaction from every account. An "Excluded Transactions" toggle \
        can switch it to show only your Budget Excluded transactions across every account instead. \
        It's read-only — it never changes a transaction, balance, or budget. Selections only exist \
        while the screen is open, so I can't see what's currently checked after you close it.
        """
}
