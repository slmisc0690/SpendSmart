import Foundation

/// GENERALIZED ORCHESTRATOR PHASE — the typed, validated shape EVERY factual SpendSmart-data
/// question is normalized into before any data lookup happens, whether it was produced by the
/// local deterministic router (`AskSpendSmartFallbackRouter`) or by Apple's on-device model
/// (`AppleFoundationModelQueryPlanner`, in `AskSpendSmartToolProvider.swift`). Deliberately plain
/// Foundation — no `FoundationModels` dependency — so it's directly unit-testable on every
/// deployment target this app supports, exactly like `AskSpendSmartToolContext` itself. The
/// `@Generable` mirror the model actually produces (`GeneratedQueryPlan`) lives in the
/// `@available(iOS 26.0, *)`-gated file and converts INTO this type — this type itself never
/// changes based on what SDK is installed.
enum SpendAIDomain: String, Sendable, Equatable, CaseIterable {
    case budgetExclusions
    case budgetSettings
    case weekly
    case monthlyPlan
    case transactions
    case connectedAccounts
    case manualAccounts
    case bills
    case savings
    case quickStats
    case categories
    case autoCalculate
    case calculateTransactions
    case appFeatureInformation
    case hypotheticalScenario
}

enum SpendAIOperation: String, Sendable, Equatable, CaseIterable {
    case count
    case total
    case both
    case list
    case search
    case summary
    case status
    case compare
    case explanation
    case hypothetical
}

/// A validated, structured request for exactly ONE deterministic data lookup. Never executed
/// directly by the model — only `SpendAIDataRegistry.execute(_:using:)` is allowed to turn a plan
/// into a real result (Phase F's own "the registry must be the only authoritative execution path"
/// requirement).
struct SpendAIQueryPlan: Sendable, Equatable {
    enum PendingFilterSpec: Sendable, Equatable {
        case all
        case pendingOnly
        case postedOnly
    }

    let domain: SpendAIDomain
    var operation: SpendAIOperation
    /// `nil` means "all time" — no date restriction. Half-open `[start, end)`, always resolved in
    /// the LOCAL calendar (see `AskSpendSmartFallbackRouter`'s own header on why UTC boundaries are
    /// never used here).
    var dateRange: DateInterval?
    /// A short, human-readable label for `dateRange` ("the past 14 days", "this month", "all
    /// time") — used by both the deterministic formatter and as grounding text for the model's
    /// final wording call, so the stated range in the sentence always matches what was ACTUALLY
    /// queried.
    var dateRangeLabel: String
    var accountFilter: String?
    var merchantFilter: String?
    var categoryFilter: String?
    var exactAmount: Decimal?
    var pendingFilter: PendingFilterSpec = .all
    var resultLimit: Int = 50
    /// Only meaningful for `.hypotheticalScenario` — the hypothetical dollar amount being tested
    /// (a new monthly savings goal, in the one scenario this phase's registry wires up; see that
    /// domain's own case in `SpendAIDataRegistry` for the documented, honest scope limit).
    var hypotheticalAmount: Decimal?
    /// Only meaningful for `.appFeatureInformation` — the feature/topic name being asked about.
    var featureTopic: String?

    init(
        domain: SpendAIDomain,
        operation: SpendAIOperation,
        dateRange: DateInterval? = nil,
        dateRangeLabel: String = "all time",
        accountFilter: String? = nil,
        merchantFilter: String? = nil,
        categoryFilter: String? = nil,
        exactAmount: Decimal? = nil,
        pendingFilter: PendingFilterSpec = .all,
        resultLimit: Int = 50,
        hypotheticalAmount: Decimal? = nil,
        featureTopic: String? = nil
    ) {
        self.domain = domain
        self.operation = operation
        self.dateRange = dateRange
        self.dateRangeLabel = dateRangeLabel
        self.accountFilter = accountFilter
        self.merchantFilter = merchantFilter
        self.categoryFilter = categoryFilter
        self.exactAmount = exactAmount
        self.pendingFilter = pendingFilter
        self.resultLimit = resultLimit
        self.hypotheticalAmount = hypotheticalAmount
        self.featureTopic = featureTopic
    }
}

/// PHASE C's own "validate every plan before executing it — an invalid or unsupported plan must
/// not reach a data adapter" requirement. Deliberately narrow: only checks the fields a domain
/// STRUCTURALLY cannot proceed without (a hypothetical with no amount, a feature lookup with no
/// topic) — anything else (a missing date range, an empty merchant filter) is a valid "no filter"
/// request, not an invalid plan.
enum SpendAIQueryPlanValidator {
    static func validate(_ plan: SpendAIQueryPlan) -> Bool {
        switch plan.domain {
        case .hypotheticalScenario:
            return plan.hypotheticalAmount != nil
        case .appFeatureInformation:
            return plan.featureTopic?.isEmpty == false
        default:
            return true
        }
    }
}

/// PHASE L — the minimal structured state carried from one answered question to the next so a
/// follow-up like "what was the total?" or "how much are they?" can be resolved without Scott
/// re-stating the domain/date range. Deliberately NOT a growing raw transcript — just the last
/// plan's domain + date range, discarded/replaced after every turn.
struct SpendAIFollowUpContext: Sendable, Equatable {
    let domain: SpendAIDomain
    let dateRange: DateInterval?
    let dateRangeLabel: String
}

/// PHASE G — typed result cases sufficient for deterministic formatting, one per supported
/// registry domain/shape. Every payload REUSES an existing, already-tested, already-Sendable
/// result struct from `AskSpendSmartToolContext` (never a duplicate/parallel definition) — this is
/// what "map each domain to existing canonical logic" (Phase F) looks like at the type level: the
/// registry's job is choosing/calling the right existing method, never re-deriving its math.
enum SpendAIQueryResult: Sendable, Equatable {
    case budgetExclusions(AskSpendSmartToolContext.BudgetExclusionsResult, dateRangeLabel: String)
    case budgetSettings(AskSpendSmartToolContext.BudgetSettingsResult)
    case weeklyStatus(AskSpendSmartToolContext.WeeklyStatusResult)
    case monthlyPlanStatus(AskSpendSmartToolContext.FinancialSummaryResult)
    case transactionList(AskSpendSmartToolContext.TransactionSearchResult)
    case accountBalances([AskSpendSmartToolContext.AccountBalanceResult])
    case manualRegisters([AskSpendSmartToolContext.ManualRegisterResult])
    case billsStatus(AskSpendSmartToolContext.BillsStatusResult)
    case savingsStatus(AskSpendSmartToolContext.SavingsStatusResult)
    case categoryTotals([AskSpendSmartToolContext.CategoryTotalResult], dateRangeLabel: String)
    case periodComparison(AskSpendSmartToolContext.PeriodComparisonResult)
    case featureExplanation(name: String, description: String)
    case hypotheticalSavingsGoal(AskSpendSmartToolContext.HypotheticalSavingsGoalResult)
    case calculateTransactionsExplanation(String)
    case noMatches(String)
    case unsupported(String)
}
