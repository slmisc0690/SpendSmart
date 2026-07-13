import Foundation
import SwiftData

/// In-memory sample data for SwiftUI previews only. Never used at app runtime or inserted into
/// the real local database.
enum SampleData {

    /// A populated container: accounts, categories, budget settings, and a handful of
    /// transactions (including a pending one and a refund) so previews show a realistic,
    /// premium-looking dashboard.
    @MainActor
    static var previewContainer: ModelContainer = {
        let container = makeContainer()
        let context = container.mainContext

        let dining = Category(name: "Food", iconName: "fork.knife", colorName: "orange", isDefault: true)
        let groceries = Category(name: "Groceries", iconName: "cart.fill", colorName: "green", isDefault: true)
        let gas = Category(name: "Gas", iconName: "fuelpump.fill", colorName: "yellow", isDefault: true)
        let shopping = Category(name: "Shopping", iconName: "bag.fill", colorName: "purple", isDefault: true)
        let home = Category(name: "Home", iconName: "house.fill", colorName: "indigo", isDefault: true)
        let creditCard = Category(name: "Credit Card", iconName: "creditcard.fill", colorName: "red", isDefault: true)
        [dining, groceries, gas, shopping, home, creditCard].forEach { context.insert($0) }

        let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 4231.55, institutionName: "Chase")
        let savings = Account(name: "Emergency Fund", type: .savings, currentBalance: 12450.00, institutionName: "Ally")
        let amex = Account(name: "Amex Gold", type: .creditCard, currentBalance: 812.40, institutionName: "American Express", creditLimit: 8000, colorHex: "#C7A15A")
        [checking, savings, amex].forEach { context.insert($0) }

        let settings = BudgetSettings(weeklySpendingLimit: 350, monthlyGoal: 1400)
        context.insert(settings)

        let planSettings = MonthlyPlanSettings(monthlySavingsGoal: 500, bufferAmount: 100)
        context.insert(planSettings)

        let paycheck = IncomeSource(name: "Paycheck", amount: 2100, frequency: .biweekly, timing: .customDate)
        let otherIncome = IncomeSource(name: "Side Income", amount: 300, frequency: .monthly, timing: .endMonth)
        [paycheck, otherIncome].forEach { context.insert($0) }

        let rent = RecurringExpense(name: "Rent", amount: 1800, frequency: .monthly, timing: .beginningMonth, isEssential: true)
        let carPayment = RecurringExpense(name: "Car Payment", amount: 340, frequency: .monthly, timing: .midMonth, isEssential: true)
        let insurance = RecurringExpense(name: "Insurance", amount: 120, frequency: .monthly, timing: .midMonth, isEssential: true)
        let subscriptions = RecurringExpense(name: "Streaming Subscriptions", amount: 45, frequency: .monthly, timing: .beginningMonth, isEssential: false)
        [rent, carPayment, insurance, subscriptions].forEach { context.insert($0) }

        let now = Date()
        let calendar = Calendar.current
        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: now) ?? now
        }

        let entries: [FinanceTransaction] = [
            FinanceTransaction(amount: 42.18, date: daysAgo(0), type: .expense, note: "Trader Joe's", account: checking, category: groceries),
            FinanceTransaction(amount: 18.50, date: daysAgo(1), type: .expense, note: "Sweetgreen", isPending: true, account: amex, category: dining),
            FinanceTransaction(amount: 64.00, date: daysAgo(1), type: .expense, note: "Shell", account: amex, category: gas),
            FinanceTransaction(amount: 129.99, date: daysAgo(2), type: .expense, note: "Nike.com", account: amex, category: shopping),
            FinanceTransaction(amount: 15.00, date: daysAgo(2), type: .refund, note: "Nike.com Refund", account: amex, category: shopping),
            FinanceTransaction(amount: 9.75, date: daysAgo(3), type: .expense, note: "Blue Bottle Coffee", account: checking, category: dining),
            FinanceTransaction(amount: 56.32, date: daysAgo(4), type: .expense, note: "Whole Foods", account: checking, category: groceries),
        ]
        entries.forEach { context.insert($0) }

        return container
    }()

    /// A fresh, empty container (no accounts, transactions, categories, or settings) used to
    /// preview first-run empty states. A function rather than a stored property, so each call
    /// site gets its own independent container instead of sharing (and risking cross-mutating)
    /// a single instance.
    @MainActor
    static func emptyPreviewContainer() -> ModelContainer {
        makeContainer()
    }

    @MainActor
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([
            Account.self,
            FinanceTransaction.self,
            BudgetSettings.self,
            Category.self,
            IncomeSource.self,
            RecurringExpense.self,
            MonthlyPlanSettings.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [config])
    }
}
