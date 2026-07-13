import Foundation

/// Local, offline "Ask SpendSmart" query engine for the Insights feature. Takes plain arrays and
/// `DateInterval`s (never touches SwiftData/persistence directly) and answers a small fixed set
/// of questions about bills, income, and spending using only `BudgetCalculator` and
/// `MonthlyPlanCalculator` — no calculation logic is duplicated here beyond simple filtering and
/// grouping.
///
/// This is entirely on-device keyword matching against a known set of `Question` cases — there is
/// no external AI provider, no networking, and no data ever leaves the device.
enum SpendSmartQueryEngine {

    struct BreakdownRow: Identifiable, Equatable {
        let label: String
        let amount: Decimal
        var id: String { label }
    }

    struct Answer: Equatable {
        let title: String
        /// `nil` only for `.unknown` — every recognized question has a real total.
        let totalAmount: Decimal?
        let explanation: String
        let breakdown: [BreakdownRow]
    }

    enum Question: Equatable {
        case midMonthBills
        case endMonthBills
        case beginningMonthBills
        case weeklyBills
        case monthlyIncome
        case fixedMonthlyExpenses
        case subscriptions
        case utilities
        case creditCardMinimums
        case billsByCategory
        case spendingByCategory
        case thisWeekSpending
        case thisMonthSpending
        case savingsOutlook
        /// A single named category/bill lookup — e.g. "Electric", "Cellular", "Loans".
        case categoryBillAmount(String)
        /// A named category looked up against actual transactions — e.g. "gas spending".
        case categorySpendingAmount(String)
        case unknown(String)
    }

    struct QuickQuestion: Identifiable, Equatable {
        let id: String
        let title: String
        let question: Question
    }

    /// The 14 quick-question chips shown on the Insights screen, in display order.
    static let quickQuestions: [QuickQuestion] = [
        QuickQuestion(id: "midMonthBills", title: "Mid-Month Bills", question: .midMonthBills),
        QuickQuestion(id: "endMonthBills", title: "End-Month Bills", question: .endMonthBills),
        QuickQuestion(id: "beginningMonthBills", title: "Beginning-Month Bills", question: .beginningMonthBills),
        QuickQuestion(id: "weeklyBills", title: "Weekly Bills", question: .weeklyBills),
        QuickQuestion(id: "monthlyIncome", title: "Monthly Income", question: .monthlyIncome),
        QuickQuestion(id: "fixedMonthlyExpenses", title: "Fixed Monthly Expenses", question: .fixedMonthlyExpenses),
        QuickQuestion(id: "subscriptions", title: "Subscriptions", question: .subscriptions),
        QuickQuestion(id: "utilities", title: "Utilities", question: .utilities),
        QuickQuestion(id: "creditCardMinimums", title: "Credit Card Minimums", question: .creditCardMinimums),
        QuickQuestion(id: "loans", title: "Loans", question: .categoryBillAmount("Loans")),
        QuickQuestion(id: "spendingByCategory", title: "Spending by Category", question: .spendingByCategory),
        QuickQuestion(id: "thisWeekSpending", title: "This Week Spending", question: .thisWeekSpending),
        QuickQuestion(id: "thisMonthSpending", title: "This Month Spending", question: .thisMonthSpending),
        QuickQuestion(id: "savingsOutlook", title: "Savings Outlook", question: .savingsOutlook),
    ]

    /// Category names grouped as "Utilities" for the `.utilities` question.
    private static let utilityCategoryNames = ["electric", "water/sewage", "internet/tv", "cellular"]

    // MARK: - Parsing

    /// Simple on-device keyword matching — no NLP model, no external service. Order matters:
    /// more specific phrases are checked before generic ones.
    static func parseQuestion(_ text: String) -> Question {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return .unknown(text) }

        if q.contains("mid") && q.contains("bill") { return .midMonthBills }
        if q.contains("end") && q.contains("bill") { return .endMonthBills }
        if q.contains("beginning") && q.contains("bill") { return .beginningMonthBills }
        if q.contains("weekly") && q.contains("bill") { return .weeklyBills }
        if q.contains("subscription") { return .subscriptions }
        if q.contains("utilit") { return .utilities }
        if q.contains("credit card") && (q.contains("minimum") || q.contains("min")) { return .creditCardMinimums }
        if q.contains("gas") { return q.contains("spend") ? .categorySpendingAmount("Gas") : .categoryBillAmount("Gas") }
        if q.contains("electric") { return .categoryBillAmount("Electric") }
        if q.contains("cellular") { return .categoryBillAmount("Cellular") }
        if q.contains("water") || q.contains("sewage") { return .categoryBillAmount("Water/Sewage") }
        if q.contains("loan") { return .categoryBillAmount("Loans") }
        if q.contains("income") { return .monthlyIncome }
        if q.contains("fixed") && q.contains("expense") { return .fixedMonthlyExpenses }
        if q.contains("bill") && q.contains("categor") { return .billsByCategory }
        if q.contains("category") && q.contains("spend") { return .spendingByCategory }
        if q.contains("overspend") || q.contains("on track") || q.contains("save") || q.contains("saving") { return .savingsOutlook }
        if q.contains("week") && q.contains("spend") { return .thisWeekSpending }
        if q.contains("month") && q.contains("spend") { return .thisMonthSpending }

        return .unknown(text)
    }

    // MARK: - Context

    /// Everything `answer(for:context:)` needs, gathered from a live `@Query` in the view layer.
    /// Nothing here is fetched or computed here — purely a data bag.
    struct Context {
        let incomeSources: [IncomeSource]
        let recurringExpenses: [RecurringExpense]
        let transactions: [FinanceTransaction]
        let accounts: [Account]
        let planSettings: MonthlyPlanSettings?
        let weeklyBudgetLimit: Decimal
        let month: DateInterval
        let week: DateInterval
        let weekStartsOnSunday: Bool
        let includePending: Bool
        let warningThreshold: Double
    }

    // MARK: - Answering

    static func answer(for question: Question, context: Context) -> Answer {
        switch question {
        case .midMonthBills:
            return billTimingAnswer(title: "Mid-Month Bills", timing: .midMonth, context: context)
        case .endMonthBills:
            return billTimingAnswer(title: "End-Month Bills", timing: .endMonth, context: context)
        case .beginningMonthBills:
            return billTimingAnswer(title: "Beginning-Month Bills", timing: .beginningMonth, context: context)
        case .weeklyBills:
            return billTimingAnswer(title: "Weekly Bills", timing: .weekly, context: context)

        case .monthlyIncome:
            let (total, rows) = incomeTotal(timing: nil, sources: context.incomeSources, in: context.month)
            return Answer(
                title: "Monthly Income",
                totalAmount: total,
                explanation: rows.isEmpty
                    ? "No active income sources are set up yet."
                    : "Your estimated total income this month from all active income sources.",
                breakdown: rows
            )

        case .fixedMonthlyExpenses:
            let (total, rows) = recurringBillTotal(matching: { $0.isActive }, expenses: context.recurringExpenses, in: context.month)
            return Answer(
                title: "Fixed Monthly Expenses",
                totalAmount: total,
                explanation: rows.isEmpty
                    ? "No active recurring bills are set up yet."
                    : "Your estimated total fixed bills this month.",
                breakdown: rows
            )

        case .subscriptions:
            let (total, rows) = recurringExpenseCategoryTotal(categoryNames: ["subscriptions"], expenses: context.recurringExpenses, in: context.month)
            return Answer(
                title: "Subscriptions",
                totalAmount: total,
                explanation: rows.isEmpty
                    ? "No active bills are categorized as Subscriptions."
                    : "Active recurring bills categorized as Subscriptions.",
                breakdown: rows
            )

        case .utilities:
            let (total, rows) = recurringExpenseCategoryTotal(categoryNames: utilityCategoryNames, expenses: context.recurringExpenses, in: context.month)
            return Answer(
                title: "Utilities",
                totalAmount: total,
                explanation: rows.isEmpty
                    ? "No active bills are categorized as a utility (Electric, Water/Sewage, Internet/TV, or Cellular)."
                    : "Active recurring bills for Electric, Water/Sewage, Internet/TV, and Cellular.",
                breakdown: rows
            )

        case .creditCardMinimums:
            let (total, rows) = creditCardMinimumsTotal(accounts: context.accounts)
            return Answer(
                title: "Credit Card Minimums",
                totalAmount: total,
                explanation: rows.isEmpty
                    ? "No active credit card has a minimum payment set."
                    : "Minimum payments across your active credit cards.",
                breakdown: rows
            )

        case .billsByCategory:
            let grouped = Dictionary(grouping: context.recurringExpenses.filter { $0.isActive }) { $0.category?.name ?? "Uncategorized" }
            let rows = grouped.compactMap { categoryName, expenses -> BreakdownRow? in
                let total = expenses.reduce(Decimal(0)) { $0 + (monthlyContribution(of: $1, in: context.month) ?? 0) }
                guard total > 0 else { return nil }
                return BreakdownRow(label: categoryName, amount: total)
            }.sorted { $0.amount > $1.amount }
            let total = rows.reduce(Decimal(0)) { $0 + $1.amount }
            return Answer(
                title: "Bills by Category",
                totalAmount: total,
                explanation: rows.isEmpty
                    ? "No active recurring bills are set up yet."
                    : "Your active recurring bills grouped by category.",
                breakdown: rows
            )

        case .spendingByCategory:
            let totals = BudgetCalculator.categoryTotals(context.transactions, in: context.month, includePending: context.includePending, context: .monthly)
            let rows = totals.map { BreakdownRow(label: $0.category?.name ?? "Uncategorized", amount: $0.total) }
            let total = BudgetCalculator.monthlySpent(context.transactions, in: context.month, includePending: context.includePending)
            return Answer(
                title: "Spending by Category",
                totalAmount: total,
                explanation: rows.isEmpty
                    ? "No spending recorded this month yet."
                    : "Where your money went this month, by category.",
                breakdown: rows
            )

        case .thisWeekSpending:
            let total = BudgetCalculator.weeklySpent(context.transactions, in: context.week, includePending: context.includePending)
            let rows = BudgetCalculator.categoryTotals(context.transactions, in: context.week, includePending: context.includePending, context: .weekly)
                .map { BreakdownRow(label: $0.category?.name ?? "Uncategorized", amount: $0.total) }
            return Answer(
                title: "This Week Spending",
                totalAmount: total,
                explanation: "Your net spending for the current week.",
                breakdown: rows
            )

        case .thisMonthSpending:
            let total = BudgetCalculator.monthlySpent(context.transactions, in: context.month, includePending: context.includePending)
            let rows = BudgetCalculator.categoryTotals(context.transactions, in: context.month, includePending: context.includePending, context: .monthly)
                .map { BreakdownRow(label: $0.category?.name ?? "Uncategorized", amount: $0.total) }
            return Answer(
                title: "This Month Spending",
                totalAmount: total,
                explanation: "Your net spending for the current month.",
                breakdown: rows
            )

        case .savingsOutlook:
            return savingsOutlookAnswer(context: context)

        case .categoryBillAmount(let name):
            let (total, rows) = recurringExpenseCategoryTotal(categoryNames: [name.lowercased()], expenses: context.recurringExpenses, in: context.month, matchNameToo: true)
            return Answer(
                title: name,
                totalAmount: total,
                explanation: rows.isEmpty
                    ? "No active bills found matching \"\(name)\"."
                    : "Active recurring bills matching \"\(name)\".",
                breakdown: rows
            )

        case .categorySpendingAmount(let name):
            let total = transactionCategoryAmount(categoryName: name, transactions: context.transactions, in: context.month, includePending: context.includePending)
            return Answer(
                title: "\(name) Spending",
                totalAmount: total,
                explanation: total == 0
                    ? "No transactions categorized as \"\(name)\" this month."
                    : "Transactions categorized as \"\(name)\" this month.",
                breakdown: []
            )

        case .unknown(let text):
            return Answer(
                title: "Not Sure Yet",
                totalAmount: nil,
                explanation: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Ask a question, or try one of the quick questions below."
                    : "I couldn't match \"\(text)\" to a question I know yet. Try one of the quick questions below, like \"Mid-Month Bills\" or \"This Month Spending\".",
                breakdown: []
            )
        }
    }

    // MARK: - Bill timing helpers

    private static func billTimingAnswer(title: String, timing: PlanTiming, context: Context) -> Answer {
        let (total, rows) = recurringBillTotal(matching: { $0.isActive && $0.timing == timing }, expenses: context.recurringExpenses, in: context.month)
        return Answer(
            title: title,
            totalAmount: total,
            explanation: rows.isEmpty
                ? "You don't have any active bills set to this timing yet."
                : "Active recurring bills set to this timing, totaled for the current month.",
            breakdown: rows
        )
    }

    /// Sums `expenses` matching `matching`, converting each to its monthly-equivalent amount via
    /// `MonthlyPlanCalculator.monthlyAmount(for:frequency:)` — a `.oneTime` expense only counts if
    /// its due date falls in `month`. Never reimplements that conversion formula itself.
    static func recurringBillTotal(
        matching: (RecurringExpense) -> Bool,
        expenses: [RecurringExpense],
        in month: DateInterval
    ) -> (total: Decimal, breakdown: [BreakdownRow]) {
        var rows: [BreakdownRow] = []
        for expense in expenses where matching(expense) {
            guard let amount = monthlyContribution(of: expense, in: month) else { continue }
            rows.append(BreakdownRow(label: expense.name, amount: amount))
        }
        rows.sort { $0.amount > $1.amount }
        let total = rows.reduce(Decimal(0)) { $0 + $1.amount }
        return (total, rows)
    }

    /// This expense's monthly-equivalent contribution for `month`, or `nil` if it doesn't count
    /// this month (a `.oneTime` expense whose due date falls outside `month`).
    private static func monthlyContribution(of expense: RecurringExpense, in month: DateInterval) -> Decimal? {
        if expense.frequency == .oneTime {
            guard let due = expense.dueDate, month.contains(due) else { return nil }
            return expense.amount
        }
        return MonthlyPlanCalculator.monthlyAmount(for: expense.amount, frequency: expense.frequency)
    }

    static func recurringExpenseCategoryTotal(
        categoryNames: [String],
        expenses: [RecurringExpense],
        in month: DateInterval,
        matchNameToo: Bool = false
    ) -> (total: Decimal, breakdown: [BreakdownRow]) {
        let normalizedSet = Set(categoryNames.map { $0.lowercased() })
        return recurringBillTotal(matching: { expense in
            guard expense.isActive else { return false }
            if let categoryName = expense.category?.name.lowercased(), normalizedSet.contains(categoryName) {
                return true
            }
            guard matchNameToo else { return false }
            let expenseName = expense.name.lowercased()
            return normalizedSet.contains { expenseName.contains($0) }
        }, expenses: expenses, in: month)
    }

    // MARK: - Income helpers

    /// Sums active income sources, optionally filtered to a single `PlanTiming` (`nil` means "all
    /// active income sources"). Mirrors `recurringBillTotal`'s one-time-date-in-month handling.
    static func incomeTotal(
        timing: PlanTiming?,
        sources: [IncomeSource],
        in month: DateInterval
    ) -> (total: Decimal, breakdown: [BreakdownRow]) {
        var rows: [BreakdownRow] = []
        for source in sources where source.isActive && (timing == nil || source.timing == timing) {
            let amount: Decimal
            if source.frequency == .oneTime {
                guard let payDate = source.nextPayDate, month.contains(payDate) else { continue }
                amount = source.amount
            } else {
                amount = MonthlyPlanCalculator.monthlyAmount(for: source.amount, frequency: source.frequency)
            }
            rows.append(BreakdownRow(label: source.name, amount: amount))
        }
        rows.sort { $0.amount > $1.amount }
        let total = rows.reduce(Decimal(0)) { $0 + $1.amount }
        return (total, rows)
    }

    // MARK: - Account helpers

    static func creditCardMinimumsTotal(accounts: [Account]) -> (total: Decimal, breakdown: [BreakdownRow]) {
        let rows = accounts
            .filter { $0.type == .creditCard && !$0.isArchived && ($0.minimumPayment ?? 0) > 0 }
            .map { BreakdownRow(label: $0.name, amount: $0.minimumPayment ?? 0) }
            .sorted { $0.amount > $1.amount }
        let total = rows.reduce(Decimal(0)) { $0 + $1.amount }
        return (total, rows)
    }

    // MARK: - Transaction helpers

    /// This month's net spending (expenses minus refunds) for a single category name, via
    /// `BudgetCalculator.categoryTotals` — never reimplements that math.
    static func transactionCategoryAmount(
        categoryName: String,
        transactions: [FinanceTransaction],
        in interval: DateInterval,
        includePending: Bool
    ) -> Decimal {
        let normalized = categoryName.trimmingCharacters(in: .whitespaces).lowercased()
        let totals = BudgetCalculator.categoryTotals(transactions, in: interval, includePending: includePending, context: .monthly)
        return totals.first { ($0.category?.name ?? "Uncategorized").lowercased() == normalized }?.total ?? 0
    }

    // MARK: - Savings outlook

    private static func savingsOutlookAnswer(context: Context) -> Answer {
        let summary = MonthlyPlanCalculator.summary(
            month: context.month,
            incomeSources: context.incomeSources,
            recurringExpenses: context.recurringExpenses,
            planSettings: context.planSettings,
            weeklyBudgetLimit: context.weeklyBudgetLimit,
            transactions: context.transactions,
            weekInterval: context.week,
            weekStartsOnSunday: context.weekStartsOnSunday,
            includePending: context.includePending,
            warningThreshold: context.warningThreshold
        )

        let explanation: String
        switch summary.projectedStatus {
        case .good:
            explanation = "You're on track to save this month at your current pace."
        case .warning:
            explanation = "Your savings goal is at risk this month at your current pace."
        case .over:
            explanation = "You're projected to overspend this month at your current pace."
        }

        let rows = [
            BreakdownRow(label: "Estimated Income", amount: summary.estimatedMonthlyIncome),
            BreakdownRow(label: "Fixed Expenses", amount: summary.estimatedMonthlyFixedExpenses),
            BreakdownRow(label: "Spent So Far", amount: summary.actualSpentThisMonth),
        ]

        return Answer(
            title: "Savings Outlook",
            totalAmount: summary.projectedMonthlySavings,
            explanation: explanation,
            breakdown: rows
        )
    }
}
