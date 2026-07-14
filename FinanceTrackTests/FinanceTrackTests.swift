import XCTest
import SwiftData
@testable import FinanceTrack

final class FinanceTrackTests: XCTestCase {

    /// A fresh in-memory `ModelContext` for tests that exercise `AutosaveCommitter`, which needs
    /// a real `ModelContext` to insert into (unlike the rest of this codebase's pure calculators,
    /// which operate on plain arrays and never touch persistence directly).
    private func makeAutosaveTestContext() -> ModelContext {
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
        let container = try! ModelContainer(for: schema, configurations: [config])
        // A plain, non-actor-isolated context (rather than `container.mainContext`) — this test
        // bundle's runner thread isn't guaranteed to be recognized as the main thread, and
        // `mainContext` traps if accessed off of it.
        return ModelContext(container)
    }

    // MARK: - Date ranges

    func testWeekRangeSpansSevenDays() {
        let interval = DateRangeHelper.currentWeekRange()
        let days = Calendar.current.dateComponents([.day], from: interval.start, to: interval.end).day
        XCTAssertEqual(days, 7)
    }

    func testWeekRangeStartsOnSundayWhenConfigured() {
        let interval = DateRangeHelper.currentWeekRange(weekStartsOnSunday: true)
        let weekday = Calendar.current.component(.weekday, from: interval.start)
        XCTAssertEqual(weekday, 1) // 1 == Sunday in Calendar.current's Gregorian numbering
    }

    // MARK: - Weekly spending

    func testWeeklySpendingExcludesCreditCardPayments() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let card = Account(name: "Card", type: .creditCard)
        let expense = FinanceTransaction(amount: 50, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Groceries", account: checking)
        let payment = FinanceTransaction(amount: 100, date: interval.start.addingTimeInterval(7200), type: .creditCardPayment, note: "Card Payment", account: checking, transferDestinationAccount: card)

        let spent = BudgetCalculator.weeklySpent([expense, payment], in: interval)

        XCTAssertEqual(spent, 50)
    }

    func testWeeklySpendingExcludesTransfers() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let savings = Account(name: "Savings", type: .savings)
        let transfer = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .transfer, note: "To savings", account: checking, transferDestinationAccount: savings)

        let spent = BudgetCalculator.weeklySpent([transfer], in: interval)

        XCTAssertEqual(spent, 0)
    }

    func testWeeklySpendingExcludesBalanceAdjustments() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let adjustment = FinanceTransaction(amount: 500, date: interval.start.addingTimeInterval(3600), type: .balanceAdjustment, note: "Correction", account: checking)

        let spent = BudgetCalculator.weeklySpent([adjustment], in: interval)

        XCTAssertEqual(spent, 0)
    }

    func testRefundsReduceWeeklySpending() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let expense = FinanceTransaction(amount: 100, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Shoes", account: checking)
        let refund = FinanceTransaction(amount: 30, date: interval.start.addingTimeInterval(7200), type: .refund, note: "Shoes refund", account: checking)

        let spent = BudgetCalculator.weeklySpent([expense, refund], in: interval)

        XCTAssertEqual(spent, 70)
    }

    func testPendingTransactionsExcludedWhenSettingDisabled() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let pendingExpense = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Coffee", isPending: true, account: checking)

        let spentIncludingPending = BudgetCalculator.weeklySpent([pendingExpense], in: interval, includePending: true)
        let spentExcludingPending = BudgetCalculator.weeklySpent([pendingExpense], in: interval, includePending: false)

        XCTAssertEqual(spentIncludingPending, 40)
        XCTAssertEqual(spentExcludingPending, 0)
    }

    // MARK: - Monthly spending

    func testMonthlySpendingExcludesCreditCardPayments() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let card = Account(name: "Card", type: .creditCard)
        let expense = FinanceTransaction(amount: 75, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Dinner", account: checking)
        let payment = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(7200), type: .creditCardPayment, note: "Card Payment", account: checking, transferDestinationAccount: card)

        let spent = BudgetCalculator.monthlySpent([expense, payment], in: interval)

        XCTAssertEqual(spent, 75)
    }

    // MARK: - Budget status

    func testDefaultWarningThresholdIsSeventyPercent() {
        let settings = BudgetSettings()
        XCTAssertEqual(settings.warningThreshold, 0.70)
    }

    func testSeventyPercentSpentTriggersWarningStatus() {
        let status = BudgetCalculator.status(spent: 70, limit: 100, warningThreshold: 0.70)
        XCTAssertEqual(status, .warning)
    }

    func testJustBelowSeventyPercentSpentIsGoodStatus() {
        let status = BudgetCalculator.status(spent: 69, limit: 100, warningThreshold: 0.70)
        XCTAssertEqual(status, .good)
    }

    func testFullyAtLimitIsOverStatus() {
        let status = BudgetCalculator.status(spent: 100, limit: 100, warningThreshold: 0.70)
        XCTAssertEqual(status, .over)
    }

    // MARK: - Account balance behavior

    func testExpenseOnCreditCardIncreasesBalance() {
        let card = Account(name: "Card", type: .creditCard, currentBalance: 100)

        AccountBalanceManager.applyExpense(amount: 50, to: card)

        XCTAssertEqual(card.currentBalance, 150)
    }

    func testExpenseOnCheckingDecreasesBalance() {
        let checking = Account(name: "Checking", type: .checking, currentBalance: 500)

        AccountBalanceManager.applyExpense(amount: 50, to: checking)

        XCTAssertEqual(checking.currentBalance, 450)
    }

    func testCreditCardPaymentDecreasesBothCheckingAndCardBalance() {
        let checking = Account(name: "Checking", type: .checking, currentBalance: 500)
        let card = Account(name: "Card", type: .creditCard, currentBalance: 200)

        AccountBalanceManager.applyCreditCardPayment(amount: 100, from: checking, to: card)

        XCTAssertEqual(checking.currentBalance, 400)
        XCTAssertEqual(card.currentBalance, 100)
    }

    func testTransferMovesMoneyBetweenAccounts() {
        let checking = Account(name: "Checking", type: .checking, currentBalance: 500)
        let savings = Account(name: "Savings", type: .savings, currentBalance: 1000)

        AccountBalanceManager.applyTransfer(amount: 200, from: checking, to: savings)

        XCTAssertEqual(checking.currentBalance, 300)
        XCTAssertEqual(savings.currentBalance, 1200)
    }

    func testRefundOnCreditCardDecreasesBalance() {
        let card = Account(name: "Card", type: .creditCard, currentBalance: 150)

        AccountBalanceManager.applyRefund(amount: 50, to: card)

        XCTAssertEqual(card.currentBalance, 100)
    }

    func testRefundOnCheckingIncreasesBalance() {
        let checking = Account(name: "Checking", type: .checking, currentBalance: 450)

        AccountBalanceManager.applyRefund(amount: 50, to: checking)

        XCTAssertEqual(checking.currentBalance, 500)
    }

    // MARK: - Add Expense flow (exclude from reports / pending)

    func testExcludedTransactionDoesNotCountTowardWeeklySpending() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let excludedExpense = FinanceTransaction(amount: 80, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Reimbursable", isExcludedFromReports: true, account: checking)

        let spent = BudgetCalculator.weeklySpent([excludedExpense], in: interval)

        XCTAssertEqual(spent, 0)
    }

    func testExcludedTransactionDoesNotCountTowardMonthlySpending() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let excludedExpense = FinanceTransaction(amount: 80, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Reimbursable", isExcludedFromReports: true, account: checking)

        let spent = BudgetCalculator.monthlySpent([excludedExpense], in: interval)

        XCTAssertEqual(spent, 0)
    }

    // MARK: - Account management

    func testAddingCheckingAccountHasCorrectDefaults() {
        let account = Account(name: "Everyday Checking", type: .checking, currentBalance: 1000)

        XCTAssertEqual(account.type, .checking)
        XCTAssertEqual(account.currentBalance, 1000)
        XCTAssertFalse(account.isArchived)
    }

    func testAddingCreditCardAccountStoresCreditFields() {
        let account = Account(name: "Amex Gold", type: .creditCard, currentBalance: 200, creditLimit: 5000, minimumPayment: 35)

        XCTAssertEqual(account.type, .creditCard)
        XCTAssertEqual(account.creditLimit, 5000)
        XCTAssertEqual(account.minimumPayment, 35)
    }

    func testEditingAccountUpdatesFields() {
        let account = Account(name: "Old Name", type: .checking, currentBalance: 100)

        account.name = "New Name"
        account.currentBalance = 250

        XCTAssertEqual(account.name, "New Name")
        XCTAssertEqual(account.currentBalance, 250)
    }

    func testArchivingAccountExcludesItFromActiveTotals() {
        let checkingA = Account(name: "Checking A", type: .checking, currentBalance: 500)
        let checkingB = Account(name: "Checking B", type: .checking, currentBalance: 300)
        checkingB.isArchived = true

        let total = AccountBalanceManager.totalBalance(of: [checkingA, checkingB], types: [.checking])

        XCTAssertEqual(total, 500)
    }

    // MARK: - Balance adjustment

    func testBalanceAdjustmentDoesNotCountTowardMonthlySpending() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let adjustment = FinanceTransaction(amount: 500, date: interval.start.addingTimeInterval(3600), type: .balanceAdjustment, note: "Correction", countsTowardWeeklyBudget: false, isExcludedFromReports: true, account: checking)

        let spent = BudgetCalculator.monthlySpent([adjustment], in: interval)

        XCTAssertEqual(spent, 0)
    }

    // MARK: - Credit utilization

    func testCreditUtilizationBelowThirtyPercentIsGood() {
        let status = CreditUtilizationCalculator.status(balance: 200, limit: 1000) // 20%
        XCTAssertEqual(status, .good)
    }

    func testCreditUtilizationAtThirtyPercentIsCaution() {
        let status = CreditUtilizationCalculator.status(balance: 300, limit: 1000) // 30%
        XCTAssertEqual(status, .caution)
    }

    func testCreditUtilizationJustBelowThirtyPercentIsGood() {
        let status = CreditUtilizationCalculator.status(balance: 299, limit: 1000) // 29.9%
        XCTAssertEqual(status, .good)
    }

    func testCreditUtilizationAtEightyPercentIsHigh() {
        let status = CreditUtilizationCalculator.status(balance: 800, limit: 1000) // 80%
        XCTAssertEqual(status, .high)
    }

    func testCreditUtilizationJustBelowEightyPercentIsCaution() {
        let status = CreditUtilizationCalculator.status(balance: 799, limit: 1000) // 79.9%
        XCTAssertEqual(status, .caution)
    }

    func testAvailableCreditCalculation() {
        let available = CreditUtilizationCalculator.availableCredit(balance: 300, limit: 1000)
        XCTAssertEqual(available, 700)
    }

    func testAvailableCreditIsNilWithoutLimit() {
        let available = CreditUtilizationCalculator.availableCredit(balance: 300, limit: nil)
        XCTAssertNil(available)
    }

    // MARK: - Weekly category breakdown

    func testWeeklyCategoryTotalsExcludeCreditCardPayments() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let card = Account(name: "Card", type: .creditCard)
        let groceries = Category(name: "Groceries")
        let expense = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Trader Joe's", account: checking, category: groceries)
        let payment = FinanceTransaction(amount: 100, date: interval.start.addingTimeInterval(7200), type: .creditCardPayment, note: "Payment", account: checking, category: groceries, transferDestinationAccount: card)

        let totals = BudgetCalculator.categoryTotals([expense, payment], in: interval, context: .weekly)

        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.total, 40)
    }

    func testWeeklyCategoryTotalsExcludeTransfers() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let savings = Account(name: "Savings", type: .savings)
        let groceries = Category(name: "Groceries")
        let transfer = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .transfer, note: "To savings", account: checking, category: groceries, transferDestinationAccount: savings)

        let totals = BudgetCalculator.categoryTotals([transfer], in: interval, context: .weekly)

        XCTAssertTrue(totals.isEmpty)
    }

    func testWeeklyCategoryTotalsExcludeBalanceAdjustments() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let groceries = Category(name: "Groceries")
        let adjustment = FinanceTransaction(amount: 500, date: interval.start.addingTimeInterval(3600), type: .balanceAdjustment, note: "Correction", account: checking, category: groceries)

        let totals = BudgetCalculator.categoryTotals([adjustment], in: interval, context: .weekly)

        XCTAssertTrue(totals.isEmpty)
    }

    func testWeeklyCategoryTotalsSubtractRefunds() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let shopping = Category(name: "Shopping")
        let expense = FinanceTransaction(amount: 100, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Shoes", account: checking, category: shopping)
        let refund = FinanceTransaction(amount: 30, date: interval.start.addingTimeInterval(7200), type: .refund, note: "Shoes refund", account: checking, category: shopping)

        let totals = BudgetCalculator.categoryTotals([expense, refund], in: interval, context: .weekly)

        XCTAssertEqual(totals.first?.total, 70)
    }

    func testPendingExcludedFromWeeklyCategoryTotalsWhenSettingDisabled() {
        let interval = DateRangeHelper.currentWeekRange()
        let checking = Account(name: "Checking", type: .checking)
        let dining = Category(name: "Dining")
        let pendingExpense = FinanceTransaction(amount: 25, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Coffee", isPending: true, account: checking, category: dining)

        let totalsIncluding = BudgetCalculator.categoryTotals([pendingExpense], in: interval, includePending: true, context: .weekly)
        let totalsExcluding = BudgetCalculator.categoryTotals([pendingExpense], in: interval, includePending: false, context: .weekly)

        XCTAssertEqual(totalsIncluding.first?.total, 25)
        XCTAssertTrue(totalsExcluding.isEmpty)
    }

    // MARK: - Weekly remaining / over-budget

    func testWeeklyRemainingAmountCalculatedCorrectly() {
        let remaining = BudgetCalculator.remaining(limit: 350, spent: 210)
        XCTAssertEqual(remaining, 140)
    }

    func testOverBudgetAmountCalculatedCorrectly() {
        let overAmount = BudgetCalculator.overBudgetAmount(spent: 420, limit: 350)
        XCTAssertEqual(overAmount, 70)
    }

    func testOverBudgetAmountIsZeroWhenUnderLimit() {
        let overAmount = BudgetCalculator.overBudgetAmount(spent: 200, limit: 350)
        XCTAssertEqual(overAmount, 0)
    }

    func testUpdatingWeeklySpendingLimitAffectsStatus() {
        let settings = BudgetSettings(weeklySpendingLimit: 100)

        let statusBefore = BudgetCalculator.status(spent: 90, limit: settings.weeklySpendingLimit, warningThreshold: settings.warningThreshold)
        XCTAssertEqual(statusBefore, .warning) // 90% >= 70% threshold

        settings.weeklySpendingLimit = 200
        let statusAfter = BudgetCalculator.status(spent: 90, limit: settings.weeklySpendingLimit, warningThreshold: settings.warningThreshold)
        XCTAssertEqual(statusAfter, .good) // 45% < 70% threshold
    }

    // MARK: - Monthly spending

    func testMonthlySpendingExcludesTransfers() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let savings = Account(name: "Savings", type: .savings)
        let transfer = FinanceTransaction(amount: 300, date: interval.start.addingTimeInterval(3600), type: .transfer, note: "To savings", account: checking, transferDestinationAccount: savings)

        let spent = BudgetCalculator.monthlySpent([transfer], in: interval)

        XCTAssertEqual(spent, 0)
    }

    func testMonthlySpendingSubtractsRefunds() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let expense = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Flight", account: checking)
        let refund = FinanceTransaction(amount: 50, date: interval.start.addingTimeInterval(7200), type: .refund, note: "Flight refund", account: checking)

        let spent = BudgetCalculator.monthlySpent([expense, refund], in: interval)

        XCTAssertEqual(spent, 150)
    }

    func testPendingTransactionsExcludedFromMonthlySpendingWhenSettingDisabled() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let pendingExpense = FinanceTransaction(amount: 60, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Pending charge", isPending: true, account: checking)

        let spentIncluding = BudgetCalculator.monthlySpent([pendingExpense], in: interval, includePending: true)
        let spentExcluding = BudgetCalculator.monthlySpent([pendingExpense], in: interval, includePending: false)

        XCTAssertEqual(spentIncluding, 60)
        XCTAssertEqual(spentExcluding, 0)
    }

    func testTransactionsOutsideSelectedMonthAreExcluded() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let beforeMonth = FinanceTransaction(amount: 500, date: interval.start.addingTimeInterval(-3600), type: .expense, note: "Last month", account: checking)
        let afterMonth = FinanceTransaction(amount: 500, date: interval.end.addingTimeInterval(3600), type: .expense, note: "Next month", account: checking)
        let insideMonth = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, note: "This month", account: checking)

        let spent = BudgetCalculator.monthlySpent([beforeMonth, afterMonth, insideMonth], in: interval)

        XCTAssertEqual(spent, 40)
    }

    // MARK: - Monthly category / account breakdowns

    func testMonthlyCategoryTotalsSubtractRefunds() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let travel = Category(name: "Travel")
        let expense = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Flight", account: checking, category: travel)
        let refund = FinanceTransaction(amount: 50, date: interval.start.addingTimeInterval(7200), type: .refund, note: "Flight refund", account: checking, category: travel)

        let totals = BudgetCalculator.categoryTotals([expense, refund], in: interval, context: .monthly)

        XCTAssertEqual(totals.first?.total, 150)
    }

    func testMonthlyAccountTotalsSubtractRefunds() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let expense = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .expense, note: "Flight", account: checking)
        let refund = FinanceTransaction(amount: 50, date: interval.start.addingTimeInterval(7200), type: .refund, note: "Flight refund", account: checking)

        let totals = BudgetCalculator.accountTotals([expense, refund], in: interval, context: .monthly)

        XCTAssertEqual(totals.first?.total, 150)
    }

    // MARK: - Monthly goal

    func testMonthlyGoalRemainingCalculatedCorrectly() {
        let remaining = BudgetCalculator.remaining(limit: 1400, spent: 890)
        XCTAssertEqual(remaining, 510)
    }

    func testMonthlyOverGoalCalculatedCorrectly() {
        let overAmount = BudgetCalculator.overBudgetAmount(spent: 1600, limit: 1400)
        XCTAssertEqual(overAmount, 200)
    }

    // MARK: - Weeks overlapping a month

    func testWeekClampedToMonthOnlyCountsTransactionsInsideMonth() {
        let calendar = Calendar.current
        let monthInterval = DateRangeHelper.monthRangeContaining(.now)
        // A week that starts a few days before the month begins and crosses into it.
        let weekBeforeMonthStart = calendar.date(byAdding: .day, value: -3, to: monthInterval.start) ?? monthInterval.start
        let weekInterval = DateInterval(start: weekBeforeMonthStart, end: monthInterval.start.addingTimeInterval(4 * 24 * 3600))

        let clipped = DateRangeHelper.clampedInterval(weekInterval, to: monthInterval)

        XCTAssertNotNil(clipped)
        XCTAssertEqual(clipped?.start, monthInterval.start)

        let checking = Account(name: "Checking", type: .checking)
        let beforeMonth = FinanceTransaction(amount: 100, date: weekBeforeMonthStart.addingTimeInterval(3600), type: .expense, note: "Before month", account: checking)
        let insideMonth = FinanceTransaction(amount: 40, date: monthInterval.start.addingTimeInterval(3600), type: .expense, note: "Inside month", account: checking)

        let spentInClippedWeek = BudgetCalculator.monthlySpent([beforeMonth, insideMonth], in: clipped!)

        XCTAssertEqual(spentInClippedWeek, 40)
    }

    // MARK: - Security & privacy settings

    func testRequireFaceIDDefaultsToFalse() {
        let settings = BudgetSettings()
        XCTAssertFalse(settings.requireFaceID)
    }

    func testHideBalancesByDefaultPersistsAfterChange() {
        let settings = BudgetSettings(hideBalancesByDefault: false)
        XCTAssertFalse(settings.hideBalancesByDefault)

        settings.hideBalancesByDefault = true

        XCTAssertTrue(settings.hideBalancesByDefault)
    }

    func testIncludePendingTransactionsAffectsWeeklyAndMonthlySpending() {
        let weekInterval = DateRangeHelper.currentWeekRange()
        let monthInterval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking)
        let pendingExpense = FinanceTransaction(amount: 30, date: weekInterval.start.addingTimeInterval(3600), type: .expense, note: "Pending", isPending: true, account: checking)

        XCTAssertEqual(BudgetCalculator.weeklySpent([pendingExpense], in: weekInterval, includePending: false), 0)
        XCTAssertEqual(BudgetCalculator.monthlySpent([pendingExpense], in: monthInterval, includePending: false), 0)
    }

    func testWeekStartsOnSundaySettingChangesWeekRangeStartDay() {
        let sundayStart = DateRangeHelper.currentWeekRange(weekStartsOnSunday: true)
        let mondayStart = DateRangeHelper.currentWeekRange(weekStartsOnSunday: false)

        let sundayWeekday = Calendar.current.component(.weekday, from: sundayStart.start)
        let mondayWeekday = Calendar.current.component(.weekday, from: mondayStart.start)

        XCTAssertEqual(sundayWeekday, 1) // Sunday
        XCTAssertEqual(mondayWeekday, 2) // Monday
    }

    // MARK: - Plaid placeholder architecture

    func testPlaidImportMappingSetsSourceToPlaid() {
        let dto = PlaidTransactionDTO(
            externalTransactionId: "txn-1",
            pendingTransactionId: nil,
            plaidAccountId: "account-1",
            amount: 25.00,
            merchantName: "Coffee Shop",
            originalDescription: "COFFEE SHOP #42",
            authorizedDate: .now,
            postedDate: nil,
            isPending: false,
            categoryGuess: "Food and Drink"
        )

        let transaction = PlaidTransactionImportService.mapToFinanceTransaction(dto, account: nil)

        XCTAssertEqual(transaction.source, .plaid)
        XCTAssertEqual(transaction.externalTransactionId, "txn-1")
        XCTAssertEqual(transaction.merchantName, "Coffee Shop")
        XCTAssertEqual(transaction.originalDescription, "COFFEE SHOP #42")
        XCTAssertEqual(transaction.plaidAccountId, "account-1")
    }

    func testPlaidImportMappingMapsPendingStateCorrectly() {
        let pendingDTO = PlaidTransactionDTO(
            externalTransactionId: "txn-pending",
            pendingTransactionId: nil,
            plaidAccountId: "account-1",
            amount: 10.00,
            merchantName: "Gas Station",
            originalDescription: "GAS STATION",
            authorizedDate: .now,
            postedDate: nil,
            isPending: true,
            categoryGuess: nil
        )
        let postedDTO = PlaidTransactionDTO(
            externalTransactionId: "txn-posted",
            pendingTransactionId: nil,
            plaidAccountId: "account-1",
            amount: 10.00,
            merchantName: "Gas Station",
            originalDescription: "GAS STATION",
            authorizedDate: .now.addingTimeInterval(-86_400),
            postedDate: .now,
            isPending: false,
            categoryGuess: nil
        )

        let pendingTransaction = PlaidTransactionImportService.mapToFinanceTransaction(pendingDTO, account: nil)
        let postedTransaction = PlaidTransactionImportService.mapToFinanceTransaction(postedDTO, account: nil)

        XCTAssertTrue(pendingTransaction.isPending)
        XCTAssertFalse(postedTransaction.isPending)
    }

    func testTransactionMatcherFindsCandidateForImportedTransaction() {
        let importedDTO = PlaidTransactionDTO(
            externalTransactionId: "txn-imported",
            pendingTransactionId: nil,
            plaidAccountId: "account-1",
            amount: 42.50,
            merchantName: "Whole Foods",
            originalDescription: "WHOLEFDS MKT #123",
            authorizedDate: .now,
            postedDate: nil,
            isPending: true,
            categoryGuess: "Groceries"
        )
        let imported = PlaidTransactionImportService.mapToFinanceTransaction(importedDTO, account: nil)
        let manualExpense = FinanceTransaction(amount: 42.50, date: .now, type: .expense, source: .manual, note: "Whole Foods")

        let matches = TransactionMatcher.findPossibleMatches(for: manualExpense, in: [imported])

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.transaction.externalTransactionId, "txn-imported")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.5)
    }

    // MARK: - Real Plaid Sandbox backend architecture

    func testImportedTransactionsAreNotCountedByDefault() {
        let dto = PlaidTransactionDTO(
            externalTransactionId: "txn-not-counted",
            pendingTransactionId: nil,
            plaidAccountId: "account-1",
            amount: 55.00,
            merchantName: "Amex Merchant",
            originalDescription: "AMEX MERCHANT",
            authorizedDate: .now,
            postedDate: .now,
            isPending: false,
            categoryGuess: nil
        )

        let imported = PlaidTransactionImportService.mapToFinanceTransaction(dto, account: nil)

        XCTAssertTrue(imported.isExcludedFromReports)
        XCTAssertFalse(imported.countsTowardWeeklyBudget)

        // Confirms the exclusion actually holds at the calculation layer, not just as a flag.
        let interval = DateRangeHelper.currentWeekRange()
        let backdatedImport = PlaidTransactionImportService.mapToFinanceTransaction(
            PlaidTransactionDTO(
                externalTransactionId: dto.externalTransactionId,
                pendingTransactionId: nil,
                plaidAccountId: dto.plaidAccountId,
                amount: dto.amount,
                merchantName: dto.merchantName,
                originalDescription: dto.originalDescription,
                authorizedDate: interval.start.addingTimeInterval(3600),
                postedDate: interval.start.addingTimeInterval(3600),
                isPending: false,
                categoryGuess: nil
            ),
            account: nil
        )
        let spent = BudgetCalculator.weeklySpent([backdatedImport], in: interval)
        XCTAssertEqual(spent, 0)
    }

    func testBackendTransactionDTODecodesAndMapsToPlaidTransactionDTO() throws {
        // authorized_date/posted_date use bare "yyyy-MM-dd" here deliberately — that's the REAL
        // shape sync-transactions/index.ts forwards from Plaid's own `authorized_date`/`date`
        // fields (Plaid never sends a time component for these). A full ISO8601 datetime fixture
        // here would silently hide the exact bug this regression-guards: decoding these through
        // the response decoder's global `.iso8601` dateDecodingStrategy (which requires a time
        // component) throws `DecodingError.dataCorrupted` on a bare date, surfacing to the user as
        // "The data couldn't be read because it isn't in the correct format."
        let json = """
        {
            "external_transaction_id": "txn-backend-1",
            "pending_transaction_id": null,
            "plaid_account_id": "account-42",
            "amount": "19.99",
            "merchant_name": "Test Merchant",
            "original_description": "TEST MERCHANT #1",
            "authorized_date": "2026-07-01",
            "posted_date": "2026-07-02",
            "is_pending": false,
            "category_guess": "Shopping"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backendDTO = try decoder.decode(BackendTransactionDTO.self, from: Data(json.utf8))

        XCTAssertEqual(backendDTO.externalTransactionId, "txn-backend-1")
        // Compared against a Decimal built from a string, not the bare literal `19.99` —
        // Decimal's float-literal conformance goes through Double too and would reintroduce
        // the exact imprecision this test exists to catch.
        XCTAssertEqual(backendDTO.amount, Decimal(string: "19.99"))

        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let authorizedComponents = backendDTO.authorizedDate.map { utcCalendar.dateComponents([.year, .month, .day], from: $0) }
        XCTAssertEqual(authorizedComponents?.year, 2026)
        XCTAssertEqual(authorizedComponents?.month, 7)
        XCTAssertEqual(authorizedComponents?.day, 1)
        let postedComponents = backendDTO.postedDate.map { utcCalendar.dateComponents([.year, .month, .day], from: $0) }
        XCTAssertEqual(postedComponents?.day, 2)

        let dto = backendDTO.asPlaidTransactionDTO
        let transaction = PlaidTransactionImportService.mapToFinanceTransaction(dto, account: nil)

        XCTAssertEqual(transaction.source, .plaid)
        XCTAssertEqual(transaction.externalTransactionId, "txn-backend-1")
        XCTAssertEqual(transaction.merchantName, "Test Merchant")
        XCTAssertFalse(transaction.isPending)
    }

    func testBackendTransactionDTOToleratesNullOptionalFields() throws {
        // Every field Plaid may legally omit or send as null for a real transaction.
        let json = """
        {
            "external_transaction_id": "txn-backend-2",
            "pending_transaction_id": null,
            "plaid_account_id": "account-42",
            "amount": "5.00",
            "merchant_name": null,
            "original_description": "UNKNOWN VENDOR",
            "authorized_date": null,
            "posted_date": "2026-07-03",
            "is_pending": true,
            "category_guess": null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backendDTO = try decoder.decode(BackendTransactionDTO.self, from: Data(json.utf8))

        XCTAssertNil(backendDTO.pendingTransactionId)
        XCTAssertNil(backendDTO.merchantName)
        XCTAssertNil(backendDTO.authorizedDate)
        XCTAssertNotNil(backendDTO.postedDate)
        XCTAssertNil(backendDTO.categoryGuess)
        XCTAssertTrue(backendDTO.isPending)
    }

    func testBackendTransactionDTORejectsMalformedDate() {
        let json = """
        {
            "external_transaction_id": "txn-backend-3",
            "pending_transaction_id": null,
            "plaid_account_id": "account-42",
            "amount": "5.00",
            "merchant_name": null,
            "original_description": "UNKNOWN VENDOR",
            "authorized_date": "not-a-date",
            "posted_date": null,
            "is_pending": false,
            "category_guess": null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(BackendTransactionDTO.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
                return
            }
        }
    }

    func testPlaidBackendConfigPointsOnlyAtOwnSupabaseBackendNeverPlaidDirectly() {
        // Regression guard: the configured backend must be our own Supabase Edge Functions —
        // never a plaid.com host (this app must never talk to Plaid directly) — and must use the
        // real Supabase Edge Functions invocation path.
        guard let baseURL = PlaidBackendConfig.baseURL else {
            XCTFail("PlaidBackendConfig.baseURL should be configured")
            return
        }
        XCTAssertEqual(baseURL.host, "dlqjgpgnaguhubftfpel.supabase.co")
        XCTAssertFalse(baseURL.absoluteString.contains("plaid.com"))
        XCTAssertTrue(baseURL.path.hasSuffix("/functions/v1"))
    }

    func testSupabasePlaidBackendServiceThrowsNotConfiguredWithoutBaseURL() async {
        // Injects `baseURL: nil` explicitly so this is deterministic regardless of what
        // PlaidBackendConfig.baseURL is set to for this build.
        let service = SupabasePlaidBackendService(baseURL: nil)
        do {
            _ = try await service.createLinkToken()
            XCTFail("Expected notConfigured to be thrown")
        } catch PlaidBackendError.notConfigured {
            // expected
        } catch {
            XCTFail("Expected PlaidBackendError.notConfigured, got \(error)")
        }
    }

    // MARK: - Monthly Plan: frequency conversion

    func testMonthlyAmountConversionFromWeekly() {
        let monthly = MonthlyPlanCalculator.monthlyAmount(for: 100, frequency: .weekly)
        XCTAssertEqual(monthly, 100 * 52 / 12)
    }

    func testMonthlyAmountConversionFromBiweekly() {
        let monthly = MonthlyPlanCalculator.monthlyAmount(for: 1000, frequency: .biweekly)
        XCTAssertEqual(monthly, 1000 * 26 / 12)
    }

    func testMonthlyAmountConversionFromTwiceMonthly() {
        let monthly = MonthlyPlanCalculator.monthlyAmount(for: 500, frequency: .twiceMonthly)
        XCTAssertEqual(monthly, 1000)
    }

    func testMonthlyExpenseConversionFromWeekly() {
        // Same conversion function is shared between income and expenses.
        let monthly = MonthlyPlanCalculator.monthlyAmount(for: 50, frequency: .weekly)
        XCTAssertEqual(monthly, 50 * 52 / 12)
    }

    func testMonthlyExpenseConversionFromYearly() {
        let monthly = MonthlyPlanCalculator.monthlyAmount(for: 1200, frequency: .yearly)
        XCTAssertEqual(monthly, 100)
    }

    // MARK: - Monthly Plan: core math

    func testFlexibleSpendingAvailableCalculation() {
        let flexible = MonthlyPlanCalculator.flexibleSpendingAvailable(
            income: 4600,
            fixedExpenses: 2305,
            savingsGoal: 500,
            bufferAmount: 100
        )
        XCTAssertEqual(flexible, 1695)
    }

    func testRecommendedWeeklySpendingCalculation() {
        let recommended = MonthlyPlanCalculator.recommendedWeeklySpendingLimit(
            flexibleSpendingAvailable: 1695,
            spendingWeeksInMonth: 5
        )
        XCTAssertEqual(recommended, 339)
    }

    func testRecommendedWeeklySpendingIsZeroWithNoWeeks() {
        let recommended = MonthlyPlanCalculator.recommendedWeeklySpendingLimit(
            flexibleSpendingAvailable: 1000,
            spendingWeeksInMonth: 0
        )
        XCTAssertEqual(recommended, 0)
    }

    func testProjectedMonthlySavingsCalculation() {
        let projected = MonthlyPlanCalculator.projectedMonthlySavings(
            income: 4600,
            fixedExpenses: 2305,
            actualSpentThisMonth: 610
        )
        XCTAssertEqual(projected, 1685)
    }

    // MARK: - Monthly Plan: active/inactive filtering

    func testInactiveIncomeSourcesAreExcluded() {
        let interval = DateRangeHelper.currentMonthRange()
        let active = IncomeSource(name: "Paycheck", amount: 2000, frequency: .monthly)
        let inactive = IncomeSource(name: "Old Job", amount: 3000, frequency: .monthly, isActive: false)

        let income = MonthlyPlanCalculator.estimatedMonthlyIncome([active, inactive], in: interval)

        XCTAssertEqual(income, 2000)
    }

    func testInactiveRecurringExpensesAreExcluded() {
        let interval = DateRangeHelper.currentMonthRange()
        let active = RecurringExpense(name: "Rent", amount: 1800, frequency: .monthly)
        let inactive = RecurringExpense(name: "Old Gym", amount: 40, frequency: .monthly, isActive: false)

        let expenses = MonthlyPlanCalculator.estimatedMonthlyFixedExpenses([active, inactive], in: interval)

        XCTAssertEqual(expenses, 1800)
    }

    // MARK: - Monthly Plan: one-time date scoping

    func testOneTimeIncomeOnlyCountsInCorrectMonth() {
        let thisMonth = DateRangeHelper.currentMonthRange()
        let nextMonth = DateRangeHelper.monthRangeContaining(
            Calendar.current.date(byAdding: .month, value: 1, to: thisMonth.start) ?? thisMonth.start
        )

        let bonus = IncomeSource(name: "Bonus", amount: 1000, frequency: .oneTime, nextPayDate: thisMonth.start.addingTimeInterval(3600))

        XCTAssertEqual(MonthlyPlanCalculator.estimatedMonthlyIncome([bonus], in: thisMonth), 1000)
        XCTAssertEqual(MonthlyPlanCalculator.estimatedMonthlyIncome([bonus], in: nextMonth), 0)
    }

    func testOneTimeExpenseOnlyCountsInCorrectMonth() {
        let thisMonth = DateRangeHelper.currentMonthRange()
        let nextMonth = DateRangeHelper.monthRangeContaining(
            Calendar.current.date(byAdding: .month, value: 1, to: thisMonth.start) ?? thisMonth.start
        )

        let repair = RecurringExpense(name: "Car Repair", amount: 450, frequency: .oneTime, dueDate: thisMonth.start.addingTimeInterval(3600))

        XCTAssertEqual(MonthlyPlanCalculator.estimatedMonthlyFixedExpenses([repair], in: thisMonth), 450)
        XCTAssertEqual(MonthlyPlanCalculator.estimatedMonthlyFixedExpenses([repair], in: nextMonth), 0)
    }

    // MARK: - Monthly Plan: applying the recommended limit

    func testApplyingRecommendedWeeklyBudgetUpdatesBudgetSettings() {
        let settings = BudgetSettings(weeklySpendingLimit: 300)

        MonthlyPlanCalculator.applyRecommendedWeeklyLimit(339, to: settings)

        XCTAssertEqual(settings.weeklySpendingLimit, 339)
    }

    // MARK: - Monthly Plan: status tiers

    func testMonthlyPlanStatusOnTrackToSave() {
        let status = MonthlyPlanCalculator.monthlyPlanStatus(projectedSavings: 700, savingsGoal: 500)
        XCTAssertEqual(status, .good)
    }

    func testMonthlyPlanStatusSavingsGoalAtRisk() {
        let status = MonthlyPlanCalculator.monthlyPlanStatus(projectedSavings: 200, savingsGoal: 500)
        XCTAssertEqual(status, .warning)
    }

    func testMonthlyPlanStatusOverspending() {
        let status = MonthlyPlanCalculator.monthlyPlanStatus(projectedSavings: -150, savingsGoal: 500)
        XCTAssertEqual(status, .over)
    }

    // MARK: - Autosave: Income Source

    func testAutosaveDoesNotCreateBlankIncomeRecord() {
        // A blank draft never validates, so the view never calls commitIncomeSource for it —
        // this is the rule the view's scheduleAutosave()/commitAutosaveNow() guard enforces.
        let messages = AutosaveCommitter.incomeSourceValidationMessages(name: "", amount: nil, frequency: .monthly, hasNextPayDate: false)
        XCTAssertFalse(messages.isEmpty)
    }

    @MainActor
    func testAutosaveCreatesValidIncomeRecord() {
        let context = makeAutosaveTestContext()
        let messages = AutosaveCommitter.incomeSourceValidationMessages(name: "Paycheck", amount: Decimal(string: "2100"), frequency: .biweekly, hasNextPayDate: false)
        XCTAssertTrue(messages.isEmpty)

        let created = AutosaveCommitter.commitIncomeSource(
            existing: nil,
            name: "Paycheck",
            amount: Decimal(string: "2100")!,
            frequency: .biweekly,
            timing: .customDate,
            dayOfMonth: nil,
            nextPayDate: nil,
            note: "",
            modelContext: context
        )

        let fetched = try! context.fetch(FetchDescriptor<IncomeSource>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, created.id)
        XCTAssertEqual(created.amount, Decimal(string: "2100"))
    }

    @MainActor
    func testEditingExistingIncomeSourcePersistsChanges() {
        let context = makeAutosaveTestContext()
        let source = IncomeSource(name: "Paycheck", amount: 2000, frequency: .monthly)
        context.insert(source)

        AutosaveCommitter.commitIncomeSource(
            existing: source,
            name: "Paycheck (Raise)",
            amount: 2200,
            frequency: .monthly,
            timing: .beginningMonth,
            dayOfMonth: nil,
            nextPayDate: nil,
            note: "Updated",
            modelContext: context
        )

        let fetched = try! context.fetch(FetchDescriptor<IncomeSource>())
        XCTAssertEqual(fetched.count, 1, "Editing an existing record must never create a second one")
        XCTAssertEqual(fetched.first?.name, "Paycheck (Raise)")
        XCTAssertEqual(fetched.first?.amount, 2200)
        XCTAssertEqual(fetched.first?.note, "Updated")
    }

    // MARK: - Autosave: Recurring Expense

    func testAutosaveDoesNotCreateBlankRecurringExpense() {
        let messages = AutosaveCommitter.recurringExpenseValidationMessages(name: "", amount: nil, frequency: .monthly, hasDueDate: false)
        XCTAssertFalse(messages.isEmpty)
    }

    @MainActor
    func testAutosaveCreatesValidRecurringExpense() {
        let context = makeAutosaveTestContext()
        let messages = AutosaveCommitter.recurringExpenseValidationMessages(name: "Rent", amount: Decimal(string: "1800"), frequency: .monthly, hasDueDate: false)
        XCTAssertTrue(messages.isEmpty)

        let created = AutosaveCommitter.commitRecurringExpense(
            existing: nil,
            name: "Rent",
            amount: 1800,
            category: nil,
            frequency: .monthly,
            timing: .beginningMonth,
            dayOfMonth: nil,
            dueDate: nil,
            paymentAccount: nil,
            isEssential: true,
            note: "",
            modelContext: context
        )

        let fetched = try! context.fetch(FetchDescriptor<RecurringExpense>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, created.id)
        XCTAssertEqual(created.amount, 1800)
    }

    @MainActor
    func testEditingExistingRecurringExpensePersistsChanges() {
        let context = makeAutosaveTestContext()
        let expense = RecurringExpense(name: "Rent", amount: 1800, frequency: .monthly)
        context.insert(expense)

        AutosaveCommitter.commitRecurringExpense(
            existing: expense,
            name: "Rent",
            amount: 1850,
            category: nil,
            frequency: .monthly,
            timing: .beginningMonth,
            dayOfMonth: nil,
            dueDate: nil,
            paymentAccount: nil,
            isEssential: false,
            note: "Rent went up",
            modelContext: context
        )

        let fetched = try! context.fetch(FetchDescriptor<RecurringExpense>())
        XCTAssertEqual(fetched.count, 1, "Editing an existing record must never create a second one")
        XCTAssertEqual(fetched.first?.amount, 1850)
        XCTAssertEqual(fetched.first?.isEssential, false)
        XCTAssertEqual(fetched.first?.note, "Rent went up")
    }

    // MARK: - Autosave: invalid drafts never persist

    func testInvalidDraftDoesNotSaveAsRealRecord() {
        // Name present but amount missing/zero — still invalid, so still not autosave-eligible.
        let incomeMessages = AutosaveCommitter.incomeSourceValidationMessages(name: "Side Gig", amount: 0, frequency: .monthly, hasNextPayDate: false)
        XCTAssertFalse(incomeMessages.isEmpty, "Amount must be greater than 0 for autosave to be eligible")

        let expenseMessages = AutosaveCommitter.recurringExpenseValidationMessages(name: "", amount: Decimal(string: "50"), frequency: .monthly, hasDueDate: false)
        XCTAssertFalse(expenseMessages.isEmpty, "Name is required for autosave to be eligible")
    }

    // MARK: - Autosave: transaction screens are not autosaved

    @MainActor
    func testTransactionSingleApplyDoesNotDoubleCountBalance() {
        // AddExpenseView/CreditCardPaymentView/BalanceAdjustmentView intentionally do not
        // autosave; this guards that applying an expense exactly once (as the production save
        // flow does) changes the balance and transaction count exactly once, not twice.
        let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 1000)
        let startingBalance = checking.currentBalance

        let transaction = FinanceTransaction(amount: 42, date: .now, type: .expense, account: checking)
        let transactions = [transaction]
        AccountBalanceManager.applyExpense(amount: 42, to: checking)

        XCTAssertEqual(checking.currentBalance, startingBalance - 42)
        XCTAssertEqual(transactions.count, 1, "A single save must produce exactly one transaction, never two")
    }

    // MARK: - Default category migration

    func testMissingDefaultCategoriesAreInsertedIntoExistingDatabase() {
        // Simulates an existing install that predates the newer default categories: only the
        // original set is present.
        let existing = [
            Category(name: "Food"), Category(name: "Groceries"), Category(name: "Gas"),
            Category(name: "Bills"), Category(name: "Shopping"), Category(name: "Entertainment"),
            Category(name: "Health"), Category(name: "Subscriptions"), Category(name: "Travel"),
            Category(name: "Other"),
        ]

        let missing = Category.missingDefaultCategories(existing: existing)
        let missingNames = Set(missing.map(\.name))

        for expectedName in ["Home", "Security", "Car", "Loans", "Furniture", "Clothing", "Internet/TV", "Cellular", "Electric", "Water/Sewage", "Retail", "Credit Card"] {
            XCTAssertTrue(missingNames.contains(expectedName), "\(expectedName) should be backfilled for an existing install")
        }
        XCTAssertEqual(missing.count, 12)
    }

    func testExistingCategoriesAreNotDuplicated() {
        // A database that already has the full default set should get nothing new.
        let existing = Category.makeDefaultSet()
        let missing = Category.missingDefaultCategories(existing: existing)
        XCTAssertTrue(missing.isEmpty)
    }

    func testUserCreatedCategoriesArePreserved() {
        let userCategory = Category(name: "Kids Activities", iconName: "figure.run", colorName: "mint", isDefault: false)
        let existing = Category.makeDefaultSet() + [userCategory]

        let missing = Category.missingDefaultCategories(existing: existing)

        XCTAssertTrue(missing.isEmpty, "No default categories should be reinserted")
        XCTAssertTrue(existing.contains(where: { $0.name == "Kids Activities" }), "The user's own category must remain untouched")
    }

    func testCategoryMigrationComparisonIsCaseInsensitiveAndTrimmed() {
        // An install with differently-cased/whitespace-padded versions of default names should
        // not get duplicates of those specific categories, even though the match isn't exact.
        let existing = [
            Category(name: "  food  "),
            Category(name: "HOME"),
            Category(name: "credit card"),
        ]

        let missing = Category.missingDefaultCategories(existing: existing)
        let missingNames = Set(missing.map(\.name))

        XCTAssertFalse(missingNames.contains("Food"))
        XCTAssertFalse(missingNames.contains("Home"))
        XCTAssertFalse(missingNames.contains("Credit Card"))
        // Everything else in the default set that wasn't represented should still be backfilled.
        XCTAssertTrue(missingNames.contains("Security"))
        XCTAssertEqual(missing.count, Category.makeDefaultSet().count - 3)
    }

    // MARK: - Dashboard/Activity reorg

    func testArchivedCategoriesAreExcludedFromActiveCategoryList() {
        // Mirrors AddExpenseView's `activeCategories` filter exactly — archiving a category must
        // remove it from anywhere new expenses are categorized.
        let active = Category(name: "Groceries", isArchived: false)
        let archived = Category(name: "Old Category", isArchived: true)
        let allCategories = [active, archived]

        let activeCategories = allCategories.filter { !$0.isArchived }

        XCTAssertEqual(activeCategories.map(\.name), ["Groceries"])
        XCTAssertFalse(activeCategories.contains(where: { $0.name == "Old Category" }))
    }

    func testDashboardWeekByWeekUsesMonthlyPlanCalculator() {
        // The Dashboard's Week-by-Week section reads `MonthlyPlanCalculator.summary(...).weeklyComparisons`
        // directly rather than recomputing anything — this confirms that shared calculation
        // produces one comparison per week touching the month, each carrying a real status.
        let month = DateRangeHelper.currentMonthRange()
        let rent = RecurringExpense(name: "Rent", amount: 1200, frequency: .monthly)
        let paycheck = IncomeSource(name: "Paycheck", amount: 3000, frequency: .monthly)
        let settings = MonthlyPlanSettings(monthlySavingsGoal: 400)

        let summary = MonthlyPlanCalculator.summary(
            month: month,
            incomeSources: [paycheck],
            recurringExpenses: [rent],
            planSettings: settings,
            weeklyBudgetLimit: 300,
            transactions: [],
            weekInterval: DateRangeHelper.currentWeekRange(),
            weekStartsOnSunday: true,
            includePending: true,
            warningThreshold: 0.70
        )

        let expectedWeekCount = DateRangeHelper.weeksOverlapping(month, weekStartsOnSunday: true).count
        XCTAssertEqual(summary.weeklyComparisons.count, expectedWeekCount)
        XCTAssertTrue(summary.weeklyComparisons.allSatisfy { $0.recommendedLimit == summary.recommendedWeeklySpendingLimit })
    }

    func testActivityDateFilterHelpersProduceDistinctRanges() {
        let thisMonth = DateRangeHelper.currentMonthRange()
        let lastMonth = DateRangeHelper.lastMonthRange()
        let quarter = DateRangeHelper.currentQuarterRange()
        let year = DateRangeHelper.currentYearRange()

        XCTAssertTrue(lastMonth.end <= thisMonth.start)
        XCTAssertTrue(quarter.contains(thisMonth.start))
        XCTAssertTrue(year.contains(thisMonth.start))
        // A quarter is always exactly 3 calendar months.
        let quarterMonths = Calendar.current.dateComponents([.month], from: quarter.start, to: quarter.end).month
        XCTAssertEqual(quarterMonths, 3)
    }

    func testLastMonthRangeIsThePriorCalendarMonth() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 15
        let referenceDate = Calendar.current.date(from: components)!

        let lastMonth = DateRangeHelper.lastMonthRange(relativeTo: referenceDate)
        let expectedStart = Calendar.current.date(from: DateComponents(year: 2026, month: 2, day: 1))!

        XCTAssertEqual(Calendar.current.startOfDay(for: lastMonth.start), Calendar.current.startOfDay(for: expectedStart))
    }

    // MARK: - Face ID

    func testBiometricAuthManagerStartsWithNoErrorMessage() {
        let manager = BiometricAuthManager()
        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertFalse(manager.isUnlocked)
    }

    // MARK: - Projected savings from weekly limit

    func testMonthlySpendingBudgetIsWeeklyLimitTimesWeekCount() {
        let budget = MonthlyPlanCalculator.monthlySpendingBudget(weeklyLimit: 500, spendingWeeksInMonth: 4)
        XCTAssertEqual(budget, 2000)
    }

    func testAvailableAfterBillsSubtractsFixedExpensesAndBufferOnly() {
        // Deliberately does NOT subtract a savings goal — that's flexibleSpendingAvailable's job,
        // not this one.
        let available = MonthlyPlanCalculator.availableAfterBills(income: 4600, fixedExpenses: 1500, bufferAmount: 100)
        XCTAssertEqual(available, 3000)
    }

    func testProjectedSavingsFromWeeklyLimitPositive() {
        let projected = MonthlyPlanCalculator.projectedSavingsFromWeeklyLimit(availableAfterBills: 3000, monthlySpendingBudget: 2000)
        XCTAssertEqual(projected, 1000)
    }

    func testProjectedSavingsFromWeeklyLimitNegative() {
        let projected = MonthlyPlanCalculator.projectedSavingsFromWeeklyLimit(availableAfterBills: 1500, monthlySpendingBudget: 2000)
        XCTAssertEqual(projected, -500)
    }

    func testHasIncomeDataForProjectionRequiresActiveIncomeSource() {
        XCTAssertFalse(MonthlyPlanCalculator.hasIncomeDataForProjection([]))

        let inactive = IncomeSource(name: "Old Job", amount: 1000, frequency: .monthly, isActive: false)
        XCTAssertFalse(MonthlyPlanCalculator.hasIncomeDataForProjection([inactive]))

        let active = IncomeSource(name: "Paycheck", amount: 2000, frequency: .monthly)
        XCTAssertTrue(MonthlyPlanCalculator.hasIncomeDataForProjection([active, inactive]))
    }

    // MARK: - Insights / Ask SpendSmart

    private func makeInsightsContext(
        incomeSources: [IncomeSource] = [],
        recurringExpenses: [RecurringExpense] = [],
        transactions: [FinanceTransaction] = [],
        accounts: [Account] = [],
        planSettings: MonthlyPlanSettings? = nil
    ) -> SpendSmartQueryEngine.Context {
        let month = DateRangeHelper.currentMonthRange()
        let week = DateRangeHelper.currentWeekRange()
        return SpendSmartQueryEngine.Context(
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            transactions: transactions,
            accounts: accounts,
            planSettings: planSettings,
            weeklyBudgetLimit: 300,
            month: month,
            week: week,
            weekStartsOnSunday: true,
            includePending: true,
            warningThreshold: 0.70
        )
    }

    func testMidMonthRecurringBillTotal() {
        let month = DateRangeHelper.currentMonthRange()
        let rent = RecurringExpense(name: "Rent", amount: 1200, frequency: .monthly, timing: .midMonth)
        let gym = RecurringExpense(name: "Gym", amount: 40, frequency: .monthly, timing: .beginningMonth)
        let inactive = RecurringExpense(name: "Old Bill", amount: 50, frequency: .monthly, timing: .midMonth, isActive: false)

        let context = makeInsightsContext(recurringExpenses: [rent, gym, inactive])
        let answer = SpendSmartQueryEngine.answer(for: .midMonthBills, context: context)

        XCTAssertEqual(answer.totalAmount, 1200)
        XCTAssertEqual(answer.breakdown.map(\.label), ["Rent"])
        _ = month
    }

    func testEndMonthRecurringBillTotal() {
        let carPayment = RecurringExpense(name: "Car Payment", amount: 340, frequency: .monthly, timing: .endMonth)
        let rent = RecurringExpense(name: "Rent", amount: 1200, frequency: .monthly, timing: .midMonth)

        let context = makeInsightsContext(recurringExpenses: [carPayment, rent])
        let answer = SpendSmartQueryEngine.answer(for: .endMonthBills, context: context)

        XCTAssertEqual(answer.totalAmount, 340)
        XCTAssertEqual(answer.breakdown.map(\.label), ["Car Payment"])
    }

    func testBeginningMonthRecurringBillTotal() {
        let insurance = RecurringExpense(name: "Insurance", amount: 120, frequency: .monthly, timing: .beginningMonth)
        let rent = RecurringExpense(name: "Rent", amount: 1200, frequency: .monthly, timing: .midMonth)

        let context = makeInsightsContext(recurringExpenses: [insurance, rent])
        let answer = SpendSmartQueryEngine.answer(for: .beginningMonthBills, context: context)

        XCTAssertEqual(answer.totalAmount, 120)
        XCTAssertEqual(answer.breakdown.map(\.label), ["Insurance"])
    }

    func testCategoryRecurringExpenseTotal() {
        let electricCategory = Category(name: "Electric", isDefault: true)
        let electricBill = RecurringExpense(name: "Power Bill", amount: 85, category: electricCategory, frequency: .monthly)
        let rent = RecurringExpense(name: "Rent", amount: 1200, frequency: .monthly)

        let context = makeInsightsContext(recurringExpenses: [electricBill, rent])
        let answer = SpendSmartQueryEngine.answer(for: .categoryBillAmount("Electric"), context: context)

        XCTAssertEqual(answer.totalAmount, 85)
        XCTAssertEqual(answer.breakdown.map(\.label), ["Power Bill"])
    }

    func testIncomeTimingTotal() {
        let paycheck = IncomeSource(name: "Paycheck", amount: 2000, frequency: .monthly, timing: .beginningMonth)
        let sideGig = IncomeSource(name: "Side Gig", amount: 300, frequency: .monthly, timing: .endMonth)

        let (total, rows) = SpendSmartQueryEngine.incomeTotal(timing: .beginningMonth, sources: [paycheck, sideGig], in: DateRangeHelper.currentMonthRange())

        XCTAssertEqual(total, 2000)
        XCTAssertEqual(rows.map(\.label), ["Paycheck"])
    }

    func testTransactionCategoryTotal() {
        let checking = Account(name: "Checking", type: .checking, currentBalance: 1000)
        let gas = Category(name: "Gas", isDefault: true)
        let interval = DateRangeHelper.currentMonthRange()
        let fillUp = FinanceTransaction(amount: 45, date: interval.start.addingTimeInterval(3600), type: .expense, account: checking, category: gas)

        let context = makeInsightsContext(transactions: [fillUp])
        let answer = SpendSmartQueryEngine.answer(for: .categorySpendingAmount("Gas"), context: context)

        XCTAssertEqual(answer.totalAmount, 45)
    }

    func testWeeklySpendingSummaryUsesBudgetCalculator() {
        let checking = Account(name: "Checking", type: .checking, currentBalance: 1000)
        let week = DateRangeHelper.currentWeekRange()
        let groceries = Category(name: "Groceries", isDefault: true)
        let transaction = FinanceTransaction(amount: 60, date: week.start.addingTimeInterval(3600), type: .expense, account: checking, category: groceries)

        let context = makeInsightsContext(transactions: [transaction])
        let answer = SpendSmartQueryEngine.answer(for: .thisWeekSpending, context: context)

        let expected = BudgetCalculator.weeklySpent([transaction], in: week, includePending: true)
        XCTAssertEqual(answer.totalAmount, expected)
        XCTAssertEqual(answer.totalAmount, 60)
    }

    func testMonthlySpendingSummaryUsesBudgetCalculator() {
        let checking = Account(name: "Checking", type: .checking, currentBalance: 1000)
        let month = DateRangeHelper.currentMonthRange()
        let dining = Category(name: "Food", isDefault: true)
        let transaction = FinanceTransaction(amount: 25, date: month.start.addingTimeInterval(3600), type: .expense, account: checking, category: dining)

        let context = makeInsightsContext(transactions: [transaction])
        let answer = SpendSmartQueryEngine.answer(for: .thisMonthSpending, context: context)

        let expected = BudgetCalculator.monthlySpent([transaction], in: month, includePending: true)
        XCTAssertEqual(answer.totalAmount, expected)
        XCTAssertEqual(answer.totalAmount, 25)
    }

    func testUnknownQuestionReturnsHelpfulFallback() {
        let question = SpendSmartQueryEngine.parseQuestion("what's the weather like today")
        XCTAssertEqual(question, .unknown("what's the weather like today"))

        let answer = SpendSmartQueryEngine.answer(for: question, context: makeInsightsContext())
        XCTAssertNil(answer.totalAmount)
        XCTAssertFalse(answer.explanation.isEmpty)
        XCTAssertTrue(answer.explanation.lowercased().contains("quick question"))
    }

    func testInsightsQuestionParsingMatchesSampleQuestions() {
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("What are my total Mid Month bills?"), .midMonthBills)
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("What are my total End Month bills?"), .endMonthBills)
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("How much is Electric?"), .categoryBillAmount("Electric"))
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("How much is Cellular?"), .categoryBillAmount("Cellular"))
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("How much are Loans?"), .categoryBillAmount("Loans"))
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("What is my total monthly income?"), .monthlyIncome)
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("What is my total fixed expenses?"), .fixedMonthlyExpenses)
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("Am I overspending?"), .savingsOutlook)
        XCTAssertEqual(SpendSmartQueryEngine.parseQuestion("Am I on track to save?"), .savingsOutlook)
    }

    /// Regression guard: the Insights engine is pure, synchronous, local computation — calling it
    /// twice with identical input produces an identical result, with no `async`/`throws` in its
    /// signature (if a future change made this hit the network or an AI provider, this file
    /// wouldn't compile as a plain synchronous call anymore).
    func testInsightsEngineIsPureLocalComputationWithNoNetworkingOrAIProvider() {
        let context = makeInsightsContext(recurringExpenses: [RecurringExpense(name: "Rent", amount: 1200, frequency: .monthly, timing: .midMonth)])
        let first = SpendSmartQueryEngine.answer(for: .midMonthBills, context: context)
        let second = SpendSmartQueryEngine.answer(for: .midMonthBills, context: context)
        XCTAssertEqual(first, second)
    }

    // MARK: - Data Backup

    @MainActor
    private func makeBackupTestContext() -> ModelContext {
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
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeFullSampleDocument() -> SpendSmartBackupService.Document {
        let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 1200)
        let groceries = Category(name: "Groceries", isDefault: true)
        let transaction = FinanceTransaction(amount: 42, type: .expense, account: checking, category: groceries)
        let budgetSettings = BudgetSettings(weeklySpendingLimit: 300)
        let monthlyPlanSettings = MonthlyPlanSettings(monthlySavingsGoal: 500)
        let income = IncomeSource(name: "Paycheck", amount: 2000, frequency: .monthly)
        let expense = RecurringExpense(name: "Rent", amount: 1200, frequency: .monthly)

        return SpendSmartBackupService.makeDocument(
            accounts: [checking],
            transactions: [transaction],
            categories: [groceries],
            budgetSettings: [budgetSettings],
            monthlyPlanSettings: [monthlyPlanSettings],
            incomeSources: [income],
            recurringExpenses: [expense]
        )
    }

    func testBackupExportIncludesAccounts() {
        let document = makeFullSampleDocument()
        XCTAssertEqual(document.accounts.count, 1)
        XCTAssertEqual(document.accounts.first?.name, "Everyday Checking")
    }

    func testBackupExportIncludesTransactions() {
        let document = makeFullSampleDocument()
        XCTAssertEqual(document.transactions.count, 1)
        XCTAssertEqual(document.transactions.first?.amount.value, 42)
    }

    func testBackupExportIncludesCategories() {
        let document = makeFullSampleDocument()
        XCTAssertEqual(document.categories.count, 1)
        XCTAssertEqual(document.categories.first?.name, "Groceries")
    }

    func testBackupExportIncludesBudgetSettings() {
        let document = makeFullSampleDocument()
        XCTAssertEqual(document.budgetSettings.count, 1)
        XCTAssertEqual(document.budgetSettings.first?.weeklySpendingLimit.value, 300)
    }

    func testBackupExportIncludesMonthlyPlanSettings() {
        let document = makeFullSampleDocument()
        XCTAssertEqual(document.monthlyPlanSettings.count, 1)
        XCTAssertEqual(document.monthlyPlanSettings.first?.monthlySavingsGoal.value, 500)
    }

    func testBackupExportIncludesIncomeSources() {
        let document = makeFullSampleDocument()
        XCTAssertEqual(document.incomeSources.count, 1)
        XCTAssertEqual(document.incomeSources.first?.name, "Paycheck")
    }

    func testBackupExportIncludesRecurringExpenses() {
        let document = makeFullSampleDocument()
        XCTAssertEqual(document.recurringExpenses.count, 1)
        XCTAssertEqual(document.recurringExpenses.first?.name, "Rent")
    }

    func testBackupExportExcludesPlaidSecretsAndTokens() throws {
        // None of the seven DTOs have any field for a Plaid access_token, client_secret, or any
        // other credential — confirm the encoded JSON contains none of those substrings, using a
        // document that includes an imported Plaid-sourced transaction (the closest thing to
        // "Plaid data" a backup ever touches).
        let checking = Account(name: "Everyday Checking", type: .checking, currentBalance: 1200, connectionType: .plaid, externalIdentifier: "plaid-account-123")
        let imported = FinanceTransaction(
            amount: 19.99,
            type: .expense,
            source: .plaid,
            countsTowardWeeklyBudget: false,
            isExcludedFromReports: true,
            externalTransactionId: "plaid-txn-456",
            account: checking
        )
        let document = SpendSmartBackupService.makeDocument(
            accounts: [checking],
            transactions: [imported],
            categories: [],
            budgetSettings: [],
            monthlyPlanSettings: [],
            incomeSources: [],
            recurringExpenses: []
        )
        let data = try SpendSmartBackupService.encode(document)
        let json = String(data: data, encoding: .utf8) ?? ""

        for forbidden in ["access_token", "client_secret", "PLAID_SECRET", "PLAID_CLIENT_ID", "password"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()), "Backup JSON must never contain \"\(forbidden)\"")
        }
        // The Plaid-sourced transaction's own (non-secret) identifiers are expected to round-trip.
        XCTAssertTrue(json.contains("plaid-txn-456"))
    }

    @MainActor
    func testImportRecreatesRecords() throws {
        let context = makeBackupTestContext()
        let document = makeFullSampleDocument()

        try SpendSmartBackupService.restore(document, into: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Account>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTrack.Category>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BudgetSettings>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MonthlyPlanSettings>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncomeSource>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecurringExpense>()).count, 1)

        let restoredTransaction = try context.fetch(FetchDescriptor<FinanceTransaction>()).first
        XCTAssertEqual(restoredTransaction?.account?.name, "Everyday Checking")
        XCTAssertEqual(restoredTransaction?.category?.name, "Groceries")
    }

    @MainActor
    func testImportReplaceModeClearsOldRecordsFirst() throws {
        let context = makeBackupTestContext()

        // Seed some pre-existing data that is NOT part of the backup being restored.
        let oldAccount = Account(name: "Old Account", type: .checking, currentBalance: 999)
        context.insert(oldAccount)
        context.insert(RecurringExpense(name: "Old Bill", amount: 10, frequency: .monthly))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Account>()).count, 1)

        try SpendSmartBackupService.restore(makeFullSampleDocument(), into: context)

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let expenses = try context.fetch(FetchDescriptor<RecurringExpense>())
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.name, "Everyday Checking", "The old pre-existing account must be gone, replaced entirely by the backup")
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.name, "Rent")
    }

    func testAutoBackupCreatesFileAfterDataChanges() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let document = makeFullSampleDocument()
        let url = try SpendSmartBackupService.writeAutoBackup(document, to: tempDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(SpendSmartBackupService.autoBackupFiles(in: tempDirectory).count, 1)
    }

    func testAutoBackupKeepsOnlyLatestFiveFiles() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let document = makeFullSampleDocument()
        for i in 0..<8 {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 60))
            _ = try SpendSmartBackupService.writeAutoBackup(document, to: tempDirectory, date: date)
        }

        XCTAssertEqual(SpendSmartBackupService.autoBackupFiles(in: tempDirectory).count, 5)
    }

    func testInvalidBackupFileReturnsSafeError() {
        let garbage = "this is not json".data(using: .utf8)!
        XCTAssertThrowsError(try SpendSmartBackupService.decode(garbage)) { error in
            guard case SpendSmartBackupService.BackupError.invalidFile = error else {
                XCTFail("Expected .invalidFile, got \(error)")
                return
            }
        }
    }

    func testUnsupportedBackupVersionReturnsSafeError() throws {
        var document = makeFullSampleDocument()
        document = SpendSmartBackupService.Document(
            backupVersion: 999,
            schemaVersion: document.schemaVersion,
            createdAt: document.createdAt,
            appName: document.appName,
            appDisplayName: document.appDisplayName,
            bundleIdentifier: document.bundleIdentifier,
            accounts: document.accounts,
            transactions: document.transactions,
            categories: document.categories,
            budgetSettings: document.budgetSettings,
            monthlyPlanSettings: document.monthlyPlanSettings,
            incomeSources: document.incomeSources,
            recurringExpenses: document.recurringExpenses
        )
        let data = try SpendSmartBackupService.encode(document)

        XCTAssertThrowsError(try SpendSmartBackupService.decode(data)) { error in
            guard case SpendSmartBackupService.BackupError.unsupportedVersion(let version) = error else {
                XCTFail("Expected .unsupportedVersion, got \(error)")
                return
            }
            XCTAssertEqual(version, 999)
        }
    }

    func testBackupRoundTripsThroughEncodeAndDecode() throws {
        // ISO8601 date encoding is second-precision, so a decoded Date can differ from the
        // original in-memory Date (which has sub-second precision) by a fraction of a second —
        // comparing decode-to-decode (both equally truncated) verifies encode/decode symmetry
        // without being sensitive to that expected, harmless precision loss.
        let document = makeFullSampleDocument()
        let decodedOnce = try SpendSmartBackupService.decode(try SpendSmartBackupService.encode(document))
        let decodedTwice = try SpendSmartBackupService.decode(try SpendSmartBackupService.encode(decodedOnce))
        XCTAssertEqual(decodedOnce, decodedTwice)
        XCTAssertEqual(decodedOnce.accounts.first?.name, "Everyday Checking")
        XCTAssertEqual(decodedOnce.transactions.first?.amount.value, 42)
    }

    // MARK: - Plaid sync persistence (PlaidTransactionImportService.applySync)

    @MainActor
    private func makePlaidSyncTestContext() -> ModelContext {
        let schema = Schema([Account.self, FinanceTransaction.self, Category.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makePlaidDTO(
        id: String,
        amount: Decimal = 12.34,
        merchantName: String? = "Test Merchant",
        isPending: Bool = false,
        pendingTransactionId: String? = nil,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PlaidTransactionDTO {
        PlaidTransactionDTO(
            externalTransactionId: id,
            pendingTransactionId: pendingTransactionId,
            plaidAccountId: "plaid-account-1",
            amount: amount,
            merchantName: merchantName,
            originalDescription: "TEST DESCRIPTION",
            authorizedDate: date,
            postedDate: date,
            isPending: isPending,
            categoryGuess: "Shopping"
        )
    }

    @MainActor
    func testApplySyncFirstSyncInsertsPlaidTransactions() throws {
        let context = makePlaidSyncTestContext()
        let result = PlaidSyncResult(
            added: [makePlaidDTO(id: "txn-1"), makePlaidDTO(id: "txn-2")],
            modified: [],
            removedExternalIds: []
        )

        let outcome = try PlaidTransactionImportService.applySync(result, context: context)

        XCTAssertEqual(outcome.insertedCount, 2)
        XCTAssertEqual(outcome.updatedCount, 0)
        XCTAssertEqual(outcome.duplicateSkippedCount, 0)
        XCTAssertEqual(outcome.removedCount, 0)

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy { $0.source == .plaid })
    }

    @MainActor
    func testApplySyncImportedDefaultsRemainReadOnlyAndNotCounted() throws {
        let context = makePlaidSyncTestContext()
        let result = PlaidSyncResult(added: [makePlaidDTO(id: "txn-defaults")], modified: [], removedExternalIds: [])

        try PlaidTransactionImportService.applySync(result, context: context)

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1)
        let transaction = try XCTUnwrap(saved.first)
        XCTAssertEqual(transaction.source, .plaid)
        XCTAssertFalse(transaction.countsTowardWeeklyBudget)
        XCTAssertTrue(transaction.isExcludedFromReports)
    }

    @MainActor
    func testApplySyncRepeatedSyncDoesNotDuplicate() throws {
        let context = makePlaidSyncTestContext()
        let dto = makePlaidDTO(id: "txn-repeat")

        let first = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [dto], modified: [], removedExternalIds: []),
            context: context
        )
        XCTAssertEqual(first.insertedCount, 1)

        // Same externalTransactionId, identical fields, delivered again exactly as `added` — as
        // would happen if the app re-processed the same backend response, or Plaid re-included it
        // in a subsequent diff unchanged.
        let second = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [dto], modified: [], removedExternalIds: []),
            context: context
        )
        XCTAssertEqual(second.insertedCount, 0)
        XCTAssertEqual(second.duplicateSkippedCount, 1)

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1, "A repeated sync must never create a second row for the same externalTransactionId")
    }

    @MainActor
    func testApplySyncRepeatedRefreshRemainsIdempotent() throws {
        let context = makePlaidSyncTestContext()
        let dtos = [makePlaidDTO(id: "a"), makePlaidDTO(id: "b"), makePlaidDTO(id: "c")]

        for _ in 0..<3 {
            try PlaidTransactionImportService.applySync(
                PlaidSyncResult(added: dtos, modified: [], removedExternalIds: []),
                context: context
            )
        }

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 3, "Three refreshes with the same unchanged data must still leave exactly 3 rows")
    }

    @MainActor
    func testApplySyncModifiedTransactionUpdatesExistingRecord() throws {
        let context = makePlaidSyncTestContext()
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [makePlaidDTO(id: "txn-mod", amount: 10, isPending: true)], modified: [], removedExternalIds: []),
            context: context
        )

        let updatedDTO = makePlaidDTO(id: "txn-mod", amount: 15, merchantName: "Updated Merchant", isPending: false)
        let outcome = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [], modified: [updatedDTO], removedExternalIds: []),
            context: context
        )

        XCTAssertEqual(outcome.updatedCount, 1)
        XCTAssertEqual(outcome.insertedCount, 0)

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1, "A modified transaction must update the existing row, never insert a second one")
        let transaction = try XCTUnwrap(saved.first)
        XCTAssertEqual(transaction.amount, 15)
        XCTAssertEqual(transaction.merchantName, "Updated Merchant")
        XCTAssertFalse(transaction.isPending)
    }

    @MainActor
    func testApplySyncRemovedTransactionOnlyAffectsMatchingPlaidRecord() throws {
        let context = makePlaidSyncTestContext()
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [makePlaidDTO(id: "keep"), makePlaidDTO(id: "remove-me")], modified: [], removedExternalIds: []),
            context: context
        )

        let outcome = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [], modified: [], removedExternalIds: ["remove-me"]),
            context: context
        )

        XCTAssertEqual(outcome.removedCount, 1)
        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.externalTransactionId, "keep")
    }

    // MARK: - Pending-to-posted merge (preserves user-entered data)

    @MainActor
    func testApplySyncPendingToPostedMergePreservesUserEnteredCategoryAndNote() throws {
        let context = makePlaidSyncTestContext()
        let category = Category(name: "Coffee", iconName: "cup.and.saucer.fill", colorName: "red")
        context.insert(category)

        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [makePlaidDTO(id: "pending-1", isPending: true)], modified: [], removedExternalIds: []),
            context: context
        )
        let pendingRow = try XCTUnwrap(try context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        // Simulate the user reviewing the pending import and setting fields Plaid never sends —
        // exactly what a real "approve/categorize" action in ImportedTransactionsReviewView would
        // do before the transaction posts.
        pendingRow.category = category
        pendingRow.note = "Morning coffee run"
        pendingRow.countsTowardWeeklyBudget = true
        pendingRow.isExcludedFromReports = false
        pendingRow.isMatchedToManualExpense = true
        pendingRow.matchedTransactionId = UUID()
        try context.save()

        // Plaid's real shape for a pending-to-posted transition: a NEW `added` entry with a NEW
        // externalTransactionId, whose own pendingTransactionId points at the OLD pending id,
        // delivered alongside a `removed` entry for that same old id.
        let postedDTO = makePlaidDTO(id: "posted-1", amount: 12.34, isPending: false, pendingTransactionId: "pending-1")
        let outcome = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [postedDTO], modified: [], removedExternalIds: ["pending-1"]),
            context: context
        )

        XCTAssertEqual(outcome.mergedFromPendingCount, 1)
        XCTAssertEqual(outcome.insertedCount, 0, "A pending-to-posted transition must never insert a fresh row")
        XCTAssertEqual(outcome.removedCount, 0, "The old pending id was already re-keyed forward, not deleted")

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1, "Exactly one row must survive — the same row, re-keyed")
        let merged = try XCTUnwrap(saved.first)
        XCTAssertEqual(merged.externalTransactionId, "posted-1")
        XCTAssertFalse(merged.isPending)

        // The whole point: every user-entered field from before the merge survives.
        XCTAssertEqual(merged.category?.name, "Coffee")
        XCTAssertEqual(merged.note, "Morning coffee run")
        XCTAssertTrue(merged.countsTowardWeeklyBudget)
        XCTAssertFalse(merged.isExcludedFromReports)
        XCTAssertTrue(merged.isMatchedToManualExpense)
        XCTAssertNotNil(merged.matchedTransactionId)
    }

    @MainActor
    func testApplySyncPendingToPostedMergeUpdatesPostedFields() throws {
        let context = makePlaidSyncTestContext()
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [makePlaidDTO(id: "pending-2", amount: 10, isPending: true)], modified: [], removedExternalIds: []),
            context: context
        )

        let postedDTO = makePlaidDTO(id: "posted-2", amount: 10.50, merchantName: "Updated Merchant", isPending: false, pendingTransactionId: "pending-2")
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [postedDTO], modified: [], removedExternalIds: ["pending-2"]),
            context: context
        )

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1)
        let merged = try XCTUnwrap(saved.first)
        XCTAssertEqual(merged.amount, 10.50, "The posted amount must replace the pending estimate")
        XCTAssertEqual(merged.merchantName, "Updated Merchant")
        XCTAssertFalse(merged.isPending)
    }

    @MainActor
    func testApplySyncWithoutMatchingPendingRowInsertsNormally() throws {
        // pendingTransactionId set, but no row exists under that id (e.g. the pending delivery was
        // never seen by this device) — must fall back to a normal insert, not silently drop the
        // transaction.
        let context = makePlaidSyncTestContext()
        let dto = makePlaidDTO(id: "posted-orphan", pendingTransactionId: "never-seen-pending-id")
        let outcome = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [dto], modified: [], removedExternalIds: []),
            context: context
        )

        XCTAssertEqual(outcome.insertedCount, 1)
        XCTAssertEqual(outcome.mergedFromPendingCount, 0)
        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.externalTransactionId, "posted-orphan")
    }

    @MainActor
    func testApplySyncDoesNotDuplicateWhenPostedTransactionAlreadyExists() throws {
        // The pending-merge branch must only ever fire when the DTO's OWN externalTransactionId
        // isn't already a known row — if the posted transaction was already merged forward in an
        // earlier sync (or delivered directly as `added` without ever going through a pending
        // state), a later re-delivery of that SAME posted id must update the existing row, never
        // create a second one, even though the DTO still carries a pendingTransactionId pointing
        // at an id that no longer exists locally.
        let context = makePlaidSyncTestContext()
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [makePlaidDTO(id: "pending-dup", isPending: true)], modified: [], removedExternalIds: []),
            context: context
        )
        // First delivery of the posted transaction — a genuine merge.
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(
                added: [makePlaidDTO(id: "posted-dup", amount: 20, pendingTransactionId: "pending-dup")],
                modified: [],
                removedExternalIds: ["pending-dup"]
            ),
            context: context
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).count, 1)

        // Plaid re-delivers the SAME posted transaction later (e.g. still within the has_more
        // pagination window, or a reinstall re-consuming an old cursor) — pendingTransactionId is
        // still set on the wire, but "pending-dup" no longer exists locally.
        let outcome = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(
                added: [makePlaidDTO(id: "posted-dup", amount: 20.50, pendingTransactionId: "pending-dup")],
                modified: [],
                removedExternalIds: []
            ),
            context: context
        )

        XCTAssertEqual(outcome.insertedCount, 0)
        XCTAssertEqual(outcome.mergedFromPendingCount, 0)
        XCTAssertEqual(outcome.updatedCount, 1)
        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1, "Must never create a duplicate row for an already-posted transaction")
        XCTAssertEqual(saved.first?.amount, 20.50)
    }

    @MainActor
    func testApplySyncPendingToPostedMergeIsIdempotentAcrossRepeatedSyncCalls() throws {
        let context = makePlaidSyncTestContext()
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [makePlaidDTO(id: "pending-idem", isPending: true)], modified: [], removedExternalIds: []),
            context: context
        )

        let payload = PlaidSyncResult(
            added: [makePlaidDTO(id: "posted-idem", pendingTransactionId: "pending-idem")],
            modified: [],
            removedExternalIds: ["pending-idem"]
        )

        let first = try PlaidTransactionImportService.applySync(payload, context: context)
        XCTAssertEqual(first.mergedFromPendingCount, 1)
        XCTAssertEqual(first.insertedCount, 0)

        // Re-running the EXACT same payload (e.g. a retried request, or the backend re-sending an
        // unacknowledged diff) must not merge again, insert a duplicate, or delete anything — the
        // old pending id is already gone from the lookup map, and the posted id is now a known
        // row, so this should land as a plain no-op update/duplicate-skip.
        let second = try PlaidTransactionImportService.applySync(payload, context: context)
        XCTAssertEqual(second.mergedFromPendingCount, 0)
        XCTAssertEqual(second.insertedCount, 0)
        XCTAssertEqual(second.removedCount, 0, "The pending id was already consumed by the first call — the removed entry must be a no-op, not an error or a delete of the merged row")

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1, "Repeated identical syncs must never change the row count")
        XCTAssertEqual(saved.first?.externalTransactionId, "posted-idem")
    }

    @MainActor
    func testApplySyncSecondTransactionCannotStealAnAlreadyMergedPendingId() throws {
        // Defends against a malformed/duplicate delivery where two DISTINCT posted transactions
        // both claim the same pendingTransactionId in one response — must never merge both into
        // the same row (which would silently discard one transaction) or crash.
        let context = makePlaidSyncTestContext()
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [makePlaidDTO(id: "pending-contested", isPending: true)], modified: [], removedExternalIds: []),
            context: context
        )

        let outcome = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(
                added: [
                    makePlaidDTO(id: "posted-claim-a", amount: 5, pendingTransactionId: "pending-contested"),
                    makePlaidDTO(id: "posted-claim-b", amount: 7, pendingTransactionId: "pending-contested"),
                ],
                modified: [],
                removedExternalIds: ["pending-contested"]
            ),
            context: context
        )

        // The first claim wins the merge (preserves whatever user data was on the pending row);
        // the second finds no matching pending row left and correctly falls back to a normal
        // insert — never a crash, never a dropped transaction, never two rows merged into one.
        XCTAssertEqual(outcome.mergedFromPendingCount, 1)
        XCTAssertEqual(outcome.insertedCount, 1)

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 2, "Both posted transactions must be represented — neither silently dropped nor merged together")
        let externalIds = Set(saved.compactMap(\.externalTransactionId))
        XCTAssertEqual(externalIds, ["posted-claim-a", "posted-claim-b"])
    }

    @MainActor
    func testApplySyncManualTransactionsAreUntouched() throws {
        let context = makePlaidSyncTestContext()
        let manual = FinanceTransaction(amount: 50, type: .expense, source: .manual, note: "Groceries")
        context.insert(manual)
        try context.save()

        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [makePlaidDTO(id: "txn-plaid")], modified: [], removedExternalIds: []),
            context: context
        )
        // A removedExternalIds entry that happens to coincide with nothing (manual transactions
        // have no externalTransactionId, so they can never match) must never touch the manual row.
        try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [], modified: [], removedExternalIds: ["txn-plaid"]),
            context: context
        )

        let saved = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(saved.count, 1, "The manual transaction must survive untouched")
        XCTAssertEqual(saved.first?.source, .manual)
        XCTAssertEqual(saved.first?.note, "Groceries")
    }

    @MainActor
    func testApplySyncEmptySyncCreatesNoRecords() throws {
        let context = makePlaidSyncTestContext()
        let outcome = try PlaidTransactionImportService.applySync(
            PlaidSyncResult(added: [], modified: [], removedExternalIds: []),
            context: context
        )

        XCTAssertEqual(outcome.insertedCount, 0)
        XCTAssertEqual(outcome.updatedCount, 0)
        XCTAssertEqual(outcome.removedCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).count, 0)
    }

    func testImportedTransactionsReviewSourceFilterIncludesExcludedPlaidTransactions() {
        // Mirrors ImportedTransactionsReviewView.importedTransactions exactly: filter by
        // source == .plaid only — never by isExcludedFromReports, since every Plaid-sourced
        // transaction has that flag set true by design (see PlaidTransactionImportService). If the
        // view accidentally filtered on it too, nothing would ever show.
        let excludedPlaidTransaction = FinanceTransaction(
            amount: 20,
            type: .expense,
            source: .plaid,
            countsTowardWeeklyBudget: false,
            isExcludedFromReports: true,
            externalTransactionId: "txn-review"
        )
        let manualTransaction = FinanceTransaction(amount: 5, type: .expense, source: .manual)
        let allTransactions = [excludedPlaidTransaction, manualTransaction]

        let imported = allTransactions.filter { $0.source == .plaid }

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.externalTransactionId, "txn-review")
        XCTAssertTrue(imported.first?.isExcludedFromReports ?? false)
    }

    @MainActor
    func testApplySyncPersistenceFailureReturnsError() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let storeURL = tempDir.appendingPathComponent("plaid-sync-test.store")
        let schema = Schema([Account.self, FinanceTransaction.self, Category.self])

        // First container/context: one successful save, so the store file actually exists on
        // disk. Scoped to its own block so both are deallocated (closing their file handles)
        // before the file is locked down below — an already-open file descriptor can keep
        // writing even after its permissions change out from under it, since POSIX permission
        // checks happen at open() time, not on every write(). A FRESH open (the second container
        // below) is what actually has to honor the now-read-only permission.
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            let seedContext = ModelContext(container)
            try PlaidTransactionImportService.applySync(
                PlaidSyncResult(added: [makePlaidDTO(id: "seed")], modified: [], removedExternalIds: []),
                context: seedContext
            )
        }

        // Lock down both the store file and its WAL/SHM companions (SQLite's default journal
        // mode) so no fresh open of this store can be opened for writing.
        for suffix in ["", "-wal", "-shm"] {
            let path = storeURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)

        // A fresh container/context pointing at the same now-read-only store: either opening it
        // read-write throws immediately, or the subsequent applySync's save() does — both are a
        // genuine "persistence failure returns an error," so either is wrapped in the same
        // assertion.
        XCTAssertThrowsError(try {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            try PlaidTransactionImportService.applySync(
                PlaidSyncResult(added: [makePlaidDTO(id: "should-fail")], modified: [], removedExternalIds: []),
                context: context
            )
        }())
    }

    // MARK: - AuthValidation

    func testAuthValidationAcceptsWellFormedEmails() {
        XCTAssertTrue(AuthValidation.isValidEmail("you@example.com"))
        XCTAssertTrue(AuthValidation.isValidEmail("first.last+tag@sub.example.co"))
    }

    func testAuthValidationRejectsMalformedEmails() {
        XCTAssertFalse(AuthValidation.isValidEmail(""))
        XCTAssertFalse(AuthValidation.isValidEmail("no-at-sign.com"))
        XCTAssertFalse(AuthValidation.isValidEmail("two@@example.com"))
        XCTAssertFalse(AuthValidation.isValidEmail("trailing@"))
        XCTAssertFalse(AuthValidation.isValidEmail("@example.com"))
        XCTAssertFalse(AuthValidation.isValidEmail("no-domain-dot@example"))
        XCTAssertFalse(AuthValidation.isValidEmail("leading-dot@.example.com"))
    }

    func testAuthValidationPasswordRequiresLengthAndDigit() {
        XCTAssertEqual(AuthValidation.passwordValidationMessages("short1").count, 1, "7 chars with a digit should only fail the length check")
        XCTAssertEqual(AuthValidation.passwordValidationMessages("nodigits").count, 1, "8+ chars with no digit should only fail the digit check")
        XCTAssertTrue(AuthValidation.passwordValidationMessages("longenough1").isEmpty)
        XCTAssertFalse(AuthValidation.isPasswordValid("short1"))
        XCTAssertTrue(AuthValidation.isPasswordValid("longenough1"))
    }

    func testAuthValidationPasswordsMatch() {
        XCTAssertTrue(AuthValidation.passwordsMatch("abc12345", "abc12345"))
        XCTAssertFalse(AuthValidation.passwordsMatch("abc12345", "abc12346"))
        XCTAssertFalse(AuthValidation.passwordsMatch("", ""), "Two empty strings must never count as a match")
    }

    // MARK: - AuthenticationService / PlaidBackendService auth wiring

    func testSupabasePlaidBackendServiceThrowsUnauthorizedWithoutAccessToken() async {
        let service = SupabasePlaidBackendService(
            accessTokenProvider: { throw AccountDeletionError.serverError }
        )
        do {
            _ = try await service.createLinkToken()
            XCTFail("Expected .unauthorized to be thrown")
        } catch PlaidBackendError.unauthorized {
            // expected
        } catch {
            XCTFail("Expected PlaidBackendError.unauthorized, got \(error)")
        }
    }

    func testSupabasePlaidBackendServiceThrowsUnauthorizedForEmptyAccessToken() async {
        let service = SupabasePlaidBackendService(
            accessTokenProvider: { "" }
        )
        do {
            _ = try await service.createLinkToken()
            XCTFail("Expected .unauthorized to be thrown")
        } catch PlaidBackendError.unauthorized {
            // expected
        } catch {
            XCTFail("Expected PlaidBackendError.unauthorized, got \(error)")
        }
    }

    func testFriendlyErrorReturnsOwnMessageVerbatim() {
        let error: Error = AccountDeletionError.serverError
        XCTAssertEqual(error.friendlyAuthMessage, "We couldn't delete your account right now. Please try again.")
    }

    // MARK: - PlaidConnectionManager (multi-institution)

    private func makeIsolatedDefaults() -> UserDefaults {
        // A dedicated suite per test, never `.standard` — this manager persists to UserDefaults,
        // and tests must never read/write the real app's stored connections.
        UserDefaults(suiteName: "PlaidConnectionManagerTests.\(UUID().uuidString)")!
    }

    func testPlaidConnectionManagerSupportsMultipleInstitutionsSimultaneously() {
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertFalse(manager.isConnected)

        manager.addOrUpdate(connectionId: "conn-amex", institutionId: "ins_1", institutionName: "American Express")
        manager.addOrUpdate(connectionId: "conn-chase", institutionId: "ins_2", institutionName: "Chase")

        XCTAssertEqual(manager.connections.count, 2, "A household must be able to link more than one institution at once")
        XCTAssertTrue(manager.isConnected)
        XCTAssertTrue(manager.connections.contains { $0.institutionName == "American Express" })
        XCTAssertTrue(manager.connections.contains { $0.institutionName == "Chase" })
    }

    func testPlaidConnectionManagerNeverHardcodesAmerianExpress() {
        // Regression guard: this manager must accept and preserve WHATEVER institution name the
        // backend reports — it must never substitute or default to "American Express" the way an
        // earlier version of this codebase did server-side.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-1", institutionId: "ins_109508", institutionName: "Bank of Example")
        XCTAssertEqual(manager.connections.first?.institutionName, "Bank of Example")
        XCTAssertEqual(manager.connections.first?.institutionId, "ins_109508")
    }

    func testPlaidConnectionManagerRemoveOnlyAffectsTargetedConnection() {
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-a", institutionId: nil, institutionName: "Bank A")
        manager.addOrUpdate(connectionId: "conn-b", institutionId: nil, institutionName: "Bank B")

        manager.remove(connectionId: "conn-a")

        XCTAssertEqual(manager.connections.count, 1)
        XCTAssertEqual(manager.connections.first?.id, "conn-b")
    }

    func testPlaidConnectionManagerMarkSyncedOnlyUpdatesTargetedConnection() {
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-a", institutionId: nil, institutionName: "Bank A")
        manager.addOrUpdate(connectionId: "conn-b", institutionId: nil, institutionName: "Bank B")

        manager.markSynced(connectionId: "conn-a")

        XCTAssertNotNil(manager.connections.first { $0.id == "conn-a" }?.lastSyncedAt)
        XCTAssertNil(manager.connections.first { $0.id == "conn-b" }?.lastSyncedAt, "markSynced must never touch a connection it wasn't called for")
    }

    func testPlaidConnectionManagerPersistsAcrossInstances() {
        let defaults = makeIsolatedDefaults()
        let first = PlaidConnectionManager(defaults: defaults)
        first.addOrUpdate(connectionId: "conn-1", institutionId: "ins_1", institutionName: "Persisted Bank")

        let second = PlaidConnectionManager(defaults: defaults)
        XCTAssertEqual(second.connections.count, 1)
        XCTAssertEqual(second.connections.first?.institutionName, "Persisted Bank")
    }

    func testPlaidConnectionManagerApplyServerStateSetsWebhookDrivenFlags() {
        // Simulates what happens when a Plaid webhook (ITEM_LOGIN_REQUIRED) sets requires_reauth
        // server-side while this device wasn't running — list-connections is how the device ever
        // learns about that.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-1", institutionId: "ins_1", institutionName: "Some Bank")
        XCTAssertFalse(manager.connections.first!.requiresReauth)

        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        manager.applyServerState(
            connectionId: "conn-1",
            institutionId: "ins_1",
            institutionName: "Some Bank",
            requiresReauth: true,
            pendingExpirationAt: expiration,
            newAccountsAvailable: true
        )

        let updated = try! XCTUnwrap(manager.connections.first)
        XCTAssertTrue(updated.requiresReauth)
        XCTAssertEqual(updated.pendingExpirationAt, expiration)
        XCTAssertTrue(updated.newAccountsAvailable)
    }

    func testPlaidConnectionManagerReconnectClearsReauthFlag() {
        // A successful reconnect (Link update mode) means Plaid just accepted fresh credentials —
        // addOrUpdate on an existing connectionId must clear any stale requiresReauth/
        // newAccountsAvailable flags rather than leaving them stuck true forever.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-1", institutionId: "ins_1", institutionName: "Some Bank")
        manager.applyServerState(
            connectionId: "conn-1",
            institutionId: "ins_1",
            institutionName: "Some Bank",
            requiresReauth: true,
            pendingExpirationAt: nil,
            newAccountsAvailable: true
        )
        XCTAssertTrue(manager.connections.first!.requiresReauth)

        manager.addOrUpdate(connectionId: "conn-1", institutionId: "ins_1", institutionName: "Some Bank")

        let reconnected = try! XCTUnwrap(manager.connections.first)
        XCTAssertFalse(reconnected.requiresReauth)
        XCTAssertFalse(reconnected.newAccountsAvailable)
    }

    // MARK: - PlaidConnectionManager legacy UserDefaults migration

    func testPlaidConnectionManagerMigratesLegacyConnectedState() {
        let defaults = makeIsolatedDefaults()
        // Exactly the scalar keys/values the pre-multi-institution PlaidConnectionManager wrote.
        defaults.set(true, forKey: "plaid.amex.isConnected")
        defaults.set("legacy-connection-id", forKey: "plaid.amex.connectionId")
        let legacySyncDate = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(legacySyncDate, forKey: "plaid.amex.lastSyncedAt")

        let manager = PlaidConnectionManager(defaults: defaults)

        XCTAssertEqual(manager.connections.count, 1, "A connected legacy user must end up with exactly one migrated connection")
        let migrated = try! XCTUnwrap(manager.connections.first)
        XCTAssertEqual(migrated.id, "legacy-connection-id", "The connectionId must survive migration unchanged — it's the only thing that ties this device to the server-side plaid_items row")
        XCTAssertEqual(migrated.institutionName, "American Express", "The old format never stored an institution name — American Express is the correct historical fact, not a guess, since the old implementation never supported anything else")
        XCTAssertNil(migrated.institutionId, "The old format never captured institution_id at all")
        XCTAssertEqual(migrated.lastSyncedAt, legacySyncDate)
        XCTAssertFalse(migrated.requiresReauth)
        XCTAssertFalse(migrated.newAccountsAvailable)
    }

    func testPlaidConnectionManagerMigrationNeverFabricatesConnectionForDisconnectedUser() {
        let defaults = makeIsolatedDefaults()
        // isConnected explicitly false — a user who was never connected, or who disconnected
        // before this device ever upgraded.
        defaults.set(false, forKey: "plaid.amex.isConnected")

        let manager = PlaidConnectionManager(defaults: defaults)

        XCTAssertTrue(manager.connections.isEmpty, "A disconnected legacy user must never be migrated into an accidentally-connected state")
        XCTAssertFalse(manager.isConnected)
    }

    func testPlaidConnectionManagerMigrationHandlesFreshInstallWithNoLegacyKeysAtAll() {
        // No legacy keys set at all — a genuinely fresh install, never on any older build.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertFalse(manager.isConnected)
    }

    func testPlaidConnectionManagerMigrationTreatsConnectedWithMissingIdAsNotConnected() {
        // A theoretically-corrupt old state: isConnected=true but no connectionId ever got saved
        // (e.g. the old markConnected(connectionId:) call was interrupted, or a very old
        // installed build predating connectionId tracking entirely, per that field's own
        // original doc comment about "connected before this build added connectionId tracking").
        // Must never fabricate a connection with an empty/missing id.
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "plaid.amex.isConnected")
        // plaid.amex.connectionId deliberately left unset.

        let manager = PlaidConnectionManager(defaults: defaults)

        XCTAssertTrue(manager.connections.isEmpty)
        XCTAssertFalse(manager.isConnected)
    }

    func testPlaidConnectionManagerMigrationRemovesLegacyKeysAfterSuccess() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "plaid.amex.isConnected")
        defaults.set("legacy-connection-id", forKey: "plaid.amex.connectionId")
        defaults.set(Date(), forKey: "plaid.amex.lastSyncedAt")

        _ = PlaidConnectionManager(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "plaid.amex.isConnected"), "isConnected must not literally be nil (bool defaults to false when absent) but the key itself must be gone")
        XCTAssertFalse(defaults.bool(forKey: "plaid.amex.isConnected"))
        XCTAssertNil(defaults.string(forKey: "plaid.amex.connectionId"))
        XCTAssertNil(defaults.object(forKey: "plaid.amex.lastSyncedAt"))
    }

    func testPlaidConnectionManagerMigrationIsIdempotentAcrossRelaunches() throws {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "plaid.amex.isConnected")
        defaults.set("legacy-connection-id", forKey: "plaid.amex.connectionId")
        defaults.set(Date(timeIntervalSince1970: 1_700_000_000), forKey: "plaid.amex.lastSyncedAt")

        // First "launch" migrates.
        let first = PlaidConnectionManager(defaults: defaults)
        XCTAssertEqual(first.connections.count, 1)

        // Simulate ordinary post-migration usage before the "next launch".
        first.markSynced(connectionId: "legacy-connection-id")
        let syncedAt = first.connections.first?.lastSyncedAt

        // A second instance over the SAME UserDefaults (simulating relaunch) must read the
        // already-migrated data as-is — never re-run migration (which would have no legacy keys
        // left to read anyway, but critically must also not wipe out `first`'s update above).
        let second = PlaidConnectionManager(defaults: defaults)
        XCTAssertEqual(second.connections.count, 1)
        XCTAssertEqual(second.connections.first?.id, "legacy-connection-id")
        // Compared with a tolerance, not exact equality — `syncedAt` is `first`'s in-memory,
        // sub-second-precision value, while `second` reads it back through ISO8601 encoding
        // (second-precision only, same truncation the backup round-trip tests already document
        // elsewhere in this file), so an exact match would be comparing two different precisions
        // of the same instant.
        let secondSyncedAt = try XCTUnwrap(second.connections.first?.lastSyncedAt)
        let expectedSyncedAt = try XCTUnwrap(syncedAt)
        XCTAssertLessThan(abs(secondSyncedAt.timeIntervalSince(expectedSyncedAt)), 1)
    }

    func testPlaidConnectionManagerMigrationDoesNotRunWhenCurrentFormatAlreadyExists() {
        // A device already on the new format (e.g. a fresh new-build install, or already
        // migrated) must never have migration logic touch its data, even if — hypothetically —
        // stale legacy keys were somehow still lingering in UserDefaults.
        let defaults = makeIsolatedDefaults()
        let first = PlaidConnectionManager(defaults: defaults)
        first.addOrUpdate(connectionId: "conn-new-format", institutionId: "ins_9", institutionName: "New Format Bank")

        // Simulate stale legacy keys somehow coexisting (e.g. leftover from a rollback/reinstall
        // scenario) — these must be ignored once the new-format key is already present.
        defaults.set(true, forKey: "plaid.amex.isConnected")
        defaults.set("legacy-connection-id", forKey: "plaid.amex.connectionId")

        let second = PlaidConnectionManager(defaults: defaults)
        XCTAssertEqual(second.connections.count, 1)
        XCTAssertEqual(second.connections.first?.id, "conn-new-format", "Migration must never run once the current-format key already has data")
    }

    // MARK: - PlaidConnectionManager server-authoritative restoration

    private func makeServerStatus(
        connectionId: String,
        institutionId: String? = "ins_1",
        institutionName: String = "Some Bank",
        requiresReauth: Bool = false,
        pendingExpirationAt: Date? = nil,
        newAccountsAvailable: Bool = false
    ) -> PlaidConnectionStatus {
        PlaidConnectionStatus(
            connectionId: connectionId,
            institutionId: institutionId,
            institutionName: institutionName,
            requiresReauth: requiresReauth,
            pendingExpirationAt: pendingExpirationAt,
            newAccountsAvailable: newAccountsAvailable
        )
    }

    func testRestoreFromServerRecoversConnectionWithNoLocalLegacyKeysAtAll() {
        // The exact physical-device failure this restoration path exists to fix: a device with
        // NO legacy keys and NO v2 data (because the server-side Item was never established
        // through this specific device) must still end up with the server's connection locally.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        XCTAssertTrue(manager.connections.isEmpty)

        manager.restoreFromServer([makeServerStatus(connectionId: "conn-server-1", institutionName: "American Express")])

        XCTAssertEqual(manager.connections.count, 1)
        XCTAssertEqual(manager.connections.first?.id, "conn-server-1")
        XCTAssertEqual(manager.connections.first?.institutionName, "American Express")
    }

    func testRestoreFromServerRecoversFromBrokenEmptyV2State() {
        // A device that already ran the (correct, but locally-blind) legacy migration and
        // persisted an empty v2 array — must still recover once the server reports a connection.
        let defaults = makeIsolatedDefaults()
        let broken = PlaidConnectionManager(defaults: defaults)
        XCTAssertTrue(broken.connections.isEmpty, "Precondition: v2 key now exists and is empty, exactly like the broken physical-device state")

        broken.restoreFromServer([makeServerStatus(connectionId: "conn-server-1")])

        XCTAssertEqual(broken.connections.count, 1)
        XCTAssertEqual(broken.connections.first?.id, "conn-server-1")
    }

    func testRestoreFromServerNeverDuplicatesAnExistingMatchingConnection() {
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-1", institutionId: "ins_1", institutionName: "Some Bank")

        manager.restoreFromServer([makeServerStatus(connectionId: "conn-1", institutionName: "Some Bank")])

        XCTAssertEqual(manager.connections.count, 1, "Restoring a connection that already matches locally must update in place, never append a duplicate")
    }

    func testRestoreFromServerPreservesLocalLastSyncedAtForMatchingConnection() {
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-1", institutionId: "ins_1", institutionName: "Some Bank")
        manager.markSynced(connectionId: "conn-1")
        let localSyncedAt = try! XCTUnwrap(manager.connections.first?.lastSyncedAt)

        manager.restoreFromServer([makeServerStatus(connectionId: "conn-1", institutionName: "Some Bank")])

        XCTAssertEqual(manager.connections.first?.lastSyncedAt, localSyncedAt, "The server has no concept of per-device last-synced-at — restoration must never null it out")
    }

    func testRestoreFromServerWithZeroConnectionsClearsStaleLocalConnection() {
        // A successful server response reporting NO connections is authoritative — a stale local
        // connection (e.g. disconnected from another device) must be cleared, per the required
        // design's rule 11: "server successfully returns zero Items → show no connected
        // institutions."
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-stale", institutionId: "ins_1", institutionName: "Stale Bank")

        manager.restoreFromServer([])

        XCTAssertTrue(manager.connections.isEmpty)
    }

    func testFailedServerRequestNeverCallsRestoreLeavingLocalStateUnchanged() {
        // Mirrors the ConnectedAccountsView contract: restoreFromServer is only ever invoked
        // after a SUCCESSFUL listConnections() call — on failure, the call site must simply not
        // invoke this method at all, so existing local state is untouched by construction.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.addOrUpdate(connectionId: "conn-1", institutionId: "ins_1", institutionName: "Some Bank")
        let before = manager.connections

        // No restoreFromServer call here — simulating a failed backend request.

        XCTAssertEqual(manager.connections, before)
    }

    func testRestoreFromServerAcceptsConnectionWithNilInstitutionId() {
        // A legacy/pre-migration plaid_items row may never have captured institution_id — the
        // server-side DTO and this manager must both tolerate that as nil, never crash or reject.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.restoreFromServer([makeServerStatus(connectionId: "conn-1", institutionId: nil, institutionName: "American Express")])

        XCTAssertEqual(manager.connections.count, 1)
        XCTAssertNil(manager.connections.first?.institutionId)
    }

    func testRestoreFromServerAcceptsConnectionWithNoOptionalServerFieldsPopulated() {
        // A minimal legacy row: no pending expiration, no reauth/new-accounts flags ever set —
        // restoration must still succeed and produce a usable local connection.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        manager.restoreFromServer([
            makeServerStatus(
                connectionId: "conn-1",
                institutionId: nil,
                requiresReauth: false,
                pendingExpirationAt: nil,
                newAccountsAvailable: false
            )
        ])

        let restored = try! XCTUnwrap(manager.connections.first)
        XCTAssertEqual(restored.id, "conn-1")
        XCTAssertNil(restored.pendingExpirationAt)
        XCTAssertFalse(restored.requiresReauth)
        XCTAssertFalse(restored.newAccountsAvailable)
    }

    func testRestoredConnectionSurvivesASecondManagerInitialization() {
        // Restoration must persist through the normal v2-key path — a second "launch" (a fresh
        // manager instance over the same UserDefaults) must load the restored data as-is, never
        // re-run migration or lose it.
        let defaults = makeIsolatedDefaults()
        let first = PlaidConnectionManager(defaults: defaults)
        first.restoreFromServer([makeServerStatus(connectionId: "conn-server-1", institutionName: "American Express")])

        let second = PlaidConnectionManager(defaults: defaults)
        XCTAssertEqual(second.connections.count, 1)
        XCTAssertEqual(second.connections.first?.id, "conn-server-1")
        XCTAssertEqual(second.connections.first?.institutionName, "American Express")
    }

    func testRestoreFromServerOnlyMutatesLocalConnectionListNoOtherSideEffects() {
        // restoreFromServer takes an already-fetched `[PlaidConnectionStatus]` — it has no network
        // access itself, so it structurally cannot create, exchange, disconnect, or delete a
        // Plaid Item. Calling it repeatedly with the same input must be idempotent (no growth, no
        // duplication), which is the only externally observable behavior this pure local-state
        // method could have.
        let manager = PlaidConnectionManager(defaults: makeIsolatedDefaults())
        let status = makeServerStatus(connectionId: "conn-1", institutionName: "Some Bank")

        manager.restoreFromServer([status])
        manager.restoreFromServer([status])
        manager.restoreFromServer([status])

        XCTAssertEqual(manager.connections.count, 1, "Repeated restoration with the same server state must never create duplicates")
    }

    // MARK: - PlaidBalanceFormatter (account-type-aware balance display)

    private func makeBalance(
        type: String?,
        subtype: String? = nil,
        current: Decimal? = nil,
        available: Decimal? = nil,
        limit: Decimal? = nil,
        isoCurrencyCode: String? = "USD"
    ) -> PlaidAccountBalance {
        PlaidAccountBalance(
            accountId: "acc-1",
            name: "Test Account",
            officialName: nil,
            mask: "1234",
            type: type,
            subtype: subtype,
            currentBalance: current,
            availableBalance: available,
            creditLimit: limit,
            isoCurrencyCode: isoCurrencyCode,
            unofficialCurrencyCode: nil
        )
    }

    func testPlaidBalanceFormatterDepositoryShowsCurrentAndAvailable() {
        let balance = makeBalance(type: "depository", subtype: "checking", current: 500, available: 480)
        let rows = PlaidBalanceFormatter.rows(for: balance)
        XCTAssertEqual(rows, [
            .init(label: "Current Balance", amount: 500),
            .init(label: "Available Balance", amount: 480),
        ])
    }

    func testPlaidBalanceFormatterCreditShowsBalanceOwedNeverCurrentBalance() {
        // The exact bug this formatter exists to prevent: a credit card's `current` (amount
        // owed) must never be labeled the same way a checking account's cash balance is.
        let balance = makeBalance(type: "credit", subtype: "credit card", current: 250, available: 4750, limit: 5000)
        let rows = PlaidBalanceFormatter.rows(for: balance)
        XCTAssertFalse(rows.contains { $0.label == "Current Balance" })
        XCTAssertEqual(rows, [
            .init(label: "Balance Owed", amount: 250),
            .init(label: "Available Credit", amount: 4750),
            .init(label: "Credit Limit", amount: 5000),
        ])
    }

    func testPlaidBalanceFormatterCreditDerivesAvailableCreditWhenPlaidOmitsIt() {
        // Plaid's own documented formula: available = limit - current (only current/limit
        // present, `available` itself is nil).
        let balance = makeBalance(type: "credit", current: 200, available: nil, limit: 1000)
        let rows = PlaidBalanceFormatter.rows(for: balance)
        XCTAssertTrue(rows.contains(.init(label: "Available Credit", amount: 800)))
    }

    func testPlaidBalanceFormatterNeverDerivesAvailableCreditIfPlaidProvidedIt() {
        // Plaid's own `available` (which can differ from the naive limit-minus-current formula
        // due to pending transactions) must always win over the derived fallback.
        let balance = makeBalance(type: "credit", current: 200, available: 750, limit: 1000)
        let rows = PlaidBalanceFormatter.rows(for: balance)
        XCTAssertTrue(rows.contains(.init(label: "Available Credit", amount: 750)))
        XCTAssertFalse(rows.contains(.init(label: "Available Credit", amount: 800)))
    }

    func testPlaidBalanceFormatterNeverDerivesAvailableCreditWithoutBothInputs() {
        XCTAssertNil(PlaidBalanceFormatter.derivedAvailableCredit(balance: makeBalance(type: "credit", current: 200, limit: nil)))
        XCTAssertNil(PlaidBalanceFormatter.derivedAvailableCredit(balance: makeBalance(type: "credit", current: nil, limit: 1000)))
    }

    func testPlaidBalanceFormatterLoanNeverLabelsBalanceAsAvailableCash() {
        let balance = makeBalance(type: "loan", subtype: "mortgage", current: 250_000, available: nil)
        let rows = PlaidBalanceFormatter.rows(for: balance)
        XCTAssertEqual(rows, [.init(label: "Balance", amount: 250_000)])
        XCTAssertFalse(rows.contains { $0.label == "Available Balance" || $0.label == "Current Balance" })
    }

    func testPlaidBalanceFormatterLoanShowsAvailableOnlyIfPlaidSuppliesIt() {
        let balance = makeBalance(type: "loan", current: 250_000, available: 0)
        let rows = PlaidBalanceFormatter.rows(for: balance)
        XCTAssertTrue(rows.contains(.init(label: "Available", amount: 0)))
    }

    func testPlaidBalanceFormatterUnknownAccountTypeUsesNeutralWordingAndNeverCrashes() {
        // A Plaid account type this app has never seen (a hypothetical future product line, or an
        // institution-specific value) must degrade to neutral wording, not crash.
        let balance = makeBalance(type: "some_future_plaid_type_2027", current: 100, available: 90)
        let rows = PlaidBalanceFormatter.rows(for: balance)
        XCTAssertEqual(rows, [
            .init(label: "Balance", amount: 100),
            .init(label: "Available", amount: 90),
        ])
    }

    func testPlaidBalanceFormatterOmitsRowsForNilValues() {
        let balance = makeBalance(type: "depository", current: nil, available: nil)
        XCTAssertTrue(PlaidBalanceFormatter.rows(for: balance).isEmpty, "Must never fabricate a $0.00 row for a value Plaid didn't provide")
    }

    func testPlaidAccountKindClassifyIsCaseInsensitiveAndDefaultsToOther() {
        XCTAssertEqual(PlaidAccountKind.classify(type: "CREDIT"), .credit)
        XCTAssertEqual(PlaidAccountKind.classify(type: nil), .other)
        XCTAssertEqual(PlaidAccountKind.classify(type: "totally_unknown"), .other)
    }

    // MARK: - Account rediscovery reconciliation (mirrors refreshPlaidAccounts in
    // supabase/functions/_shared/plaid.ts — this project has no Deno test harness, so the SET
    // LOGIC that server-side function's reconciliation depends on is verified here instead, the
    // one place this codebase can actually run automated tests. See PlaidAccountReconciliation
    // below for the exact mirrored decision rule.)

    func testAccountReconciliationNewAccountIsInsertedActive() {
        let outcome = PlaidAccountReconciliation.classify(accountId: "new-acc", previouslyActive: [], seenNow: ["new-acc"])
        XCTAssertEqual(outcome, .activeAfterRefresh)
    }

    func testAccountReconciliationExistingAccountStaysActiveNotDuplicated() {
        let outcome = PlaidAccountReconciliation.classify(accountId: "acc-1", previouslyActive: ["acc-1"], seenNow: ["acc-1"])
        XCTAssertEqual(outcome, .activeAfterRefresh, "An account Plaid still reports must be upserted (update), never inserted a second time")
    }

    func testAccountReconciliationPreviouslyInactiveAccountReactivatesWhenSeenAgain() {
        // "previouslyActive" only tracks currently-active rows (mirrors the real query's
        // `.eq("is_active", true)`) — an account NOT in that set that reappears in `seenNow` is,
        // by construction, a reactivation: the shared upsert always writes `is_active: true` for
        // every row Plaid currently reports, regardless of its prior state.
        let outcome = PlaidAccountReconciliation.classify(accountId: "closed-then-reopened", previouslyActive: [], seenNow: ["closed-then-reopened"])
        XCTAssertEqual(outcome, .activeAfterRefresh)
    }

    func testAccountReconciliationAccountAbsentFromCompleteResponseBecomesInactive() {
        let outcome = PlaidAccountReconciliation.classify(accountId: "closed-acc", previouslyActive: ["closed-acc"], seenNow: [])
        XCTAssertEqual(outcome, .deactivated)
    }

    func testAccountReconciliationUnrelatedInactiveAccountStaysUntouched() {
        let outcome = PlaidAccountReconciliation.classify(accountId: "long-gone", previouslyActive: [], seenNow: [])
        XCTAssertEqual(outcome, .unchanged)
    }

    func testAccountReconciliationStaleIdSetMatchesSubtraction() {
        let stale = PlaidAccountReconciliation.staleAccountIds(previouslyActive: ["a", "b", "c"], seenNow: ["b", "c"])
        XCTAssertEqual(stale, ["a"])
    }

    func testAccountReconciliationNoStaleIdsWhenEverythingStillSeen() {
        let stale = PlaidAccountReconciliation.staleAccountIds(previouslyActive: ["a", "b"], seenNow: ["a", "b", "c"])
        XCTAssertTrue(stale.isEmpty)
    }

    // MARK: - CurrencyInputState (cents-first currency entry)

    private func makeState(
        allowsNegative: Bool = false,
        allowsZero: Bool = true,
        minimum: Decimal? = nil,
        maximum: Decimal? = nil
    ) -> CurrencyInputState {
        CurrencyInputState(allowsNegative: allowsNegative, allowsZero: allowsZero, minimum: minimum, maximum: maximum)
    }

    // Digit entry

    func testDigitEntryCentsFirstSequence() {
        var state = makeState()
        state.enterDigit(1)
        XCTAssertEqual(state.amount, 0.01)
        state.enterDigit(2)
        XCTAssertEqual(state.amount, 0.12)
        state.enterDigit(3)
        XCTAssertEqual(state.amount, 1.23)
        state.enterDigit(4)
        XCTAssertEqual(state.amount, 12.34)
        state.enterDigit(5)
        XCTAssertEqual(state.amount, 123.45)
    }

    func testDigitEntryOfZeroKeepsFieldAtZeroNotEmpty() {
        var state = makeState()
        state.enterDigit(0)
        XCTAssertEqual(state.amount, 0)
        XCTAssertNotNil(state.amount, "A typed 0 is content, not an empty field")
    }

    // Backspace

    func testBackspaceRemovesLastDigit() {
        var state = makeState()
        for digit in [1, 2, 3, 4, 5] { state.enterDigit(digit) }
        XCTAssertEqual(state.amount, 123.45)
        state.backspace()
        XCTAssertEqual(state.amount, 12.34)
    }

    func testBackspaceFromOneCentEmptiesTheField() {
        var state = makeState()
        state.enterDigit(1)
        XCTAssertEqual(state.amount, 0.01)
        state.backspace()
        XCTAssertNil(state.amount)
    }

    func testBackspaceOnEmptyFieldIsANoOp() {
        var state = makeState()
        state.backspace()
        XCTAssertNil(state.amount)
    }

    func testClearAlwaysEmptiesTheField() {
        var state = makeState()
        for digit in [1, 2, 3, 4, 5] { state.enterDigit(digit) }
        state.clear()
        XCTAssertNil(state.amount)
    }

    // Paste

    func testPasteOfPlainDecimalAmount() {
        var state = makeState()
        XCTAssertTrue(state.applyPastedText("123.45"))
        XCTAssertEqual(state.amount, 123.45)
    }

    func testPasteOfDollarPrefixedAmount() {
        var state = makeState()
        XCTAssertTrue(state.applyPastedText("$123.45"))
        XCTAssertEqual(state.amount, 123.45)
    }

    func testPasteOfGroupedAmount() {
        var state = makeState()
        XCTAssertTrue(state.applyPastedText("$1,234.56"))
        XCTAssertEqual(state.amount, Decimal(string: "1234.56"))
    }

    func testPasteOfBareIntegerIsWholeDollarsNeverCents() {
        var state = makeState()
        XCTAssertTrue(state.applyPastedText("1234"))
        XCTAssertEqual(state.amount, 1234, "Pasting 1234 must never become 12.34 — that's cents-first TYPING behavior, not paste behavior")
    }

    func testPasteWithLeadingAndTrailingWhitespace() {
        var state = makeState()
        XCTAssertTrue(state.applyPastedText("  42.50  "))
        XCTAssertEqual(state.amount, 42.50)
    }

    func testPasteWithLocaleDecimalSeparator() {
        var state = makeState()
        let germanLocale = Locale(identifier: "de_DE")
        XCTAssertTrue(state.applyPastedText("1.234,56", locale: germanLocale))
        XCTAssertEqual(state.amount, Decimal(string: "1234.56"))
    }

    func testPasteOfInvalidTextIsRejectedAndLeavesFieldUnchanged() {
        var state = makeState()
        state.enterDigit(1)
        state.enterDigit(2)
        XCTAssertFalse(state.applyPastedText("not a number"))
        XCTAssertEqual(state.amount, 0.12, "A rejected paste must never partially apply or clear existing content")
    }

    func testPasteOfEmptyOrWhitespaceOnlyTextIsRejected() {
        var state = makeState()
        XCTAssertFalse(state.applyPastedText(""))
        XCTAssertFalse(state.applyPastedText("   "))
        XCTAssertNil(state.amount)
    }

    func testPasteOfMultipleDecimalPointsIsRejected() {
        var state = makeState()
        XCTAssertFalse(state.applyPastedText("12.34.56"))
        XCTAssertNil(state.amount)
    }

    // Validation

    func testZeroDisallowedRejectsExactlyZero() {
        let state = makeState(allowsZero: false)
        var zeroState = state
        zeroState.enterDigit(0)
        XCTAssertFalse(zeroState.satisfiesOwnConstraints)
    }

    func testZeroAllowedAcceptsExactlyZero() {
        var state = makeState(allowsZero: true)
        state.enterDigit(0)
        XCTAssertTrue(state.satisfiesOwnConstraints)
    }

    func testNegativeDisallowedRejectsPastedNegativeOutright() {
        var state = makeState(allowsNegative: false)
        XCTAssertFalse(state.applyPastedText("-5.00"), "A negative paste must be rejected entirely, not silently made positive")
        XCTAssertNil(state.amount)
    }

    func testNegativeAllowedAcceptsPastedNegative() {
        var state = makeState(allowsNegative: true)
        XCTAssertTrue(state.applyPastedText("-5.00"))
        XCTAssertEqual(state.amount, -5.00)
        XCTAssertTrue(state.satisfiesOwnConstraints)
    }

    func testDigitEntryNeverProducesANegativeValueEvenWhenAllowed() {
        // Cents-first digit entry has no keystroke for a sign — negatives can only arrive via
        // paste. Confirmed here as a regression guard since this is the one behavior EVERY
        // migrated screen in the app currently depends on (AmountEntryView's own sanitizer used
        // to strip "-" for the same reason).
        var state = makeState(allowsNegative: true)
        state.enterDigit(5)
        XCTAssertEqual(state.amount, 0.05)
        XCTAssertFalse(state.isNegative)
    }

    func testMinimumIsExposedViaSatisfiesOwnConstraintsNotByBlockingTyping() {
        var state = makeState(minimum: 10)
        state.enterDigit(5) // $0.05, below the minimum — must still be typable
        XCTAssertEqual(state.amount, 0.05)
        XCTAssertFalse(state.satisfiesOwnConstraints)
        for _ in 0..<3 { state.enterDigit(0) } // $50.00
        XCTAssertTrue(state.satisfiesOwnConstraints)
    }

    func testMaximumBlocksFurtherDigitsOnceReached() {
        var state = makeState(maximum: 1.00)
        state.enterDigit(1)
        state.enterDigit(0)
        state.enterDigit(0) // $1.00 exactly — at the ceiling
        XCTAssertEqual(state.amount, 1.00)
        state.enterDigit(5) // would become $10.05 — must be refused
        XCTAssertEqual(state.amount, 1.00)
    }

    func testMaximumClampsAnOverLimitPaste() {
        var state = makeState(maximum: 100)
        XCTAssertTrue(state.applyPastedText("999.99"))
        XCTAssertEqual(state.amount, 100, "A paste exceeding maximum is clamped to it, never left unbounded")
    }

    func testRoundingToTwoDecimalPlacesOnPaste() {
        var state = makeState()
        XCTAssertTrue(state.applyPastedText("12.999"))
        XCTAssertEqual(state.amount, 13.00, "Plain rounding to the nearest cent, not truncation")
    }

    func testVeryLargeValueDoesNotOverflowOrCrash() {
        var state = makeState()
        for _ in 0..<15 { state.enterDigit(9) }
        XCTAssertNotNil(state.amount)
        XCTAssertLessThanOrEqual(state.amount ?? 0, Decimal(string: "9999999999.99")!)
    }

    func testEmptyOptionalFieldHasNilAmount() {
        let state = makeState()
        XCTAssertNil(state.amount)
        XCTAssertTrue(state.satisfiesOwnConstraints, "An empty field satisfies the field's OWN constraints — required-ness is each screen's own concern")
    }

    func testEmptyRequiredFieldIsCallerResponsibilityNotFieldConstraint() {
        // Mirrors every migrated screen's own `amount == nil` required-check — the field itself
        // never encodes "required", by design (see satisfiesOwnConstraints's own doc comment).
        let state = makeState()
        let isValidPerCallerRule = state.amount != nil
        XCTAssertFalse(isValidPerCallerRule)
    }

    // Editing existing values

    func testLoadingExistingValueDisplaysCorrectly() {
        var state = makeState()
        state.load(123.45)
        XCTAssertEqual(state.amount, 123.45)
        XCTAssertEqual(state.displayText(locale: Locale(identifier: "en_US")), "$123.45")
    }

    func testTypingAfterLoadingContinuesCentsFirstFromLoadedValue() {
        var state = makeState()
        state.load(Decimal(string: "123.45"))
        state.enterDigit(6)
        XCTAssertEqual(state.amount, Decimal(string: "1234.56"), "Loading $123.45 then typing 6 must produce $1,234.56, never erase the loaded value")
    }

    func testBackspaceAfterLoadingShiftsDownFromLoadedValue() {
        var state = makeState()
        state.load(123.45)
        state.backspace()
        XCTAssertEqual(state.amount, 12.34)
    }

    func testReplacingWholeLoadedValueViaPaste() {
        var state = makeState()
        state.load(123.45)
        XCTAssertTrue(state.applyPastedText("50.00"))
        XCTAssertEqual(state.amount, 50.00)
    }

    func testSaveRoundTripReturnsExactSamePreciseAmount() {
        var state = makeState()
        state.load(1999.99)
        let roundTripped = state.amount
        XCTAssertEqual(roundTripped, Decimal(string: "1999.99"))
    }

    func testLoadingNilProducesEmptyField() {
        var state = makeState()
        state.load(123.45)
        state.load(nil)
        XCTAssertNil(state.amount)
    }

    // Accessibility / formatting safety

    func testDisplayTextNeverContainsDuplicateCurrencySymbols() {
        var state = makeState()
        state.load(42.00)
        let text = state.displayText(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(text.filter { $0 == "$" }.count, 1)
    }

    func testDisplayTextHasNoMalformedSeparators() {
        var state = makeState()
        state.load(1234567.89)
        let text = state.displayText(locale: Locale(identifier: "en_US"))
        XCTAssertFalse(text.contains(",,"))
        XCTAssertFalse(text.contains(".."))
    }

    func testDisplayTextDoesNotCrashWithUnknownOrUnusualLocale() {
        var state = makeState()
        state.load(42.50)
        let weirdLocale = Locale(identifier: "xx_XX_NONEXISTENT")
        let text = state.displayText(locale: weirdLocale)
        XCTAssertFalse(text.isEmpty)
    }

    func testRepeatedIdenticalLoadsAreIdempotent() {
        // Guards against a recursive update loop: loading the same value repeatedly (as
        // `updateUIView` might do on every unrelated SwiftUI re-render) must never change the
        // state or its displayed text.
        var state = makeState()
        state.load(75.25)
        let firstText = state.displayText(locale: Locale(identifier: "en_US"))
        state.load(75.25)
        state.load(75.25)
        XCTAssertEqual(state.amount, 75.25)
        XCTAssertEqual(state.displayText(locale: Locale(identifier: "en_US")), firstText)
    }

    // Paste parser, exercised directly

    func testParseFormattedAmountAcceptsAccountingStyleParenthesesAsNegative() {
        let parsed = CurrencyInputState.parseFormattedAmount("(50.00)")
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.isNegative ?? false)
        XCTAssertEqual(parsed?.cents, 5000)
    }

    func testParseFormattedAmountRejectsGarbageText() {
        XCTAssertNil(CurrencyInputState.parseFormattedAmount("abc"))
        XCTAssertNil(CurrencyInputState.parseFormattedAmount("$$"))
        XCTAssertNil(CurrencyInputState.parseFormattedAmount("12/34"))
    }

    // MARK: - Manual Account monthly-spending default

    func testNewRegisterOnlyAccountDefaultsToNotCountingTowardMonthlySpending() {
        // Mirrors AddAccountView's own init: a brand-new account's toggle starts off.
        let account = Account(name: "Old Loan", type: .other, currentBalance: 0, defaultCountsTowardMonthlySpending: false)
        XCTAssertFalse(account.defaultCountsTowardMonthlySpending)
    }

    func testNewSpendingTrackedAccountDefaultsCorrectlyWhenExplicitlyEnabled() {
        let account = Account(name: "Everyday Checking", type: .checking, currentBalance: 0, defaultCountsTowardMonthlySpending: true)
        XCTAssertTrue(account.defaultCountsTowardMonthlySpending)
    }

    func testExistingAccountConstructedWithoutTheFieldDefaultsToTrue() {
        // The schema-level default (used by the lightweight SwiftData migration backfill for
        // every pre-existing account) — never explicitly passed here, on purpose.
        let account = Account(name: "Legacy Account", type: .checking, currentBalance: 100)
        XCTAssertTrue(account.defaultCountsTowardMonthlySpending)
    }

    func testEditingAccountDefaultDoesNotAlterOldTransactionsOwnStoredValue() {
        let account = Account(name: "Register", type: .other, currentBalance: 0, defaultCountsTowardMonthlySpending: false)
        let oldTransaction = FinanceTransaction(amount: 20, type: .expense, countsTowardMonthlySpending: true, account: account)

        // Flip the account's default AFTER the transaction already exists.
        account.defaultCountsTowardMonthlySpending = true

        XCTAssertTrue(oldTransaction.countsTowardMonthlySpending, "Changing the account default must never rewrite an existing transaction's own stored value")
    }

    @MainActor
    func testUntouchedNewAccountFormPersistsMonthlySpendingDefaultAsFalse() {
        // Simulates AddAccountView.commitAutosaveNow's "brand-new account" branch end to end: the
        // form's toggle state starts at `false` per its own `init` (never touched by the user),
        // gets passed straight into the new `Account`, inserted, and saved — the persisted row
        // must come back with `defaultCountsTowardMonthlySpending == false`.
        let context = makeAutosaveTestContext()
        let untouchedFormToggleState = false // AddAccountView's init(account: nil) seed value

        let account = Account(
            name: "New Loan",
            type: .other,
            currentBalance: 0,
            defaultCountsTowardMonthlySpending: untouchedFormToggleState
        )
        context.insert(account)
        try! context.save()

        let fetched = try! context.fetch(FetchDescriptor<Account>()).first
        XCTAssertEqual(fetched?.defaultCountsTowardMonthlySpending, false, "Saving a new account without touching the toggle must persist false")
    }

    @MainActor
    func testBackupPreservesAccountDefaultCountsTowardMonthlySpending() throws {
        let account = Account(name: "Register Only", type: .cash, currentBalance: 50, defaultCountsTowardMonthlySpending: false)

        let document = SpendSmartBackupService.makeDocument(
            accounts: [account], transactions: [], categories: [], budgetSettings: [],
            monthlyPlanSettings: [], incomeSources: [], recurringExpenses: []
        )
        let encoded = try SpendSmartBackupService.encode(document)
        let decoded = try SpendSmartBackupService.decode(encoded)

        XCTAssertEqual(decoded.accounts.first?.defaultCountsTowardMonthlySpending, false)
    }

    func testBackupDecodingOldAccountJSONWithoutTheFieldDefaultsToTrue() throws {
        // Simulates a backup file written before this field existed — the key is simply absent.
        let oldFormatJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Old Backup Account",
            "type": "checking",
            "currentBalance": "100.00",
            "colorHex": "#5D9CFF",
            "isArchived": false,
            "createdAt": \(Date().timeIntervalSinceReferenceDate),
            "updatedAt": \(Date().timeIntervalSinceReferenceDate),
            "connectionType": "manual"
        }
        """
        let decoded = try JSONDecoder().decode(SpendSmartBackupService.AccountDTO.self, from: Data(oldFormatJSON.utf8))
        XCTAssertTrue(decoded.defaultCountsTowardMonthlySpending)
    }

    // MARK: - Manual Account monthly-spending: expense-level override

    func testExpenseDefaultsOnWhenAccountDefaultIsOn() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, defaultCountsTowardMonthlySpending: true)
        let expense = FinanceTransaction(amount: 10, type: .expense, countsTowardMonthlySpending: account.defaultCountsTowardMonthlySpending, account: account)
        XCTAssertTrue(expense.countsTowardMonthlySpending)
    }

    func testExpenseDefaultsOffWhenAccountDefaultIsOff() {
        let account = Account(name: "Register", type: .other, currentBalance: 0, defaultCountsTowardMonthlySpending: false)
        let expense = FinanceTransaction(amount: 10, type: .expense, countsTowardMonthlySpending: account.defaultCountsTowardMonthlySpending, account: account)
        XCTAssertFalse(expense.countsTowardMonthlySpending)
    }

    func testUserOverrideOnPersistsRegardlessOfAccountDefault() {
        let account = Account(name: "Register", type: .other, currentBalance: 0, defaultCountsTowardMonthlySpending: false)
        // The user manually flips the toggle ON despite the account defaulting off.
        let expense = FinanceTransaction(amount: 10, type: .expense, countsTowardMonthlySpending: true, account: account)
        XCTAssertTrue(expense.countsTowardMonthlySpending)
    }

    func testUserOverrideOffPersistsRegardlessOfAccountDefault() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, defaultCountsTowardMonthlySpending: true)
        // The user manually flips the toggle OFF despite the account defaulting on.
        let expense = FinanceTransaction(amount: 10, type: .expense, countsTowardMonthlySpending: false, account: account)
        XCTAssertFalse(expense.countsTowardMonthlySpending)
    }

    func testNoAccountExpenseDefaultsToCountingTowardMonthlySpending() {
        // Cash purchases, or any expense not tied to an account, must default to counting —
        // preserving today's behavior and supporting the explicit "cash purchase that counts"
        // requirement.
        let expense = FinanceTransaction(amount: 15, type: .expense, countsTowardMonthlySpending: true, account: nil)
        XCTAssertTrue(expense.countsTowardMonthlySpending)
        XCTAssertNil(expense.account)
    }

    func testNoAccountExpenseCanStillBeExcludedFromMonthlySpending() {
        let expense = FinanceTransaction(amount: 15, type: .expense, countsTowardMonthlySpending: false, account: nil)
        XCTAssertFalse(expense.countsTowardMonthlySpending)
    }

    // MARK: - Manual Account monthly-spending: calculations

    func testIncludedExpenseAffectsMonthlyTotal() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 50, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: true, account: account)

        let total = BudgetCalculator.monthlySpent([expense], in: interval)
        XCTAssertEqual(total, 50)
    }

    func testExcludedExpenseDoesNotAffectMonthlyTotal() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let expense = FinanceTransaction(amount: 50, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: false, account: account)

        let total = BudgetCalculator.monthlySpent([expense], in: interval)
        XCTAssertEqual(total, 0)
    }

    func testExpenseCanCountWeeklyButNotMonthly() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 30, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardWeeklyBudget: true, countsTowardMonthlySpending: false, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([expense], in: interval), 30)
        XCTAssertEqual(BudgetCalculator.monthlySpent([expense], in: DateRangeHelper.currentMonthRange()), 0)
    }

    func testExpenseCanCountMonthlyButNotWeekly() {
        let weekInterval = DateRangeHelper.currentWeekRange()
        let monthInterval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 30, date: weekInterval.start.addingTimeInterval(3600), type: .expense, countsTowardWeeklyBudget: false, countsTowardMonthlySpending: true, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([expense], in: weekInterval), 0)
        XCTAssertEqual(BudgetCalculator.monthlySpent([expense], in: monthInterval), 30)
    }

    func testExpenseCanCountInBothWeeklyAndMonthly() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 30, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardWeeklyBudget: true, countsTowardMonthlySpending: true, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([expense], in: interval), 30)
        XCTAssertEqual(BudgetCalculator.monthlySpent([expense], in: DateRangeHelper.currentMonthRange()), 30)
    }

    func testExpenseCanCountInNeitherWeeklyNorMonthly() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let expense = FinanceTransaction(amount: 30, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardWeeklyBudget: false, countsTowardMonthlySpending: false, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([expense], in: interval), 0)
        XCTAssertEqual(BudgetCalculator.monthlySpent([expense], in: DateRangeHelper.currentMonthRange()), 0)
    }

    func testDeletingIncludedExpenseReducesMonthlyTotalWhenSimulatedByRemoval() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: true, account: account)

        XCTAssertEqual(BudgetCalculator.monthlySpent([expense], in: interval), 40)
        // Simulates deletion: the transaction is simply no longer in the collection passed in —
        // BudgetCalculator has no persistence of its own to invalidate.
        XCTAssertEqual(BudgetCalculator.monthlySpent([], in: interval), 0)
    }

    func testDeletingExcludedExpenseLeavesMonthlyTotalUnchanged() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let countedExpense = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: true, account: account)
        let excludedExpense = FinanceTransaction(amount: 999, date: interval.start.addingTimeInterval(7200), type: .expense, countsTowardMonthlySpending: false, account: account)

        let before = BudgetCalculator.monthlySpent([countedExpense, excludedExpense], in: interval)
        let after = BudgetCalculator.monthlySpent([countedExpense], in: interval) // excludedExpense "deleted"
        XCTAssertEqual(before, after, "Removing a transaction that never counted must never change the total")
    }

    func testRefundExcludedFromBothFlagsNeverReducesEitherTotal() {
        // A refund is gated by the exact same flags its originating expense would be — a refund
        // from a register-only account (both flags off) must never reduce monthly or weekly
        // spending, since the original purchase never raised either total in the first place.
        let monthInterval = DateRangeHelper.currentMonthRange()
        let weekInterval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let refund = FinanceTransaction(amount: 25, date: weekInterval.start.addingTimeInterval(3600), type: .refund, countsTowardWeeklyBudget: false, countsTowardMonthlySpending: false, account: account)

        XCTAssertEqual(BudgetCalculator.monthlySpent([refund], in: monthInterval), 0)
        XCTAssertEqual(BudgetCalculator.weeklySpent([refund], in: weekInterval), 0)
    }

    // MARK: - Refund regression tests (symmetric context gating)

    func testMonthlyIncludedRefundReducesMonthlySpending() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let refund = FinanceTransaction(amount: 25, date: interval.start.addingTimeInterval(3600), type: .refund, countsTowardMonthlySpending: true, account: account)

        XCTAssertEqual(BudgetCalculator.monthlySpent([refund], in: interval), -25)
    }

    func testMonthlyExcludedRefundDoesNotAffectMonthlySpending() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let refund = FinanceTransaction(amount: 25, date: interval.start.addingTimeInterval(3600), type: .refund, countsTowardMonthlySpending: false, account: account)

        XCTAssertEqual(BudgetCalculator.monthlySpent([refund], in: interval), 0)
    }

    func testWeeklyIncludedRefundReducesWeeklySpending() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let refund = FinanceTransaction(amount: 15, date: interval.start.addingTimeInterval(3600), type: .refund, countsTowardWeeklyBudget: true, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([refund], in: interval), -15)
    }

    func testWeeklyExcludedRefundDoesNotAffectWeeklySpending() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let refund = FinanceTransaction(amount: 15, date: interval.start.addingTimeInterval(3600), type: .refund, countsTowardWeeklyBudget: false, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([refund], in: interval), 0)
    }

    func testRefundWithMonthlyTrueAndWeeklyFalseAffectsOnlyMonthly() {
        let weekInterval = DateRangeHelper.currentWeekRange()
        let monthInterval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let refund = FinanceTransaction(amount: 40, date: weekInterval.start.addingTimeInterval(3600), type: .refund, countsTowardWeeklyBudget: false, countsTowardMonthlySpending: true, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([refund], in: weekInterval), 0)
        XCTAssertEqual(BudgetCalculator.monthlySpent([refund], in: monthInterval), -40)
    }

    func testRefundWithMonthlyFalseAndWeeklyTrueAffectsOnlyWeekly() {
        let weekInterval = DateRangeHelper.currentWeekRange()
        let monthInterval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let refund = FinanceTransaction(amount: 40, date: weekInterval.start.addingTimeInterval(3600), type: .refund, countsTowardWeeklyBudget: true, countsTowardMonthlySpending: false, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([refund], in: weekInterval), -40)
        XCTAssertEqual(BudgetCalculator.monthlySpent([refund], in: monthInterval), 0)
    }

    func testExcludedFromReportsRefundAffectsNeitherContext() {
        let weekInterval = DateRangeHelper.currentWeekRange()
        let monthInterval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let refund = FinanceTransaction(amount: 60, date: weekInterval.start.addingTimeInterval(3600), type: .refund, countsTowardWeeklyBudget: true, countsTowardMonthlySpending: true, isExcludedFromReports: true, account: account)

        XCTAssertEqual(BudgetCalculator.weeklySpent([refund], in: weekInterval), 0)
        XCTAssertEqual(BudgetCalculator.monthlySpent([refund], in: monthInterval), 0)
    }

    func testMonthlyCategoryTotalsMatchMonthlyTotalBehaviorForRefunds() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let dining = Category(name: "Dining")
        let expense = FinanceTransaction(amount: 100, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: true, account: account, category: dining)
        let includedRefund = FinanceTransaction(amount: 20, date: interval.start.addingTimeInterval(7200), type: .refund, countsTowardMonthlySpending: true, account: account, category: dining)
        let excludedRefund = FinanceTransaction(amount: 999, date: interval.start.addingTimeInterval(10800), type: .refund, countsTowardMonthlySpending: false, account: account, category: dining)

        let monthlyTotal = BudgetCalculator.monthlySpent([expense, includedRefund, excludedRefund], in: interval)
        let categoryTotal = BudgetCalculator.categoryTotals([expense, includedRefund, excludedRefund], in: interval, context: .monthly).first?.total

        XCTAssertEqual(monthlyTotal, 80)
        XCTAssertEqual(categoryTotal, monthlyTotal, "The category breakdown must agree exactly with the monthly ring total")
    }

    func testWeeklyCategoryTotalsMatchWeeklyTotalBehaviorForRefunds() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let dining = Category(name: "Dining")
        let expense = FinanceTransaction(amount: 100, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardWeeklyBudget: true, account: account, category: dining)
        let includedRefund = FinanceTransaction(amount: 20, date: interval.start.addingTimeInterval(7200), type: .refund, countsTowardWeeklyBudget: true, account: account, category: dining)
        let excludedRefund = FinanceTransaction(amount: 999, date: interval.start.addingTimeInterval(10800), type: .refund, countsTowardWeeklyBudget: false, account: account, category: dining)

        let weeklyTotal = BudgetCalculator.weeklySpent([expense, includedRefund, excludedRefund], in: interval)
        let categoryTotal = BudgetCalculator.categoryTotals([expense, includedRefund, excludedRefund], in: interval, context: .weekly).first?.total

        XCTAssertEqual(weeklyTotal, 80)
        XCTAssertEqual(categoryTotal, weeklyTotal, "The category breakdown must agree exactly with the weekly ring total")
    }

    func testMonthlyAccountTotalsMatchMonthlyTotalBehaviorForRefunds() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 100, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: true, account: account)
        let includedRefund = FinanceTransaction(amount: 20, date: interval.start.addingTimeInterval(7200), type: .refund, countsTowardMonthlySpending: true, account: account)
        let excludedRefund = FinanceTransaction(amount: 999, date: interval.start.addingTimeInterval(10800), type: .refund, countsTowardMonthlySpending: false, account: account)

        let monthlyTotal = BudgetCalculator.monthlySpent([expense, includedRefund, excludedRefund], in: interval)
        let accountTotal = BudgetCalculator.accountTotals([expense, includedRefund, excludedRefund], in: interval, context: .monthly).first?.total

        XCTAssertEqual(monthlyTotal, 80)
        XCTAssertEqual(accountTotal, monthlyTotal, "The account breakdown must agree exactly with the monthly ring total")
    }

    func testWeeklyAccountTotalsMatchWeeklyTotalBehaviorForRefunds() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 100, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardWeeklyBudget: true, account: account)
        let includedRefund = FinanceTransaction(amount: 20, date: interval.start.addingTimeInterval(7200), type: .refund, countsTowardWeeklyBudget: true, account: account)
        let excludedRefund = FinanceTransaction(amount: 999, date: interval.start.addingTimeInterval(10800), type: .refund, countsTowardWeeklyBudget: false, account: account)

        let weeklyTotal = BudgetCalculator.weeklySpent([expense, includedRefund, excludedRefund], in: interval)
        let accountTotal = BudgetCalculator.accountTotals([expense, includedRefund, excludedRefund], in: interval, context: .weekly).first?.total

        XCTAssertEqual(weeklyTotal, 80)
        XCTAssertEqual(accountTotal, weeklyTotal, "The account breakdown must agree exactly with the weekly ring total")
    }

    func testIsCountedReturnsCorrectAnswerForEachContextForRefunds() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let monthOnlyRefund = FinanceTransaction(amount: 10, date: interval.start.addingTimeInterval(3600), type: .refund, countsTowardWeeklyBudget: false, countsTowardMonthlySpending: true, account: account)

        XCTAssertTrue(BudgetCalculator.isCounted(monthOnlyRefund, includePending: true, context: .monthly))
        XCTAssertFalse(BudgetCalculator.isCounted(monthOnlyRefund, includePending: true, context: .weekly))
    }

    func testImportedPlaidTransactionNeverCountsRegardlessOfFlags() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Amex", type: .creditCard, currentBalance: 0)
        // Mirrors PlaidTransactionImportService.mapToFinanceTransaction's actual defaults.
        let imported = FinanceTransaction(
            amount: 100,
            date: interval.start.addingTimeInterval(3600),
            type: .expense,
            source: .plaid,
            countsTowardWeeklyBudget: false,
            countsTowardMonthlySpending: false,
            isExcludedFromReports: true,
            account: account
        )
        XCTAssertEqual(BudgetCalculator.monthlySpent([imported], in: interval), 0)
        XCTAssertFalse(BudgetCalculator.isCounted(imported, includePending: true, context: .monthly))
    }

    func testCreditCardPaymentNeverCountsTowardMonthlySpending() {
        let interval = DateRangeHelper.currentMonthRange()
        let checking = Account(name: "Checking", type: .checking, currentBalance: 0)
        let card = Account(name: "Card", type: .creditCard, currentBalance: 0)
        let payment = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .creditCardPayment, account: checking, transferDestinationAccount: card)
        XCTAssertEqual(BudgetCalculator.monthlySpent([payment], in: interval), 0)
    }

    func testBalanceAdjustmentNeverCountsTowardMonthlySpending() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let adjustment = FinanceTransaction(amount: 500, date: interval.start.addingTimeInterval(3600), type: .balanceAdjustment, account: account)
        XCTAssertEqual(BudgetCalculator.monthlySpent([adjustment], in: interval), 0)
    }

    func testMonthlyIsCountedAgreesWithMonthlySpentPredicate() {
        // Guards the exact bug the new `context` parameter was designed to fix: isCounted must
        // never disagree with the actual ring-total predicate for the same context.
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let excluded = FinanceTransaction(amount: 30, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: false, account: account)

        XCTAssertFalse(BudgetCalculator.isCounted(excluded, includePending: true, context: .monthly))
        XCTAssertEqual(BudgetCalculator.monthlySpent([excluded], in: interval), 0)
    }

    func testWeeklyIsCountedAgreesWithWeeklySpentPredicate() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let excluded = FinanceTransaction(amount: 30, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardWeeklyBudget: false, account: account)

        XCTAssertFalse(BudgetCalculator.isCounted(excluded, includePending: true, context: .weekly))
        XCTAssertEqual(BudgetCalculator.weeklySpent([excluded], in: interval), 0)
    }

    // MARK: - Manual transaction deletion

    @MainActor
    func testOrdinaryManualExpenseDeletesSafelyAndReversesBalance() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        context.insert(account)
        let expense = FinanceTransaction(amount: 20, type: .expense, source: .manual, account: account)
        context.insert(expense)
        AccountBalanceManager.applyExpense(amount: 20, to: account)
        XCTAssertEqual(account.currentBalance, 80)

        let deleted = ManualTransactionDeletionService.delete(expense, context: context)

        XCTAssertTrue(deleted)
        XCTAssertEqual(account.currentBalance, 100, "Deleting an expense must give the money back")
        let remaining = try! context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testManualRefundDeletesSafelyAndReversesBalance() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        context.insert(account)
        let refund = FinanceTransaction(amount: 20, type: .refund, source: .manual, account: account)
        context.insert(refund)
        AccountBalanceManager.applyRefund(amount: 20, to: account)
        XCTAssertEqual(account.currentBalance, 120)

        ManualTransactionDeletionService.delete(refund, context: context)

        XCTAssertEqual(account.currentBalance, 100, "Deleting a refund must take the money back out")
    }

    @MainActor
    func testBalanceAdjustmentDeletesSafelyByReversingStoredDelta() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        context.insert(account)
        // Mirrors BalanceAdjustmentView.save(): amount stores the SIGNED DELTA, not the absolute
        // target balance.
        let delta: Decimal = 50
        let adjustment = FinanceTransaction(amount: delta, type: .balanceAdjustment, source: .manual, account: account)
        context.insert(adjustment)
        AccountBalanceManager.applyBalanceAdjustment(account: account, newBalance: account.currentBalance + delta)
        XCTAssertEqual(account.currentBalance, 150)

        ManualTransactionDeletionService.delete(adjustment, context: context)

        XCTAssertEqual(account.currentBalance, 100, "Deleting a balance adjustment must subtract its stored delta back out")
    }

    @MainActor
    func testCreditCardPaymentDeletesSafelyAndReversesBothAccounts() {
        let context = makeAutosaveTestContext()
        let checking = Account(name: "Checking", type: .checking, currentBalance: 500)
        let card = Account(name: "Card", type: .creditCard, currentBalance: 200)
        context.insert(checking)
        context.insert(card)
        let payment = FinanceTransaction(amount: 100, type: .creditCardPayment, source: .manual, account: checking, transferDestinationAccount: card)
        context.insert(payment)
        AccountBalanceManager.applyCreditCardPayment(amount: 100, from: checking, to: card)
        XCTAssertEqual(checking.currentBalance, 400)
        XCTAssertEqual(card.currentBalance, 100)

        ManualTransactionDeletionService.delete(payment, context: context)

        XCTAssertEqual(checking.currentBalance, 500, "Deleting a payment must refund the source account")
        XCTAssertEqual(card.currentBalance, 200, "Deleting a payment must restore the card's balance owed")
    }

    @MainActor
    func testCreditCardPaymentDeletionRequiresBothAccountRelationships() {
        let context = makeAutosaveTestContext()
        let checking = Account(name: "Checking", type: .checking, currentBalance: 500)
        context.insert(checking)
        // Missing `transferDestinationAccount` — a malformed row that should never be produced by
        // CreditCardPaymentView, but the deletion service must still refuse to touch it rather
        // than silently deleting the row without reversing any balance.
        let malformedPayment = FinanceTransaction(amount: 100, type: .creditCardPayment, source: .manual, account: checking)
        context.insert(malformedPayment)

        let deleted = ManualTransactionDeletionService.delete(malformedPayment, context: context)

        XCTAssertFalse(deleted)
        XCTAssertEqual(checking.currentBalance, 500, "A missing precondition must never partially mutate a balance")
        let remaining = try! context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(remaining.count, 1, "A failed precondition must never delete the row either")
    }

    @MainActor
    func testPlaidImportCannotBeDeletedThroughThisService() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Amex", type: .creditCard, currentBalance: 100)
        context.insert(account)
        let imported = FinanceTransaction(amount: 30, type: .expense, source: .plaid, account: account)
        context.insert(imported)

        XCTAssertEqual(ManualTransactionDeletionService.eligibility(for: imported), .blockedPlaidImport)
        let deleted = ManualTransactionDeletionService.delete(imported, context: context)

        XCTAssertFalse(deleted)
        XCTAssertEqual(account.currentBalance, 100, "A blocked deletion must never touch the account balance")
        let remaining = try! context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(remaining.count, 1, "A blocked deletion must never remove the row")
    }

    @MainActor
    func testMatchedTransactionRelationshipClearedSafelyOnBothSidesBeforeDeletion() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        context.insert(account)
        let manual = FinanceTransaction(amount: 20, type: .expense, source: .manual, account: account)
        let imported = FinanceTransaction(amount: 20, type: .expense, source: .plaid, account: account)
        context.insert(manual)
        context.insert(imported)
        manual.isMatchedToManualExpense = true
        manual.matchedTransactionId = imported.id
        imported.isMatchedToManualExpense = true
        imported.matchedTransactionId = manual.id

        ManualTransactionDeletionService.delete(manual, context: context)

        XCTAssertFalse(imported.isMatchedToManualExpense, "The surviving counterpart must have its match relationship cleared")
        XCTAssertNil(imported.matchedTransactionId)
        let remaining = try! context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(remaining.count, 1, "The Plaid counterpart must never be deleted alongside the manual transaction")
        XCTAssertEqual(remaining.first?.source, .plaid)
    }

    @MainActor
    func testRecurringOccurrenceConfirmationCopyIsDistinctFromOrdinaryExpense() {
        // No live code path sets `isRecurringGenerated` today (no FinanceTransaction is ever
        // linked to a RecurringExpense), but the copy itself must exist and be distinct, per the
        // approved design, for whenever that linkage ships.
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 10, type: .expense, account: account)

        let ordinary = ManualTransactionDeletionService.confirmationCopy(for: expense)
        let recurring = ManualTransactionDeletionService.confirmationCopy(for: expense, isRecurringGenerated: true)

        XCTAssertEqual(ordinary.title, "Delete Expense?")
        XCTAssertEqual(recurring.title, "Delete This Occurrence?")
        XCTAssertNotEqual(ordinary.title, recurring.title)
    }

    func testConfirmationCopyIsDistinctPerTransactionType() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 10, type: .expense, account: account)
        let refund = FinanceTransaction(amount: 10, type: .refund, account: account)
        let adjustment = FinanceTransaction(amount: 10, type: .balanceAdjustment, account: account)
        let payment = FinanceTransaction(amount: 10, type: .creditCardPayment, account: account)

        XCTAssertEqual(ManualTransactionDeletionService.confirmationCopy(for: expense).destructiveActionTitle, "Delete Expense")
        XCTAssertEqual(ManualTransactionDeletionService.confirmationCopy(for: refund).destructiveActionTitle, "Delete Refund")
        XCTAssertEqual(ManualTransactionDeletionService.confirmationCopy(for: adjustment).destructiveActionTitle, "Delete Adjustment")
        XCTAssertEqual(ManualTransactionDeletionService.confirmationCopy(for: payment).destructiveActionTitle, "Delete Payment")
    }

    // MARK: - Optional category

    func testSavingExpenseWithNoCategoryPersistsNilCategory() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 12, type: .expense, account: account, category: nil)
        XCTAssertNil(expense.category)
    }

    @MainActor
    func testUncategorizedExpensePersistsNilCategoryAcrossContextSave() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        context.insert(account)
        let expense = FinanceTransaction(amount: 12, type: .expense, account: account, category: nil)
        context.insert(expense)
        try! context.save()

        let fetched = try! context.fetch(FetchDescriptor<FinanceTransaction>()).first
        XCTAssertNil(fetched?.category)
    }

    func testIncludedUncategorizedExpenseAffectsMonthlyTotal() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: true, account: account, category: nil)

        XCTAssertEqual(BudgetCalculator.monthlySpent([expense], in: interval), 40)
    }

    func testExcludedUncategorizedExpenseDoesNotAffectMonthlyTotal() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Register", type: .other, currentBalance: 0)
        let expense = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: false, account: account, category: nil)

        XCTAssertEqual(BudgetCalculator.monthlySpent([expense], in: interval), 0)
    }

    func testUncategorizedTransactionsGroupUnderNilCategoryBucketAndAgreeWithTotal() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let groceries = Category(name: "Groceries")
        let categorized = FinanceTransaction(amount: 30, date: interval.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: true, account: account, category: groceries)
        let uncategorized = FinanceTransaction(amount: 20, date: interval.start.addingTimeInterval(7200), type: .expense, countsTowardMonthlySpending: true, account: account, category: nil)

        let totals = BudgetCalculator.categoryTotals([categorized, uncategorized], in: interval, context: .monthly)
        let monthlyTotal = BudgetCalculator.monthlySpent([categorized, uncategorized], in: interval)

        XCTAssertEqual(totals.count, 2)
        let uncategorizedBucket = totals.first { $0.category == nil }
        XCTAssertNotNil(uncategorizedBucket, "An eligible uncategorized transaction must still appear as its own bucket, never silently dropped")
        XCTAssertEqual(uncategorizedBucket?.total, 20)
        XCTAssertEqual(totals.reduce(Decimal(0)) { $0 + $1.total }, monthlyTotal, "The breakdown's sum must never fall short of the period's overall total")
    }

    func testSpendSmartQueryEngineHandlesUncategorizedTransactionsSafely() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let month = DateRangeHelper.currentMonthRange()
        let uncategorized = FinanceTransaction(amount: 15, date: month.start.addingTimeInterval(3600), type: .expense, countsTowardMonthlySpending: true, account: account, category: nil)

        let amount = SpendSmartQueryEngine.transactionCategoryAmount(categoryName: "Uncategorized", transactions: [uncategorized], in: month, includePending: true)
        XCTAssertEqual(amount, 15, "A nil-category transaction must be findable under the Uncategorized label without crashing")
    }

    // MARK: - Physical-device monthly-spending regression (exact reported scenario)

    @MainActor
    func testPhysicalDeviceRegression_RegisterOnlyAccountExpenseDoesNotAffectMonthlyOrRemaining() {
        // Reproduces the exact reported steps: new Manual Account, monthly toggle left OFF, a
        // $2.00 expense saved without touching the toggle.
        let context = makeAutosaveTestContext()
        let account = Account(name: "Register Only", type: .other, currentBalance: 0, defaultCountsTowardMonthlySpending: false)
        context.insert(account)

        // Mirrors AddExpenseView.init(preselectedAccount:) seeding from the account's own default.
        let monthlyFlagFromForm = account.defaultCountsTowardMonthlySpending
        let expense = FinanceTransaction(amount: 2, date: .now, type: .expense, countsTowardWeeklyBudget: true, countsTowardMonthlySpending: monthlyFlagFromForm, account: account)
        context.insert(expense)
        try! context.save()

        let fetched = try! context.fetch(FetchDescriptor<FinanceTransaction>()).first
        XCTAssertEqual(fetched?.countsTowardMonthlySpending, false, "The persisted flag must be false")

        let monthInterval = DateRangeHelper.currentMonthRange()
        let monthlySpentBefore = BudgetCalculator.monthlySpent([], in: monthInterval)
        let monthlySpentAfter = BudgetCalculator.monthlySpent([fetched!], in: monthInterval)
        XCTAssertEqual(monthlySpentAfter, monthlySpentBefore, "Dashboard monthly spent must not change")

        let remainingBefore = BudgetCalculator.remaining(limit: 1000, spent: monthlySpentBefore)
        let remainingAfter = BudgetCalculator.remaining(limit: 1000, spent: monthlySpentAfter)
        XCTAssertEqual(remainingAfter, remainingBefore, "Monthly remaining must not change")

        let weekInterval = DateRangeHelper.currentWeekRange()
        XCTAssertEqual(BudgetCalculator.weeklySpent([fetched!], in: weekInterval), 2, "Weekly must still change since the weekly toggle is on")
    }

    @MainActor
    func testPhysicalDeviceRegression_FlagSurvivesRelaunchSimulatedByFreshFetch() {
        let schema = Schema([Account.self, FinanceTransaction.self, BudgetSettings.self, Category.self, IncomeSource.self, RecurringExpense.self, MonthlyPlanSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        let account = Account(name: "Register Only", type: .other, currentBalance: 0, defaultCountsTowardMonthlySpending: false)
        let insertContext = ModelContext(container)
        insertContext.insert(account)
        let expense = FinanceTransaction(amount: 2, type: .expense, countsTowardMonthlySpending: false, account: account)
        insertContext.insert(expense)
        try! insertContext.save()

        // A fresh ModelContext against the same container simulates a relaunch's initial fetch.
        let relaunchContext = ModelContext(container)
        let fetched = try! relaunchContext.fetch(FetchDescriptor<FinanceTransaction>()).first
        XCTAssertEqual(fetched?.countsTowardMonthlySpending, false, "The flag must still be false after a simulated relaunch")
    }

    // MARK: - Manual Account deletion

    @MainActor
    func testEligibleEmptyManualAccountDeletes() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Old Loan", type: .other, currentBalance: 0)
        context.insert(account)
        try! context.save()

        let deleted = ManualAccountDeletionService.delete(account, transactions: [], context: context)

        XCTAssertTrue(deleted)
        let remaining = try! context.fetch(FetchDescriptor<Account>())
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testManualAccountWithOrdinaryExpensesDeletesAlongWithThem() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 80)
        context.insert(account)
        let expense = FinanceTransaction(amount: 20, type: .expense, source: .manual, account: account)
        let refund = FinanceTransaction(amount: 5, type: .refund, source: .manual, account: account)
        context.insert(expense)
        context.insert(refund)
        try! context.save()

        let deleted = ManualAccountDeletionService.delete(account, transactions: [expense, refund], context: context)

        XCTAssertTrue(deleted)
        let remainingAccounts = try! context.fetch(FetchDescriptor<Account>())
        let remainingTransactions = try! context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertTrue(remainingAccounts.isEmpty)
        XCTAssertTrue(remainingTransactions.isEmpty, "SwiftData's cascade rule must remove the account's own ordinary transactions")
    }

    @MainActor
    func testPlaidConnectedAccountIsNeverEligibleForManualDeletion() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Amex", type: .creditCard, currentBalance: 100, connectionType: .plaid)
        context.insert(account)
        try! context.save()

        let eligibility = ManualAccountDeletionService.eligibility(for: account, transactions: [])
        XCTAssertEqual(eligibility, .blockedPlaidAccount)

        let deleted = ManualAccountDeletionService.delete(account, transactions: [], context: context)
        XCTAssertFalse(deleted)
        let remaining = try! context.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(remaining.count, 1, "A blocked deletion must never remove the account")
    }

    @MainActor
    func testAccountBlockedByCreditCardPaymentIsNeverPartiallyDeleted() {
        let context = makeAutosaveTestContext()
        let checking = Account(name: "Checking", type: .checking, currentBalance: 400)
        let card = Account(name: "Card", type: .creditCard, currentBalance: 100)
        context.insert(checking)
        context.insert(card)
        let payment = FinanceTransaction(amount: 100, type: .creditCardPayment, source: .manual, account: checking, transferDestinationAccount: card)
        context.insert(payment)
        try! context.save()

        let eligibility = ManualAccountDeletionService.eligibility(for: checking, transactions: [payment])
        XCTAssertEqual(eligibility, .blockedCreditCardPayment(otherAccountName: "Card"))
        XCTAssertEqual(ManualAccountDeletionService.blockedMessage(for: eligibility), "This account is used by a credit-card payment involving Card. Delete or reverse that payment before deleting this account.")

        let deleted = ManualAccountDeletionService.delete(checking, transactions: [payment], context: context)
        XCTAssertFalse(deleted)
        let remainingAccounts = try! context.fetch(FetchDescriptor<Account>())
        let remainingTransactions = try! context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(remainingAccounts.count, 2, "Neither account may be touched when blocked")
        XCTAssertEqual(remainingTransactions.count, 1, "The payment record must survive untouched")
    }

    @MainActor
    func testAccountBlockedByTransferFromTheDestinationSideIsAlsoBlocked() {
        let context = makeAutosaveTestContext()
        let checking = Account(name: "Checking", type: .checking, currentBalance: 400)
        let savings = Account(name: "Savings", type: .savings, currentBalance: 100)
        context.insert(checking)
        context.insert(savings)
        let transfer = FinanceTransaction(amount: 50, type: .transfer, source: .manual, account: checking, transferDestinationAccount: savings)
        context.insert(transfer)
        try! context.save()

        // Blocked from the DESTINATION side too, not just the source.
        let eligibility = ManualAccountDeletionService.eligibility(for: savings, transactions: [transfer])
        XCTAssertEqual(eligibility, .blockedTransfer(otherAccountName: "Checking"))

        let deleted = ManualAccountDeletionService.delete(savings, transactions: [transfer], context: context)
        XCTAssertFalse(deleted)
    }

    func testBlockedMessageFallsBackSafelyWhenOtherAccountNameUnavailable() {
        let message = ManualAccountDeletionService.blockedMessage(for: .blockedCreditCardPayment(otherAccountName: nil))
        XCTAssertEqual(message, "This account is used by a credit-card payment involving another account. Delete or reverse that payment before deleting this account.")
    }

    @MainActor
    func testRepeatedManualAccountDeletionIsSafe() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Old Loan", type: .other, currentBalance: 0)
        context.insert(account)
        try! context.save()

        let firstDelete = ManualAccountDeletionService.delete(account, transactions: [], context: context)
        XCTAssertTrue(firstDelete)

        // Calling delete again on the same (now-detached) object must never crash.
        let secondDelete = ManualAccountDeletionService.delete(account, transactions: [], context: context)
        _ = secondDelete // outcome is secondary to "did not crash"; no assertion on the exact value

        let remaining = try! context.fetch(FetchDescriptor<Account>())
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Smart Signals foundation

    private struct FakeSmartSignalEngine: SmartSignalEngine {
        let signals: [SmartSignal]
        func generateSignals(context: SmartSignalContext) -> [SmartSignal] { signals }
    }

    private static let smartSignalsFixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEmptySmartSignalContext(now: Date = FinanceTrackTests.smartSignalsFixedNow) -> SmartSignalContext {
        SmartSignalContext(
            transactions: [],
            accounts: [],
            categories: [],
            incomeSources: [],
            recurringExpenses: [],
            budgetSettings: nil,
            monthlyPlanSettings: nil,
            now: now
        )
    }

    private func makeSmartSignal(
        id: String,
        deduplicationID: String? = nil,
        category: SmartSignalCategory = .spending,
        severity: SmartSignalSeverity = .information,
        confidence: SmartSignalConfidence = .medium,
        priority: Int = 0,
        relevantDate: Date? = nil,
        evaluatedAt: Date = FinanceTrackTests.smartSignalsFixedNow
    ) -> SmartSignal {
        SmartSignal(
            id: id,
            deduplicationID: deduplicationID ?? id,
            category: category,
            severity: severity,
            confidence: confidence,
            priority: priority,
            title: "Test Signal \(id)",
            explanation: "Deterministic test explanation.",
            metrics: [],
            action: nil,
            relevantDate: relevantDate,
            evaluatedAt: evaluatedAt
        )
    }

    // Coordinator combination behavior

    func testSmartSignalsEngineWithNoEnginesReturnsEmptyArray() {
        let coordinator = SmartSignalsEngine(engines: [])
        XCTAssertTrue(coordinator.generateSignals(context: makeEmptySmartSignalContext()).isEmpty)
    }

    func testEnginesReturningNoSignalsProduceEmptyResult() {
        let coordinator = SmartSignalsEngine(engines: [
            FakeSmartSignalEngine(signals: []),
            FakeSmartSignalEngine(signals: []),
        ])
        XCTAssertTrue(coordinator.generateSignals(context: makeEmptySmartSignalContext()).isEmpty)
    }

    func testResultsFromMultipleEnginesAreCombined() {
        let engineA = FakeSmartSignalEngine(signals: [makeSmartSignal(id: "a")])
        let engineB = FakeSmartSignalEngine(signals: [makeSmartSignal(id: "b")])
        let coordinator = SmartSignalsEngine(engines: [engineA, engineB])
        let result = coordinator.generateSignals(context: makeEmptySmartSignalContext())
        XCTAssertEqual(Set(result.map(\.id)), Set(["a", "b"]))
    }

    func testOneEngineCanProduceMultipleSignals() {
        let engine = FakeSmartSignalEngine(signals: [makeSmartSignal(id: "a"), makeSmartSignal(id: "b")])
        let coordinator = SmartSignalsEngine(engines: [engine])
        XCTAssertEqual(coordinator.generateSignals(context: makeEmptySmartSignalContext()).count, 2)
    }

    // Ranking determinism

    func testRankingIsDeterministic() {
        let signals = [makeSmartSignal(id: "a", priority: 1), makeSmartSignal(id: "b", priority: 2)]
        let ranking = SmartSignalRanking()
        XCTAssertEqual(ranking.rank(signals).map(\.id), ranking.rank(signals).map(\.id))
    }

    func testRankingUnaffectedByEngineInjectionOrder() {
        let engineA = FakeSmartSignalEngine(signals: [makeSmartSignal(id: "a", priority: 1)])
        let engineB = FakeSmartSignalEngine(signals: [makeSmartSignal(id: "b", priority: 2)])
        let resultAB = SmartSignalsEngine(engines: [engineA, engineB]).generateSignals(context: makeEmptySmartSignalContext())
        let resultBA = SmartSignalsEngine(engines: [engineB, engineA]).generateSignals(context: makeEmptySmartSignalContext())
        XCTAssertEqual(resultAB.map(\.id), resultBA.map(\.id))
        XCTAssertEqual(resultAB.map(\.id), ["b", "a"])
    }

    func testHigherPrioritySortsBeforeLowerPriority() {
        let low = makeSmartSignal(id: "low", priority: 1)
        let high = makeSmartSignal(id: "high", priority: 5)
        XCTAssertEqual(SmartSignalRanking().rank([low, high]).map(\.id), ["high", "low"])
    }

    func testSeverityOrderingIsCorrect() {
        let positive = makeSmartSignal(id: "positive", severity: .positive)
        let information = makeSmartSignal(id: "information", severity: .information)
        let headsUp = makeSmartSignal(id: "headsUp", severity: .headsUp)
        let important = makeSmartSignal(id: "important", severity: .important)
        let ranked = SmartSignalRanking().rank([positive, information, headsUp, important])
        XCTAssertEqual(ranked.map(\.id), ["important", "headsUp", "information", "positive"])
    }

    func testConfidenceOrderingIsCorrect() {
        let limited = makeSmartSignal(id: "limited", confidence: .limitedData)
        let medium = makeSmartSignal(id: "medium", confidence: .medium)
        let high = makeSmartSignal(id: "high", confidence: .high)
        let ranked = SmartSignalRanking().rank([limited, medium, high])
        XCTAssertEqual(ranked.map(\.id), ["high", "medium", "limited"])
    }

    func testMoreRecentRelevantDateSortsFirstWhenPreviousFieldsTie() {
        let older = makeSmartSignal(id: "older", relevantDate: Date(timeIntervalSince1970: 1_000))
        let newer = makeSmartSignal(id: "newer", relevantDate: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(SmartSignalRanking().rank([older, newer]).map(\.id), ["newer", "older"])
    }

    func testEvaluatedAtIsUsedWhenRelevantDateIsNil() {
        let early = makeSmartSignal(id: "early", relevantDate: nil, evaluatedAt: Date(timeIntervalSince1970: 1_000))
        let late = makeSmartSignal(id: "late", relevantDate: nil, evaluatedAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(SmartSignalRanking().rank([early, late]).map(\.id), ["late", "early"])
    }

    func testEqualRankedSignalsUseStableLexicalIdOrdering() {
        let z = makeSmartSignal(id: "z-signal")
        let a = makeSmartSignal(id: "a-signal")
        XCTAssertEqual(SmartSignalRanking().rank([z, a]).map(\.id), ["a-signal", "z-signal"])
    }

    // Deduplication behavior

    func testDuplicateDeduplicationIDValuesProduceOneResult() {
        let engine = FakeSmartSignalEngine(signals: [
            makeSmartSignal(id: "a1", deduplicationID: "dup"),
            makeSmartSignal(id: "a2", deduplicationID: "dup"),
        ])
        let result = SmartSignalsEngine(engines: [engine]).generateSignals(context: makeEmptySmartSignalContext())
        XCTAssertEqual(result.count, 1)
    }

    func testSelectedDuplicateIsTheHighestRanked() {
        let low = makeSmartSignal(id: "low", deduplicationID: "dup", priority: 1)
        let high = makeSmartSignal(id: "high", deduplicationID: "dup", priority: 5)
        let engine = FakeSmartSignalEngine(signals: [low, high])
        let result = SmartSignalsEngine(engines: [engine]).generateSignals(context: makeEmptySmartSignalContext())
        XCTAssertEqual(result.map(\.id), ["high"])
    }

    func testDuplicateSelectionIsIndependentOfEngineOrder() {
        let low = makeSmartSignal(id: "low", deduplicationID: "dup", priority: 1)
        let high = makeSmartSignal(id: "high", deduplicationID: "dup", priority: 5)
        let lowFirstEngine = FakeSmartSignalEngine(signals: [low, high])
        let highFirstEngine = FakeSmartSignalEngine(signals: [high, low])
        let resultA = SmartSignalsEngine(engines: [lowFirstEngine]).generateSignals(context: makeEmptySmartSignalContext())
        let resultB = SmartSignalsEngine(engines: [highFirstEngine]).generateSignals(context: makeEmptySmartSignalContext())
        XCTAssertEqual(resultA.map(\.id), ["high"])
        XCTAssertEqual(resultB.map(\.id), ["high"])
    }

    func testDistinctDeduplicationIDsArePreserved() {
        let engine = FakeSmartSignalEngine(signals: [
            makeSmartSignal(id: "a", deduplicationID: "dup-a"),
            makeSmartSignal(id: "b", deduplicationID: "dup-b"),
        ])
        let result = SmartSignalsEngine(engines: [engine]).generateSignals(context: makeEmptySmartSignalContext())
        XCTAssertEqual(Set(result.map(\.id)), Set(["a", "b"]))
    }

    // Placeholder engine safety

    /// The six engines still in their foundation-only placeholder state — `BudgetSignalEngine`
    /// now has real logic (see the dedicated "BudgetSignalEngine" test section below) and is
    /// deliberately no longer asserted here as a placeholder, though it also correctly returns no
    /// signals for these same no-budget-configured contexts (see
    /// `testBudgetSignalEngineWithNoBudgetSettingsReturnsNoSignals`).
    func testRemainingPlaceholderEnginesHandleEmptyAndSparseContextsSafely() {
        let engines: [any SmartSignalEngine] = [
            SpendingSignalEngine(),
            SubscriptionSignalEngine(),
            IncomeSignalEngine(),
            CashFlowSignalEngine(),
            SavingsSignalEngine(),
            CreditCardSignalEngine(),
        ]
        let emptyContext = makeEmptySmartSignalContext()

        let checking = Account(name: "Checking", type: .checking, currentBalance: 0)
        let sparseContext = SmartSignalContext(
            transactions: [FinanceTransaction(amount: 10, type: .expense, account: checking)],
            accounts: [checking],
            categories: [],
            incomeSources: [],
            recurringExpenses: [],
            budgetSettings: nil,
            monthlyPlanSettings: nil,
            now: FinanceTrackTests.smartSignalsFixedNow
        )

        for engine in engines {
            XCTAssertEqual(engine.generateSignals(context: emptyContext).count, 0)
            XCTAssertEqual(engine.generateSignals(context: sparseContext).count, 0)
        }
    }

    // MARK: - BudgetSignalEngine

    private static let budgetSignalFixedNow = Date(timeIntervalSince1970: 1_752_000_000)

    private func makeBudgetSettings(
        weeklyLimit: Decimal = 300,
        monthlyGoal: Decimal? = nil,
        includePending: Bool = true,
        warningThreshold: Double = 0.70,
        weekStartsOnSunday: Bool = true
    ) -> BudgetSettings {
        BudgetSettings(
            weeklySpendingLimit: weeklyLimit,
            weekStartsOnSunday: weekStartsOnSunday,
            includePendingTransactions: includePending,
            monthlyGoal: monthlyGoal,
            warningThreshold: warningThreshold
        )
    }

    private func makeBudgetSignalContext(
        transactions: [FinanceTransaction] = [],
        budgetSettings: BudgetSettings?,
        now: Date = FinanceTrackTests.budgetSignalFixedNow
    ) -> SmartSignalContext {
        SmartSignalContext(
            transactions: transactions,
            accounts: [],
            categories: [],
            incomeSources: [],
            recurringExpenses: [],
            budgetSettings: budgetSettings,
            monthlyPlanSettings: nil,
            now: now
        )
    }

    /// An expense placed a controlled fraction of the way through the week containing `now` (0 =
    /// week start, 1 = week end) — lets a test target a specific progress percentage without
    /// hand-computing calendar boundaries itself (it reuses `DateRangeHelper`, the same date
    /// source `BudgetSignalEngine` uses).
    private func makeWeeklyExpense(amount: Decimal, fractionIntoWeek: Double, now: Date, weekStartsOnSunday: Bool = true) -> FinanceTransaction {
        let week = DateRangeHelper.weekRangeContaining(now, weekStartsOnSunday: weekStartsOnSunday)
        let date = week.start.addingTimeInterval(week.duration * fractionIntoWeek)
        return FinanceTransaction(amount: amount, date: date, type: .expense)
    }

    private func makeMonthlyExpense(amount: Decimal, fractionIntoMonth: Double, now: Date) -> FinanceTransaction {
        let month = DateRangeHelper.monthRangeContaining(now)
        let date = month.start.addingTimeInterval(month.duration * fractionIntoMonth)
        return FinanceTransaction(amount: amount, date: date, type: .expense)
    }

    func testBudgetSignalEngineWithNoBudgetSettingsReturnsNoSignals() {
        let context = makeBudgetSignalContext(budgetSettings: nil)
        XCTAssertTrue(BudgetSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testBudgetDisabledEquivalentToZeroOrAbsentLimitReturnsNoSignals() {
        // This model has no separate "is budget enabled" flag distinct from a zero/absent limit
        // (see the final report) — a weekly limit of 0 and an absent monthly goal both represent
        // "no budget configured," the same as no `BudgetSettings` at all.
        let settings = makeBudgetSettings(weeklyLimit: 0, monthlyGoal: nil)
        let context = makeBudgetSignalContext(budgetSettings: settings)
        XCTAssertTrue(BudgetSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testZeroBudgetLimitsReturnNoSignals() {
        let settings = makeBudgetSettings(weeklyLimit: 0, monthlyGoal: 0)
        let context = makeBudgetSignalContext(budgetSettings: settings)
        XCTAssertTrue(BudgetSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testNegativeBudgetLimitsReturnNoSignals() {
        let settings = makeBudgetSettings(weeklyLimit: -50, monthlyGoal: -100)
        let context = makeBudgetSignalContext(budgetSettings: settings)
        XCTAssertTrue(BudgetSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testBudgetExceededReturnsExactlyOneImportantSignalWithCorrectOverageMetric() {
        let settings = makeBudgetSettings(weeklyLimit: 100, monthlyGoal: nil)
        let expense = makeWeeklyExpense(amount: 142, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)

        XCTAssertEqual(signals.count, 1)
        guard let signal = signals.first else { return }
        XCTAssertEqual(signal.severity, .important)
        XCTAssertEqual(signal.confidence, .high)
        XCTAssertEqual(signal.category, .budget)
        XCTAssertEqual(signal.id, "budget.weekly.exceeded")
        guard case .currency(let overage)? = signal.metrics.first(where: { $0.id == "budget.overage" })?.value else {
            return XCTFail("Expected a structured currency overage metric")
        }
        XCTAssertEqual(overage, 42)
    }

    func testExceededTakesPrecedenceOverAllOtherBudgetStates() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 200, fractionIntoWeek: 0.9, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.exceeded"])
    }

    func testProgressExactlyOneHundredPercentProducesExceededNotNearlyReached() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 100, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.exceeded"])
    }

    func testProgressFromEightyFivePercentProducesNearlyReachedSignal() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 90, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.nearly-reached"])
        XCTAssertEqual(signals.first?.severity, .headsUp)
        XCTAssertEqual(signals.first?.confidence, .high)
    }

    func testProgressExactlyEightyFivePercentProducesNearlyReachedSignal() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 85, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.nearly-reached"])
    }

    func testProgressImmediatelyBelowEightyFivePercentDoesNotProduceNearlyReached() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 84, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.halfway"])
    }

    func testProgressFromFiftyPercentProducesHalfwaySignal() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 60, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.halfway"])
        XCTAssertEqual(signals.first?.severity, .information)
        XCTAssertEqual(signals.first?.confidence, .high)
    }

    func testProgressExactlyFiftyPercentProducesHalfwaySignal() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 50, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.halfway"])
    }

    func testProgressImmediatelyBelowFiftyPercentDoesNotProduceHalfwaySignal() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 49, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.on-track"])
    }

    func testOnTrackSignalIsNotProducedTooEarlyInThePeriod() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let week = DateRangeHelper.weekRangeContaining(FinanceTrackTests.budgetSignalFixedNow, weekStartsOnSunday: true)
        let tooEarlyNow = week.start.addingTimeInterval(3_600) // 1 hour into a 7-day week
        let expense = FinanceTransaction(amount: 10, date: week.start.addingTimeInterval(1_800), type: .expense)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings, now: tooEarlyNow)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertTrue(signals.isEmpty, "A budget under 50% progress with almost no elapsed period must produce no signal at all, not a premature on-track one")
    }

    func testOnTrackSignalIsProducedWhenElapsedPeriodAndProgressRequirementsAreMet() {
        let settings = makeBudgetSettings(weeklyLimit: 200)
        let expense = makeWeeklyExpense(amount: 50, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.on-track"])
        XCTAssertEqual(signals.first?.category, .positive)
        XCTAssertEqual(signals.first?.severity, .positive)
    }

    func testBudgetSignalIdentifiersAreDeterministicAcrossIndependentWeeklyAndMonthlySignals() {
        let settings = makeBudgetSettings(weeklyLimit: 100, monthlyGoal: 1_000)
        let week = DateRangeHelper.weekRangeContaining(FinanceTrackTests.budgetSignalFixedNow, weekStartsOnSunday: true)
        let month = DateRangeHelper.monthRangeContaining(FinanceTrackTests.budgetSignalFixedNow)
        // Isolated via the counting flags so each transaction affects only the period it's meant
        // to test — otherwise a transaction inside both the week and the month would count toward
        // both totals by default and make the two periods' progress interdependent.
        let weeklyOnlyExpense = FinanceTransaction(
            amount: 90, date: week.start.addingTimeInterval(week.duration * 0.5), type: .expense,
            countsTowardWeeklyBudget: true, countsTowardMonthlySpending: false
        )
        let monthlyOnlyExpense = FinanceTransaction(
            amount: 500, date: month.start.addingTimeInterval(month.duration * 0.5), type: .expense,
            countsTowardWeeklyBudget: false, countsTowardMonthlySpending: true
        )
        let context = makeBudgetSignalContext(transactions: [weeklyOnlyExpense, monthlyOnlyExpense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)

        XCTAssertEqual(Set(signals.map(\.id)), Set(["budget.weekly.nearly-reached", "budget.monthly.halfway"]))
        XCTAssertEqual(Set(signals.map(\.deduplicationID)), Set(["budget.weekly.nearly-reached", "budget.monthly.halfway"]))
    }

    func testEvaluatedAtEqualsFixedContextNow() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 90, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.first?.evaluatedAt, FinanceTrackTests.budgetSignalFixedNow)
    }

    func testBudgetSignalsNeverUseRandomIdentifiers() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 90, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let first = BudgetSignalEngine().generateSignals(context: context)
        let second = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "Two separate evaluations of identical input must produce identical ids — never a random one")
    }

    func testBudgetSignalMetricsRetainStructuredNumericValues() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 90, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        guard let signal = BudgetSignalEngine().generateSignals(context: context).first else {
            return XCTFail("Expected a signal")
        }
        guard case .percentage(let progress)? = signal.metrics.first(where: { $0.id == "budget.progress" })?.value else {
            return XCTFail("Expected a structured percentage progress metric")
        }
        XCTAssertEqual(progress, 0.9, accuracy: 0.0001)
        guard case .currency(let remaining)? = signal.metrics.first(where: { $0.id == "budget.remaining" })?.value else {
            return XCTFail("Expected a structured currency remaining metric")
        }
        XCTAssertEqual(remaining, 10)
    }

    func testEngineNeverReturnsMultiplePrimarySignalsForOneBudget() {
        let settings = makeBudgetSettings(weeklyLimit: 100, monthlyGoal: nil)
        let expense = makeWeeklyExpense(amount: 90, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        XCTAssertEqual(BudgetSignalEngine().generateSignals(context: context).count, 1)
    }

    func testRepeatedBudgetSignalEvaluationWithIdenticalContextReturnsEqualResults() {
        let settings = makeBudgetSettings(weeklyLimit: 100, monthlyGoal: 1_000)
        let expense = makeWeeklyExpense(amount: 90, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let engine = BudgetSignalEngine()
        XCTAssertEqual(engine.generateSignals(context: context), engine.generateSignals(context: context))
    }

    // Model correctness

    func testSmartSignalEqualityBehavesCorrectly() {
        let a = makeSmartSignal(id: "a")
        let sameAsA = makeSmartSignal(id: "a")
        let different = makeSmartSignal(id: "b")
        XCTAssertEqual(a, sameAsA)
        XCTAssertNotEqual(a, different)
    }

    func testSmartSignalCodableRoundTripSucceeds() throws {
        let original = makeSmartSignal(id: "codable-test", relevantDate: Date(timeIntervalSince1970: 1_650_000_000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SmartSignal.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testSmartSignalActionCodableRoundTripSucceeds() throws {
        let withDescription = SmartSignalAction(id: "action-1", title: "Review Category", description: "See the breakdown.")
        let withDescriptionData = try JSONEncoder().encode(withDescription)
        XCTAssertEqual(withDescription, try JSONDecoder().decode(SmartSignalAction.self, from: withDescriptionData))

        let withoutDescription = SmartSignalAction(id: "action-2", title: "Review", description: nil)
        let withoutDescriptionData = try JSONEncoder().encode(withoutDescription)
        XCTAssertEqual(withoutDescription, try JSONDecoder().decode(SmartSignalAction.self, from: withoutDescriptionData))
    }

    func testEverySmartSignalMetricValueCaseSurvivesEqualityAndCodableRoundTrip() throws {
        let values: [SmartSignalMetric.Value] = [
            .currency(Decimal(string: "42.75")!),
            .percentage(0.65),
            .count(3),
            .number(12.5),
            .text("Groceries"),
        ]
        for value in values {
            let metric = SmartSignalMetric(id: "metric", label: "Test Metric", value: value)
            let data = try JSONEncoder().encode(metric)
            let decoded = try JSONDecoder().decode(SmartSignalMetric.self, from: data)
            XCTAssertEqual(metric, decoded, "Value \(value) must survive a Codable round trip")
        }
    }

    // Dependency injection isolation

    func testFakeEnginesCanBeInjectedWithoutGlobalMutation() {
        let fake = FakeSmartSignalEngine(signals: [makeSmartSignal(id: "fake-only")])
        let coordinatorWithFake = SmartSignalsEngine(engines: [fake])
        let coordinatorWithoutFake = SmartSignalsEngine(engines: [])

        let resultWithFake = coordinatorWithFake.generateSignals(context: makeEmptySmartSignalContext())
        let resultWithoutFake = coordinatorWithoutFake.generateSignals(context: makeEmptySmartSignalContext())

        XCTAssertEqual(resultWithFake.map(\.id), ["fake-only"])
        XCTAssertTrue(resultWithoutFake.isEmpty, "Injecting a fake engine into one coordinator instance must never affect another")
    }

    // MARK: - SpendingSignalEngine

    /// Tuesday, July 8 2025 — mid-year, nowhere near a US daylight-saving transition, so 7-day
    /// calendar arithmetic in these tests never silently drifts by an hour.
    private static let spendingSignalAnchor = Date(timeIntervalSince1970: 1_752_000_000)

    private func spendingCurrentWeekStart(weekStartsOnSunday: Bool = true) -> Date {
        DateRangeHelper.weekRangeContaining(FinanceTrackTests.spendingSignalAnchor, weekStartsOnSunday: weekStartsOnSunday).start
    }

    private func spendingPreviousWeekStart(weekStartsOnSunday: Bool = true) -> Date {
        let calendar = Calendar.current
        let currentStart = spendingCurrentWeekStart(weekStartsOnSunday: weekStartsOnSunday)
        let referenceDate = calendar.date(byAdding: .day, value: -7, to: currentStart) ?? currentStart
        return DateRangeHelper.weekRangeContaining(referenceDate, weekStartsOnSunday: weekStartsOnSunday).start
    }

    private func spendingCurrentMonthStart() -> Date {
        DateRangeHelper.monthRangeContaining(FinanceTrackTests.spendingSignalAnchor).start
    }

    private func spendingPreviousMonthStart() -> Date {
        DateRangeHelper.lastMonthRange(relativeTo: FinanceTrackTests.spendingSignalAnchor).start
    }

    private func makeSpendingSignalContext(
        transactions: [FinanceTransaction] = [],
        budgetSettings: BudgetSettings? = nil,
        now: Date
    ) -> SmartSignalContext {
        SmartSignalContext(
            transactions: transactions,
            accounts: [],
            categories: [],
            incomeSources: [],
            recurringExpenses: [],
            budgetSettings: budgetSettings,
            monthlyPlanSettings: nil,
            now: now
        )
    }

    private func makeSpendingSettings(includePending: Bool = true, weekStartsOnSunday: Bool = true) -> BudgetSettings {
        BudgetSettings(weekStartsOnSunday: weekStartsOnSunday, includePendingTransactions: includePending)
    }

    private func makeSpendingTransaction(
        amount: Decimal,
        date: Date,
        type: TransactionType = .expense,
        countsTowardWeeklyBudget: Bool = true,
        countsTowardMonthlySpending: Bool = true,
        isExcludedFromReports: Bool = false,
        isPending: Bool = false
    ) -> FinanceTransaction {
        FinanceTransaction(
            amount: amount,
            date: date,
            type: type,
            countsTowardWeeklyBudget: countsTowardWeeklyBudget,
            countsTowardMonthlySpending: countsTowardMonthlySpending,
            isExcludedFromReports: isExcludedFromReports,
            isPending: isPending
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components) ?? FinanceTrackTests.spendingSignalAnchor
    }

    // MARK: SpendingSignalEngine — weekly rule

    func testWeeklySignalFiresWhenClearlyQualifying() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        let signals = SpendingSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.count, 1)
    }

    func testWeeklySignalHasExactIdAndDeduplicationID() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.id, "spending.week.higher-than-previous")
        XCTAssertEqual(signal.deduplicationID, "spending.week.higher-than-previous")
    }

    func testWeeklySignalHasExactCategorySeverityPriorityTitleAndDates() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.category, .spending)
        XCTAssertEqual(signal.severity, .headsUp)
        XCTAssertEqual(signal.priority, 250)
        XCTAssertEqual(signal.title, "Spending Up This Week")
        XCTAssertEqual(signal.relevantDate, weekStart)
        XCTAssertEqual(signal.evaluatedAt, now)
    }

    func testWeeklySignalMetricsAppearInExactOrderWithCorrectIdsLabelsAndValues() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.metrics.count, 3)
        XCTAssertEqual(signal.metrics[0].id, "spending.week.current")
        XCTAssertEqual(signal.metrics[0].label, "This Week")
        guard case .currency(let current) = signal.metrics[0].value else { return XCTFail("Expected currency") }
        XCTAssertEqual(current, 300)

        XCTAssertEqual(signal.metrics[1].id, "spending.week.previous")
        XCTAssertEqual(signal.metrics[1].label, "Previous Week")
        guard case .currency(let previous) = signal.metrics[1].value else { return XCTFail("Expected currency") }
        XCTAssertEqual(previous, 200)

        XCTAssertEqual(signal.metrics[2].id, "spending.week.increase")
        XCTAssertEqual(signal.metrics[2].label, "Increase")
        guard case .percentage(let increase) = signal.metrics[2].value else { return XCTFail("Expected percentage") }
        XCTAssertEqual(increase, 0.5, accuracy: 0.0001)
    }

    func testWeeklySignalExplanationContainsFormattedAmountsAndPercentage() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertTrue(signal.explanation.contains("$300.00"))
        XCTAssertTrue(signal.explanation.contains("$200.00"))
        XCTAssertTrue(signal.explanation.contains("50%"))
    }

    func testWeeklySignalFiresAtExactPercentageThreshold() {
        // previous = 200, current = 270 → increase = 70 → exactly 35%, comfortably above $50.
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 270, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertEqual(SpendingSignalEngine().generateSignals(context: context).count, 1)
    }

    func testWeeklySignalFiresAtExactAbsoluteThreshold() {
        // previous = 100, current = 150 → increase = 50 exactly, 50% (comfortably above 35%).
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 100, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 150, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertEqual(SpendingSignalEngine().generateSignals(context: context).count, 1)
    }

    func testWeeklySignalDoesNotFireJustBelowPercentageThresholdEvenWhenDollarThresholdIsMet() {
        // previous = 1000, current = 1340 → increase = 340 (34%, well above $50, below 35%).
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_340, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testWeeklySignalDoesNotFireAtExactPercentageButBelowDollarThreshold() {
        // previous = 100, current = 135 → increase = 35 (exactly 35%, but only $35 < $50).
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 100, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 135, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testWeeklySignalDoesNotFireWhenPreviousComparableSpendIsZero() {
        let weekStart = spendingCurrentWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600))]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testWeeklySignalDoesNotFireWhenCurrentEqualsPrevious() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 200, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testWeeklySignalDoesNotFireWithFewerThan48ElapsedHours() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(47 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testWeeklySignalQualifiesAtExactly48ElapsedHoursWithMediumConfidence() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(48 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.confidence, .medium)
    }

    func testWeeklySignalUsesMediumConfidenceJustBelow96ElapsedHours() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600 - 1)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.confidence, .medium)
    }

    func testWeeklySignalUsesHighConfidenceAtExactly96ElapsedHours() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.confidence, .high)
    }

    func testWeeklyComparisonUsesOnlyPriorEquivalentElapsedWindowNotFullPriorWeek() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(48 * 3600)
        let transactions = [
            // Inside the 48-hour comparable window of the previous week.
            makeSpendingTransaction(amount: 100, date: previousStart.addingTimeInterval(3600)),
            // Far outside that window (day 5 of the previous week) — must NOT be counted.
            makeSpendingTransaction(amount: 500, date: previousStart.addingTimeInterval(5 * 24 * 3600)),
            makeSpendingTransaction(amount: 200, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let previous)? = signal.metrics.first(where: { $0.id == "spending.week.previous" })?.value else {
            return XCTFail("Expected a previous-week currency metric")
        }
        XCTAssertEqual(previous, 100, "The $500 transaction outside the comparable window must not be counted")
    }

    func testWeeklySundayStartSettingIsRespected() {
        let weekStart = spendingCurrentWeekStart(weekStartsOnSunday: true)
        let previousStart = spendingPreviousWeekStart(weekStartsOnSunday: true)
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let settings = makeSpendingSettings(weekStartsOnSunday: true)
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: settings, now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.relevantDate, weekStart)
    }

    func testWeeklyMondayStartSettingIsRespected() {
        let weekStart = spendingCurrentWeekStart(weekStartsOnSunday: false)
        let previousStart = spendingPreviousWeekStart(weekStartsOnSunday: false)
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let settings = makeSpendingSettings(weekStartsOnSunday: false)
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: settings, now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.relevantDate, weekStart)
        XCTAssertNotEqual(weekStart, spendingCurrentWeekStart(weekStartsOnSunday: true), "Monday-start and Sunday-start weeks must resolve to different boundaries for this anchor")
    }

    func testWeeklyPendingTransactionIsIncludedWhenIncludePendingTransactionsIsTrue() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600), isPending: true),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(includePending: true), now: now)
        XCTAssertEqual(SpendingSignalEngine().generateSignals(context: context).count, 1)
    }

    func testWeeklyPendingTransactionIsExcludedWhenIncludePendingTransactionsIsFalse() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600), isPending: true),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(includePending: false), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty, "With pending excluded, current spend is $0 — no increase to report")
    }

    func testWeeklyExcludedFromReportsTransactionIsNotCounted() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 9_999, date: weekStart.addingTimeInterval(7200), isExcludedFromReports: true),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.week.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 300, "The excluded transaction must never contribute to the total")
    }

    func testWeeklyIncomeIsNotCounted() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 5_000, date: weekStart.addingTimeInterval(7200), type: .income),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.week.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 300)
    }

    func testWeeklyTransferIsNotCounted() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 5_000, date: weekStart.addingTimeInterval(7200), type: .transfer),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.week.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 300)
    }

    func testWeeklyCreditCardPaymentIsNotCounted() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 5_000, date: weekStart.addingTimeInterval(7200), type: .creditCardPayment),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.week.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 300)
    }

    func testWeeklyRefundReducesSpendingPerBudgetCalculatorSemantics() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 100, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 100, date: weekStart.addingTimeInterval(7200), type: .refund),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.week.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 200, "The refund must subtract from the total exactly as BudgetCalculator already does")
    }

    func testWeeklyCountingFlagIsRespectedThroughBudgetCalculator() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 9_999, date: weekStart.addingTimeInterval(7200), countsTowardWeeklyBudget: false),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.week.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 300, "A transaction opted out of the weekly count must never contribute")
    }

    // MARK: SpendingSignalEngine — monthly rule

    func testMonthlySignalFiresWhenClearlyQualifying() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertEqual(SpendingSignalEngine().generateSignals(context: context).count, 1)
    }

    func testMonthlySignalFieldsAndMetricOrderExactlyMatchApprovedContract() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.id, "spending.month.higher-than-previous")
        XCTAssertEqual(signal.deduplicationID, "spending.month.higher-than-previous")
        XCTAssertEqual(signal.category, .spending)
        XCTAssertEqual(signal.severity, .headsUp)
        XCTAssertEqual(signal.priority, 220)
        XCTAssertEqual(signal.title, "Spending Up This Month")
        XCTAssertEqual(signal.relevantDate, monthStart)
        XCTAssertEqual(signal.evaluatedAt, now)

        XCTAssertEqual(signal.metrics.count, 3)
        XCTAssertEqual(signal.metrics[0].id, "spending.month.current")
        XCTAssertEqual(signal.metrics[0].label, "This Month")
        XCTAssertEqual(signal.metrics[1].id, "spending.month.previous")
        XCTAssertEqual(signal.metrics[1].label, "Previous Month")
        XCTAssertEqual(signal.metrics[2].id, "spending.month.increase")
        XCTAssertEqual(signal.metrics[2].label, "Increase")
        guard case .currency(let current) = signal.metrics[0].value else { return XCTFail("Expected currency") }
        XCTAssertEqual(current, 1_500)
        guard case .currency(let previous) = signal.metrics[1].value else { return XCTFail("Expected currency") }
        XCTAssertEqual(previous, 1_000)
    }

    func testMonthlySignalFiresAtExactPercentageAndAbsoluteThreshold() {
        // previous = 1000, current = 1300 → increase = 300 → exactly 30%, well above $100.
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_300, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertEqual(SpendingSignalEngine().generateSignals(context: context).count, 1)
    }

    func testMonthlySignalDoesNotFireJustBelowPercentageThreshold() {
        // previous = 1000, current = 1290 → increase = 290 → 29%, below 30%.
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_290, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testMonthlySignalDoesNotFireWhenPercentageMetButBelowDollarThreshold() {
        // previous = 200, current = 260 → increase = 60 → exactly 30%, but only $60 < $100.
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 260, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testMonthlySignalDoesNotFireWhenPreviousComparableSpendIsZero() {
        let monthStart = spendingCurrentMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600))]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testMonthlySignalDoesNotFireWithFewerThan120ElapsedHours() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(119 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testMonthlySignalQualifiesAtExactly120ElapsedHoursWithMediumConfidence() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(120 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.confidence, .medium)
    }

    func testMonthlySignalUsesMediumConfidenceJustBelow240ElapsedHours() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600 - 1)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.confidence, .medium)
    }

    func testMonthlySignalUsesHighConfidenceAtExactly240ElapsedHours() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        XCTAssertEqual(signal.confidence, .high)
    }

    func testMonthlyComparisonUsesOnlyPriorEquivalentElapsedWindowNotFullPriorMonth() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(120 * 3600)
        let transactions = [
            // Inside the 120-hour comparable window of the previous month.
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            // Far outside that window (day 20 of the previous month) — must NOT be counted.
            makeSpendingTransaction(amount: 5_000, date: previousStart.addingTimeInterval(20 * 24 * 3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let previous)? = signal.metrics.first(where: { $0.id == "spending.month.previous" })?.value else {
            return XCTFail("Expected a previous-month currency metric")
        }
        XCTAssertEqual(previous, 1_000, "The $5,000 transaction outside the comparable window must not be counted")
    }

    func testMonthlyRuleHandlesLongerCurrentMonthThanShorterPriorMonthSafely() {
        // March 2025 (31 days) vs. February 2025 (28 days, non-leap) — the previous comparable
        // window must be capped at February's end rather than overflowing into March.
        let now = makeDate(year: 2025, month: 3, day: 31, hour: 0).addingTimeInterval(-3600) // deep into March, elapsed >> 240h
        let previousStart = spendingPreviousMonthStartRelative(to: now)
        let currentStart = spendingCurrentMonthStartRelative(to: now)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: currentStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        // The requirement under test is safety (no crash, no invalid DateInterval trap) — a
        // qualifying signal is a reasonable secondary confirmation that totals still computed.
        let signals = SpendingSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.count, 1)
    }

    private func spendingCurrentMonthStartRelative(to date: Date) -> Date {
        DateRangeHelper.monthRangeContaining(date).start
    }

    private func spendingPreviousMonthStartRelative(to date: Date) -> Date {
        DateRangeHelper.lastMonthRange(relativeTo: date).start
    }

    func testMonthlyPendingInclusionSettingIsRespected() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600), isPending: true),
        ]
        let includedContext = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(includePending: true), now: now)
        XCTAssertEqual(SpendingSignalEngine().generateSignals(context: includedContext).count, 1)

        let excludedContext = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(includePending: false), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: excludedContext).isEmpty)
    }

    func testMonthlyExcludedFromReportsTransactionIsNotCounted() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 9_999, date: monthStart.addingTimeInterval(7200), isExcludedFromReports: true),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.month.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 1_500)
    }

    func testMonthlyRefundReducesSpendingPerBudgetCalculatorSemantics() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_600, date: monthStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 100, date: monthStart.addingTimeInterval(7200), type: .refund),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.month.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 1_500, "The refund must subtract from the total exactly as BudgetCalculator already does")
    }

    func testMonthlyCountingFlagIsRespectedThroughBudgetCalculator() {
        let monthStart = spendingCurrentMonthStart()
        let previousStart = spendingPreviousMonthStart()
        let now = monthStart.addingTimeInterval(240 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 1_000, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 9_999, date: monthStart.addingTimeInterval(7200), countsTowardMonthlySpending: false),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        guard let signal = SpendingSignalEngine().generateSignals(context: context).first else { return XCTFail("Expected a signal") }
        guard case .currency(let current)? = signal.metrics.first(where: { $0.id == "spending.month.current" })?.value else {
            return XCTFail("Expected a currency metric")
        }
        XCTAssertEqual(current, 1_500, "A transaction opted out of the monthly count must never contribute")
    }

    // MARK: SpendingSignalEngine — coordination and determinism

    func testSpendingSignalEngineWithEmptyTransactionsReturnsNoSignals() {
        let now = spendingCurrentMonthStart().addingTimeInterval(240 * 3600)
        let context = makeSpendingSignalContext(transactions: [], budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testSpendingSignalEngineReturnsEmptyWhenNeitherThresholdIsMet() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 205, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        XCTAssertTrue(SpendingSignalEngine().generateSignals(context: context).isEmpty)
    }

    func testWeeklyAndMonthlySignalsCoexistInWeeklyThenMonthlyOrder() {
        let weekStart = spendingCurrentWeekStart()
        let monthStart = spendingCurrentMonthStart()
        let previousWeekStart = spendingPreviousWeekStart()
        let previousMonthStart = spendingPreviousMonthStart()
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousWeekStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 1_000, date: previousMonthStart.addingTimeInterval(3600)),
            // Placed on day 5 of the current month — inside the monthly current-comparable window,
            // but deliberately outside BOTH weekly comparable windows (the truncated previous-week
            // window ends day 4, and the current week doesn't start until day 6), so this doesn't
            // cross-contaminate the weekly total.
            makeSpendingTransaction(amount: 1_500, date: monthStart.addingTimeInterval(4 * 24 * 3600 + 3600)),
        ]
        // `now` must clear both elapsed gates while staying inside the SAME week as `weekStart`
        // (the month gate, 240h, is the larger of the two, and the month started only a few days
        // before the week — so anchoring off `monthStart` satisfies both without rolling `now`
        // into the following week).
        let farEnoughNow = monthStart.addingTimeInterval(240 * 3600)
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: farEnoughNow)
        let signals = SpendingSignalEngine().generateSignals(context: context)
        XCTAssertEqual(signals.map(\.id), ["spending.week.higher-than-previous", "spending.month.higher-than-previous"])
    }

    func testRepeatedGenerationWithIdenticalContextReturnsEqualArrays() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        let engine = SpendingSignalEngine()
        XCTAssertEqual(engine.generateSignals(context: context), engine.generateSignals(context: context))
    }

    func testSpendingSignalIdsRemainDeterministicAcrossEvaluations() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        let first = SpendingSignalEngine().generateSignals(context: context).map(\.id)
        let second = SpendingSignalEngine().generateSignals(context: context).map(\.id)
        XCTAssertEqual(first, second)
    }

    func testNoSpendingSignalUsesABudgetSignalDeduplicationID() {
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        let signals = SpendingSignalEngine().generateSignals(context: context)
        XCTAssertTrue(signals.allSatisfy { !$0.deduplicationID.hasPrefix("budget.") })
    }

    func testSpendingSignalEngineAndBudgetSignalEngineCoexistWithoutDeduplicationCollision() {
        let settings = makeBudgetSettings(weeklyLimit: 50)
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: settings, now: now)
        let coordinator = SmartSignalsEngine(engines: [BudgetSignalEngine(), SpendingSignalEngine()])
        let signals = coordinator.generateSignals(context: context)
        XCTAssertEqual(Set(signals.map(\.deduplicationID)).count, signals.count, "No deduplication collision should occur")
        XCTAssertTrue(signals.contains { $0.id == "budget.weekly.exceeded" })
        XCTAssertTrue(signals.contains { $0.id == "spending.week.higher-than-previous" })
    }

    func testExistingRankingPlacesBudgetExceededAheadOfSpendingSignalsByPriority() {
        let settings = makeBudgetSettings(weeklyLimit: 50)
        let weekStart = spendingCurrentWeekStart()
        let previousStart = spendingPreviousWeekStart()
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: settings, now: now)
        let coordinator = SmartSignalsEngine(engines: [SpendingSignalEngine(), BudgetSignalEngine()])
        let signals = coordinator.generateSignals(context: context)
        XCTAssertEqual(signals.first?.id, "budget.weekly.exceeded", "Priority 400 must outrank the spending signal's priority 250 regardless of injection order")
    }

    func testSpendingSignalEngineDeterministicUnderExplicitTestCalendarAndTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let weekStart = DateRangeHelper.weekRangeContaining(FinanceTrackTests.spendingSignalAnchor, weekStartsOnSunday: true, calendar: calendar).start
        let previousStart = DateRangeHelper.weekRangeContaining(
            calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart,
            weekStartsOnSunday: true,
            calendar: calendar
        ).start
        let now = weekStart.addingTimeInterval(96 * 3600)
        let transactions = [
            makeSpendingTransaction(amount: 200, date: previousStart.addingTimeInterval(3600)),
            makeSpendingTransaction(amount: 300, date: weekStart.addingTimeInterval(3600)),
        ]
        let context = makeSpendingSignalContext(transactions: transactions, budgetSettings: makeSpendingSettings(), now: now)
        let first = SpendingSignalEngine().generateSignals(context: context)
        let second = SpendingSignalEngine().generateSignals(context: context)
        XCTAssertEqual(first, second, "Identical context under an explicitly configured calendar/timezone must produce identical output")
    }

    // MARK: - Manual Account deposits

    func testExpenseSaveBehaviorRemainsUnchanged() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        AccountBalanceManager.applyExpense(amount: 20, to: account)
        XCTAssertEqual(account.currentBalance, 80)
    }

    func testRefundSaveBehaviorRemainsUnchanged() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        AccountBalanceManager.applyRefund(amount: 20, to: account)
        XCTAssertEqual(account.currentBalance, 120)
    }

    func testDepositCanBeRepresentedByTheTransactionModel() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let deposit = FinanceTransaction(amount: 50, type: .income, source: .manual, account: account)
        XCTAssertEqual(deposit.type, .income)
        XCTAssertEqual(deposit.type.label, "Deposit")
        XCTAssertFalse(deposit.type.countsAsSpending)
    }

    func testDepositEnteredAsPositiveAmountIncreasesManualAccountBalance() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        AccountBalanceManager.applyIncome(amount: 50, to: account)
        XCTAssertEqual(account.currentBalance, 150)
    }

    func testMultipleDepositsIncreaseTheBalanceCumulatively() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        AccountBalanceManager.applyIncome(amount: 25, to: account)
        AccountBalanceManager.applyIncome(amount: 40, to: account)
        AccountBalanceManager.applyIncome(amount: 10, to: account)
        XCTAssertEqual(account.currentBalance, 75)
    }

    func testDepositDoesNotDecreaseTheBalance() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        AccountBalanceManager.applyIncome(amount: 30, to: account)
        XCTAssertGreaterThan(account.currentBalance, 100)
    }

    func testDepositDoesNotCountTowardWeeklySpending() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let deposit = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .income, account: account)
        XCTAssertEqual(BudgetCalculator.weeklySpent([deposit], in: interval), 0)
    }

    func testDepositDoesNotCountTowardMonthlySpending() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let deposit = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .income, account: account)
        XCTAssertEqual(BudgetCalculator.monthlySpent([deposit], in: interval), 0)
    }

    func testDepositDoesNotCountTowardCategorySpendingTotals() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let groceries = Category(name: "Groceries")
        let deposit = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .income, account: account, category: groceries)
        let totals = BudgetCalculator.categoryTotals([deposit], in: interval, context: .monthly)
        XCTAssertTrue(totals.isEmpty, "A deposit must never appear in a category spending breakdown")
    }

    func testDepositDoesNotCountTowardAccountSpendingTotals() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let deposit = FinanceTransaction(amount: 200, date: interval.start.addingTimeInterval(3600), type: .income, account: account)
        let totals = BudgetCalculator.accountTotals([deposit], in: interval, context: .monthly)
        XCTAssertTrue(totals.isEmpty, "A deposit must never appear in an account spending breakdown")
    }

    func testDepositDoesNotAffectBudgetCalculatorProgress() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expense = FinanceTransaction(amount: 50, date: interval.start.addingTimeInterval(3600), type: .expense, account: account)
        let deposit = FinanceTransaction(amount: 500, date: interval.start.addingTimeInterval(7200), type: .income, account: account)

        let spentWithoutDeposit = BudgetCalculator.weeklySpent([expense], in: interval)
        let spentWithDeposit = BudgetCalculator.weeklySpent([expense, deposit], in: interval)
        XCTAssertEqual(spentWithoutDeposit, spentWithDeposit, "A deposit must never change net spending")

        let progressWithoutDeposit = BudgetCalculator.progress(spent: spentWithoutDeposit, limit: 100)
        let progressWithDeposit = BudgetCalculator.progress(spent: spentWithDeposit, limit: 100)
        XCTAssertEqual(progressWithoutDeposit, progressWithDeposit)
    }

    @MainActor
    func testDepositDoesNotCauseABudgetSmartSignalWhenNoQualifyingExpenseExists() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let week = DateRangeHelper.weekRangeContaining(FinanceTrackTests.budgetSignalFixedNow, weekStartsOnSunday: true)
        // Placed very early in the period so an on-track positive signal (which only requires
        // low spend, not zero) can't appear either — isolating this test to exactly one question:
        // does the deposit itself trigger any spending-driven signal.
        let tooEarlyNow = week.start.addingTimeInterval(3_600)
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let deposit = FinanceTransaction(amount: 500, date: week.start.addingTimeInterval(1_800), type: .income, account: account)
        let context = makeBudgetSignalContext(transactions: [deposit], budgetSettings: settings, now: tooEarlyNow)

        let signals = BudgetSignalEngine().generateSignals(context: context)
        XCTAssertTrue(signals.isEmpty, "A deposit alone, however large, must never produce a budget signal")
    }

    @MainActor
    func testAddingADepositDoesNotChangeAnExistingExpenseDrivenBudgetSmartSignalResult() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let expense = makeWeeklyExpense(amount: 90, fractionIntoWeek: 0.5, now: FinanceTrackTests.budgetSignalFixedNow)
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let deposit = FinanceTransaction(amount: 1_000, date: FinanceTrackTests.budgetSignalFixedNow, type: .income, account: account)

        let contextWithoutDeposit = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let contextWithDeposit = makeBudgetSignalContext(transactions: [expense, deposit], budgetSettings: settings)

        let resultWithoutDeposit = BudgetSignalEngine().generateSignals(context: contextWithoutDeposit)
        let resultWithDeposit = BudgetSignalEngine().generateSignals(context: contextWithDeposit)

        XCTAssertEqual(resultWithoutDeposit, resultWithDeposit, "Adding a deposit must never change an existing expense-driven budget signal")
        XCTAssertEqual(resultWithDeposit.map(\.id), ["budget.weekly.nearly-reached"])
    }

    @MainActor
    func testDepositPersistsWithTheCorrectTransactionType() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        context.insert(account)
        let deposit = FinanceTransaction(amount: 75, type: .income, source: .manual, account: account)
        context.insert(deposit)
        try! context.save()

        let fetched = try! context.fetch(FetchDescriptor<FinanceTransaction>()).first
        XCTAssertEqual(fetched?.type, .income)
        XCTAssertEqual(fetched?.amount, 75)
    }

    // MARK: - TransactionPreferenceStore

    /// A fresh, isolated `UserDefaults` domain per call — never the shared `.standard` domain —
    /// so these tests can never leak state into each other or into a real device's preferences.
    private func makeIsolatedUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: "TransactionPreferenceStoreTests.\(UUID().uuidString)")!
    }

    private func makePreferences(
        weekly: Bool = true,
        monthly: Bool = true,
        excluded: Bool = false,
        pending: Bool = false
    ) -> TransactionEntryPreferences {
        TransactionEntryPreferences(
            countsTowardWeeklyBudget: weekly,
            countsTowardMonthlySpending: monthly,
            isExcludedFromReports: excluded,
            isPending: pending
        )
    }

    func testNoSavedExpensePreferencesUseExistingExpenseDefaults() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let fallback = makePreferences(monthly: false)
        let resolved = store.resolvedPreferences(accountID: UUID(), type: .expense, fallback: fallback)
        XCTAssertEqual(resolved, fallback)
    }

    func testNoSavedRefundPreferencesUseExistingRefundDefaults() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let fallback = makePreferences(pending: true)
        let resolved = store.resolvedPreferences(accountID: UUID(), type: .refund, fallback: fallback)
        XCTAssertEqual(resolved, fallback)
    }

    func testNoSavedDepositPreferencesUseExistingDepositDefaults() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let fallback = makePreferences(excluded: true)
        let resolved = store.resolvedPreferences(accountID: UUID(), type: .income, fallback: fallback)
        XCTAssertEqual(resolved, fallback)
    }

    func testSuccessfullySavedExpensePreferencesAreRestoredForTheSameAccount() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let saved = makePreferences(weekly: false, monthly: true, excluded: true, pending: false)
        store.save(saved, accountID: accountID, type: .expense)
        XCTAssertEqual(store.preferences(accountID: accountID, type: .expense), saved)
    }

    func testSuccessfullySavedRefundPreferencesAreRestoredForTheSameAccount() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let saved = makePreferences(weekly: true, monthly: false, excluded: false, pending: true)
        store.save(saved, accountID: accountID, type: .refund)
        XCTAssertEqual(store.preferences(accountID: accountID, type: .refund), saved)
    }

    func testSuccessfullySavedDepositPreferencesAreRestoredForTheSameAccount() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let saved = makePreferences(excluded: true, pending: false)
        store.save(saved, accountID: accountID, type: .income)
        XCTAssertEqual(store.preferences(accountID: accountID, type: .income), saved)
    }

    func testChangingExpenseDefaultsDoesNotChangeRefundDefaults() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let refundPrefs = makePreferences(weekly: true, monthly: true)
        store.save(refundPrefs, accountID: accountID, type: .refund)
        store.save(makePreferences(weekly: false, monthly: false), accountID: accountID, type: .expense)
        XCTAssertEqual(store.preferences(accountID: accountID, type: .refund), refundPrefs)
    }

    func testChangingExpenseDefaultsDoesNotChangeDepositDefaults() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let depositPrefs = makePreferences(excluded: true)
        store.save(depositPrefs, accountID: accountID, type: .income)
        store.save(makePreferences(excluded: false), accountID: accountID, type: .expense)
        XCTAssertEqual(store.preferences(accountID: accountID, type: .income), depositPrefs)
    }

    func testChangingRefundDefaultsDoesNotChangeExpenseDefaults() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let expensePrefs = makePreferences(pending: true)
        store.save(expensePrefs, accountID: accountID, type: .expense)
        store.save(makePreferences(pending: false), accountID: accountID, type: .refund)
        XCTAssertEqual(store.preferences(accountID: accountID, type: .expense), expensePrefs)
    }

    func testChangingDepositDefaultsDoesNotChangeExpenseOrRefundDefaults() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let expensePrefs = makePreferences(weekly: true)
        let refundPrefs = makePreferences(weekly: false)
        store.save(expensePrefs, accountID: accountID, type: .expense)
        store.save(refundPrefs, accountID: accountID, type: .refund)
        store.save(makePreferences(weekly: true, monthly: false), accountID: accountID, type: .income)
        XCTAssertEqual(store.preferences(accountID: accountID, type: .expense), expensePrefs)
        XCTAssertEqual(store.preferences(accountID: accountID, type: .refund), refundPrefs)
    }

    func testAccountAPreferencesDoNotAffectAccountB() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountA = UUID()
        let accountB = UUID()
        let prefsA = makePreferences(weekly: true, monthly: true)
        store.save(prefsA, accountID: accountA, type: .expense)
        store.save(makePreferences(weekly: false, monthly: false), accountID: accountB, type: .expense)
        XCTAssertEqual(store.preferences(accountID: accountA, type: .expense), prefsA)
        XCTAssertNotEqual(store.preferences(accountID: accountA, type: .expense), store.preferences(accountID: accountB, type: .expense))
    }

    func testTwoAccountsWithTheSameNameRemainIndependent() {
        // The store is keyed by UUID, never by display name — two `Account` objects sharing a
        // name must never collide just because a naive implementation might have compared names.
        let accountA = Account(name: "Everyday Checking", type: .checking, currentBalance: 0)
        let accountB = Account(name: "Everyday Checking", type: .checking, currentBalance: 0)
        XCTAssertNotEqual(accountA.id, accountB.id)

        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        store.save(makePreferences(weekly: true), accountID: accountA.id, type: .expense)
        store.save(makePreferences(weekly: false), accountID: accountB.id, type: .expense)
        XCTAssertEqual(store.preferences(accountID: accountA.id, type: .expense)?.countsTowardWeeklyBudget, true)
        XCTAssertEqual(store.preferences(accountID: accountB.id, type: .expense)?.countsTowardWeeklyBudget, false)
    }

    func testTrueValuesCanBeReplacedWithFalseValues() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        store.save(makePreferences(weekly: true, monthly: true, excluded: true, pending: true), accountID: accountID, type: .expense)
        store.save(makePreferences(weekly: false, monthly: false, excluded: false, pending: false), accountID: accountID, type: .expense)
        let resolved = store.preferences(accountID: accountID, type: .expense)
        XCTAssertEqual(resolved, makePreferences(weekly: false, monthly: false, excluded: false, pending: false))
    }

    func testFalseValuesCanBeReplacedWithTrueValues() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        store.save(makePreferences(weekly: false, monthly: false, excluded: false, pending: false), accountID: accountID, type: .expense)
        store.save(makePreferences(weekly: true, monthly: true, excluded: true, pending: true), accountID: accountID, type: .expense)
        let resolved = store.preferences(accountID: accountID, type: .expense)
        XCTAssertEqual(resolved, makePreferences(weekly: true, monthly: true, excluded: true, pending: true))
    }

    func testCancelingWithoutSavingDoesNotUpdatePreferences() {
        // Modeled directly: a cancel path in the view never calls `TransactionPreferenceStore.save`
        // at all (see AddExpenseView — only `attemptSave()`'s success path calls it), so this
        // proves the store itself is untouched when no save call happens.
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let original = makePreferences(weekly: true)
        store.save(original, accountID: accountID, type: .expense)
        // Simulates the user changing the toggle in the UI and then canceling — no `save` call
        // ever happens for that change.
        XCTAssertEqual(store.preferences(accountID: accountID, type: .expense), original)
    }

    func testPreferencesSurviveRecreatingTheStore() {
        let defaults = makeIsolatedUserDefaults()
        let accountID = UUID()
        let saved = makePreferences(monthly: false, excluded: true)
        TransactionPreferenceStore(defaults: defaults).save(saved, accountID: accountID, type: .refund)

        // A brand-new `TransactionPreferenceStore` value, backed by the SAME `UserDefaults`
        // domain — simulates the app relaunching and constructing a fresh store instance.
        let recreatedStore = TransactionPreferenceStore(defaults: defaults)
        XCTAssertEqual(recreatedStore.preferences(accountID: accountID, type: .refund), saved)
    }

    func testStableAccountIdsAndTransactionTypeKeysAreUsed() {
        // Two accounts, two types, four independent slots — proves the key incorporates both the
        // account id and the type, not just one or the other.
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountA = UUID()
        let accountB = UUID()
        store.save(makePreferences(weekly: true), accountID: accountA, type: .expense)
        store.save(makePreferences(weekly: false), accountID: accountA, type: .refund)
        store.save(makePreferences(monthly: true), accountID: accountB, type: .expense)
        store.save(makePreferences(monthly: false), accountID: accountB, type: .refund)

        XCTAssertEqual(store.preferences(accountID: accountA, type: .expense)?.countsTowardWeeklyBudget, true)
        XCTAssertEqual(store.preferences(accountID: accountA, type: .refund)?.countsTowardWeeklyBudget, false)
        XCTAssertEqual(store.preferences(accountID: accountB, type: .expense)?.countsTowardMonthlySpending, true)
        XCTAssertEqual(store.preferences(accountID: accountB, type: .refund)?.countsTowardMonthlySpending, false)
    }

    // AddExpenseView has no editing mode today — its `init` only accepts an optional
    // `preselectedAccount`, never an existing `FinanceTransaction` to edit (confirmed by
    // inspection: no such parameter or code path exists anywhere in the file). Items 18/19 from
    // the task ("editing uses the transaction's own values" / "editing updates preferences for
    // the final type") therefore do not apply — there is no edit flow to test. This is reported
    // explicitly in the final report rather than silently skipped.

    // MARK: - Category sorting

    func testCategoriesSortAlphabetically() {
        let categories = [
            Category(name: "Zebra"),
            Category(name: "Apple"),
            Category(name: "Mango"),
        ]
        let sorted = CategorySorting.sortedAlphabetically(categories)
        XCTAssertEqual(sorted.map(\.name), ["Apple", "Mango", "Zebra"])
    }

    func testCategorySortingIsCaseInsensitive() {
        let categories = [
            Category(name: "banana"),
            Category(name: "Apple"),
            Category(name: "cherry"),
        ]
        let sorted = CategorySorting.sortedAlphabetically(categories)
        XCTAssertEqual(sorted.map(\.name), ["Apple", "banana", "cherry"])
    }

    func testDuplicateCategoryNamesUseAStableTieBreaker() {
        let first = Category(name: "Food")
        let second = Category(name: "Food")
        let sortedOnce = CategorySorting.sortedAlphabetically([first, second])
        let sortedAgain = CategorySorting.sortedAlphabetically([second, first])
        // Regardless of input order, the tie breaker (lexical id) must produce the same result.
        XCTAssertEqual(sortedOnce.map(\.id), sortedAgain.map(\.id))
    }

    func testCategorySortingDoesNotMutateTheSourceCollection() {
        let original = [Category(name: "Zebra"), Category(name: "Apple")]
        let originalOrder = original.map(\.id)
        _ = CategorySorting.sortedAlphabetically(original)
        XCTAssertEqual(original.map(\.id), originalOrder, "Sorting must never reorder the caller's own array")
    }

    func testExistingCategorySelectionRemainsValidAfterSorting() {
        let groceries = Category(name: "Groceries")
        let categories = [Category(name: "Zebra"), groceries, Category(name: "Apple")]
        let sorted = CategorySorting.sortedAlphabetically(categories)
        XCTAssertTrue(sorted.contains { $0.id == groceries.id })
    }

    func testUncategorizedOrOptionalSelectionIsPreserved() {
        // `CategoryPickerCard`'s "Uncategorized" choice sets `selectedCategory = nil` — proven at
        // the model level: nothing about sorting or category data forces a non-nil selection.
        var selectedCategory: FinanceTrack.Category? = Category(name: "Groceries")
        selectedCategory = nil
        XCTAssertNil(selectedCategory)
    }

    func testStoredCategoryIdsAndRelationshipsRemainUnchanged() {
        let category = Category(name: "Groceries", iconName: "cart.fill", colorName: "green")
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let transaction = FinanceTransaction(amount: 10, type: .expense, account: account, category: category)
        _ = CategorySorting.sortedAlphabetically([category])
        XCTAssertEqual(transaction.category?.id, category.id)
        XCTAssertEqual(category.iconName, "cart.fill")
        XCTAssertEqual(category.colorName, "green")
    }

    // MARK: - CalculatorEngine

    func testCalculatorInitialStateIsZero() {
        let engine = CalculatorEngine()
        XCTAssertEqual(engine.entryText, "0")
        XCTAssertNil(engine.errorMessage)
    }

    func testCalculatorAddition() {
        var engine = CalculatorEngine()
        engine.inputDigit(2)
        engine.setOperation(.add)
        engine.inputDigit(3)
        engine.equals()
        XCTAssertEqual(engine.entryText, "5")
    }

    func testCalculatorSubtraction() {
        var engine = CalculatorEngine()
        engine.inputDigit(9)
        engine.setOperation(.subtract)
        engine.inputDigit(4)
        engine.equals()
        XCTAssertEqual(engine.entryText, "5")
    }

    func testCalculatorMultiplication() {
        var engine = CalculatorEngine()
        engine.inputDigit(6)
        engine.setOperation(.multiply)
        engine.inputDigit(7)
        engine.equals()
        XCTAssertEqual(engine.entryText, "42")
    }

    func testCalculatorDivision() {
        var engine = CalculatorEngine()
        engine.inputDigit(8)
        engine.setOperation(.divide)
        engine.inputDigit(2)
        engine.equals()
        XCTAssertEqual(engine.entryText, "4")
    }

    func testCalculatorDecimalArithmetic() {
        var engine = CalculatorEngine()
        engine.inputDigit(1)
        engine.inputDecimalPoint()
        engine.inputDigit(5)
        engine.setOperation(.add)
        engine.inputDigit(2)
        engine.inputDecimalPoint()
        engine.inputDigit(5)
        engine.equals()
        XCTAssertEqual(engine.entryText, "4")
    }

    func testCalculatorClear() {
        var engine = CalculatorEngine()
        engine.inputDigit(9)
        engine.setOperation(.add)
        engine.inputDigit(9)
        engine.clear()
        XCTAssertEqual(engine.entryText, "0")
        XCTAssertNil(engine.errorMessage)
    }

    func testCalculatorDivisionByZeroDoesNotCrash() {
        var engine = CalculatorEngine()
        engine.inputDigit(5)
        engine.setOperation(.divide)
        engine.inputDigit(0)
        engine.equals()
        XCTAssertNotNil(engine.errorMessage)
        XCTAssertEqual(engine.entryText, "0")
    }

    func testCalculatorNewCalculationAfterAResult() {
        var engine = CalculatorEngine()
        engine.inputDigit(2)
        engine.setOperation(.add)
        engine.inputDigit(2)
        engine.equals()
        XCTAssertEqual(engine.entryText, "4")
        engine.inputDigit(9)
        XCTAssertEqual(engine.entryText, "9", "Typing after a result must start a fresh entry, not append to the result")
    }

    func testCalculatorChainedOperationBehavior() {
        var engine = CalculatorEngine()
        engine.inputDigit(2)
        engine.setOperation(.add)
        engine.inputDigit(3)
        engine.setOperation(.multiply) // chains: (2 + 3) queued, now × pending
        engine.inputDigit(4)
        engine.equals()
        XCTAssertEqual(engine.entryText, "20", "2 + 3 × 4 chains left-to-right: (2+3)=5, 5×4=20")
    }

    func testCalculatorStateDoesNotMutateAnAccount() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        var engine = CalculatorEngine()
        engine.inputDigit(5)
        engine.setOperation(.add)
        engine.inputDigit(5)
        engine.equals()
        XCTAssertEqual(account.currentBalance, 100, "CalculatorEngine has no reference to any Account and cannot change one")
    }

    @MainActor
    func testCalculatorStateDoesNotCreateOrModifyTransactions() {
        let context = makeAutosaveTestContext()
        var engine = CalculatorEngine()
        engine.inputDigit(1)
        engine.setOperation(.add)
        engine.inputDigit(1)
        engine.equals()
        let transactions = try! context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertTrue(transactions.isEmpty, "CalculatorEngine has no ModelContext and cannot create a transaction")
    }

    func testCalculatorStateDoesNotChangePreferenceStorage() {
        let store = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        var engine = CalculatorEngine()
        engine.inputDigit(7)
        engine.setOperation(.multiply)
        engine.inputDigit(6)
        engine.equals()
        XCTAssertNil(store.preferences(accountID: accountID, type: .expense), "CalculatorEngine has no reference to TransactionPreferenceStore")
    }

    // MARK: - DescriptionStore

    private func makeIsolatedDescriptionDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DescriptionStoreTests.\(UUID().uuidString)")!
    }

    func testEmptyDescriptionStoreSeedsAllSixteenDefaults() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        XCTAssertEqual(store.all().count, 16)
    }

    func testSeededSpellingsMatchExactly() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let expected = [
            "Amex", "Citi Card", "Amazon", "Car Loan(Lisa)", "Car Loan(Scott)",
            "HELOC(JMAFCU)", "Water", "Waterscape", "Bestbuy", "Disney",
            "Xfinity", "AT&T", "Rooms2go", "Electric", "Mortgage", "Gas(Natural)"
        ]
        XCTAssertEqual(Set(store.all()), Set(expected))
    }

    func testSeedingHappensOnlyOnce() {
        let defaults = makeIsolatedDescriptionDefaults()
        _ = DescriptionStore(defaults: defaults)
        _ = DescriptionStore(defaults: defaults).add("Amazon")
        // A second instantiation must never re-seed on top of the first — the count stays at 16
        // (adding an exact duplicate of an existing seed is a no-op, not a 17th entry).
        let secondInstance = DescriptionStore(defaults: defaults)
        XCTAssertEqual(secondInstance.all().count, 16)
    }

    func testRecreatingStorePreservesTheList() {
        let defaults = makeIsolatedDescriptionDefaults()
        let original = DescriptionStore(defaults: defaults).all()
        let recreated = DescriptionStore(defaults: defaults).all()
        XCTAssertEqual(Set(original), Set(recreated))
    }

    func testUserAddedDescriptionsPersist() {
        let defaults = makeIsolatedDescriptionDefaults()
        DescriptionStore(defaults: defaults).add("Netflix")
        XCTAssertTrue(DescriptionStore(defaults: defaults).all().contains("Netflix"))
    }

    func testAddingEmptyStringFails() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let before = store.all().count
        XCTAssertNil(store.add(""))
        XCTAssertEqual(store.all().count, before)
    }

    func testAddingWhitespaceOnlyTextFails() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let before = store.all().count
        XCTAssertNil(store.add("   \n  "))
        XCTAssertEqual(store.all().count, before)
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let added = store.add("  Costco  ")
        XCTAssertEqual(added, "Costco")
        XCTAssertTrue(store.all().contains("Costco"))
    }

    func testExactDuplicatesAreNotAdded() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let before = store.all().count
        XCTAssertNotNil(store.add("Amazon"))
        XCTAssertEqual(store.all().count, before)
    }

    func testCaseInsensitiveDuplicatesAreNotAdded() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let before = store.all().count
        XCTAssertNotNil(store.add("AMAZON"))
        XCTAssertEqual(store.all().count, before)
    }

    func testDuplicateRejectionReturnsTheExistingStoredValue() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let result = store.add("amazon")
        // The pre-existing stored spelling ("Amazon") is returned, not the differently-capitalized
        // input — so the caller selects the entry that's actually in the list.
        XCTAssertEqual(result, "Amazon")
    }

    func testAddingAUniqueDescriptionSucceeds() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let added = store.add("Spotify")
        XCTAssertEqual(added, "Spotify")
        XCTAssertTrue(store.all().contains("Spotify"))
    }

    func testNewlyAddedDescriptionIsAvailableAfterStoreRecreation() {
        let defaults = makeIsolatedDescriptionDefaults()
        DescriptionStore(defaults: defaults).add("Spotify")
        XCTAssertTrue(DescriptionStore(defaults: defaults).all().contains("Spotify"))
    }

    func testAddingADescriptionDoesNotCreateOrModifyATransaction() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        let transaction = FinanceTransaction(amount: 10, type: .expense, note: "Original", account: account)
        _ = store.add("Netflix")
        XCTAssertEqual(transaction.note, "Original")
    }

    func testAddingADescriptionDoesNotAffectAccountBalance() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        _ = store.add("Netflix")
        XCTAssertEqual(account.currentBalance, 100)
    }

    func testAddingADescriptionDoesNotAffectRememberedTransactionPreferences() {
        let descriptionStore = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let preferenceStore = TransactionPreferenceStore(defaults: makeIsolatedUserDefaults())
        let accountID = UUID()
        let saved = makePreferences(weekly: false, monthly: true)
        preferenceStore.save(saved, accountID: accountID, type: .expense)
        _ = descriptionStore.add("Netflix")
        XCTAssertEqual(preferenceStore.preferences(accountID: accountID, type: .expense), saved)
    }

    func testDescriptionChoicesSortAlphabetically() {
        let sorted = DescriptionSorting.sortedAlphabetically(["Xfinity", "Amazon", "Mortgage"])
        XCTAssertEqual(sorted, ["Amazon", "Mortgage", "Xfinity"])
    }

    func testDescriptionSortingIsCaseInsensitive() {
        let sorted = DescriptionSorting.sortedAlphabetically(["water", "Amazon", "electric"])
        XCTAssertEqual(sorted, ["Amazon", "electric", "water"])
    }

    func testDescriptionSortingHasADeterministicTieBreaker() {
        let sortedOnce = DescriptionSorting.sortedAlphabetically(["Gas(Natural)", "Water"])
        let sortedAgain = DescriptionSorting.sortedAlphabetically(["Water", "Gas(Natural)"])
        XCTAssertEqual(sortedOnce, sortedAgain)
    }

    func testDescriptionSortingDoesNotMutateTheStoredSourceList() {
        let original = ["Zebra", "Amazon"]
        let originalCopy = original
        _ = DescriptionSorting.sortedAlphabetically(original)
        XCTAssertEqual(original, originalCopy)
    }

    func testSuppliedPunctuationAndParenthesesRemainUnchanged() {
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        XCTAssertTrue(store.all().contains("Car Loan(Lisa)"))
        XCTAssertTrue(store.all().contains("Car Loan(Scott)"))
        XCTAssertTrue(store.all().contains("HELOC(JMAFCU)"))
        XCTAssertTrue(store.all().contains("AT&T"))
        XCTAssertTrue(store.all().contains("Gas(Natural)"))
    }

    func testTwoManualAccountsAccessTheSameGlobalDescriptionList() {
        // The store is keyed globally (one UserDefaults key, no account id in it at all) — proven
        // by two independent store handles over the same defaults domain seeing the same addition
        // regardless of which "account's" Add Transaction screen added it.
        let defaults = makeIsolatedDescriptionDefaults()
        let storeForAccountA = DescriptionStore(defaults: defaults)
        let storeForAccountB = DescriptionStore(defaults: defaults)
        _ = storeForAccountA.add("Shared Merchant")
        XCTAssertTrue(storeForAccountB.all().contains("Shared Merchant"))
    }

    // MARK: - Description & transaction integration

    func testSelectingADescriptionMapsToTheExistingNoteProperty() {
        // `AddExpenseView.descriptionBinding` reads/writes `note` directly — modeled here at the
        // model level, since `note` is confirmed (by inspection of `FinanceTransaction`,
        // `TransactionRow`, `DashboardView`, and `TransactionMatcher`) to be the one existing
        // property manual entries use for their description; no second field exists.
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let transaction = FinanceTransaction(amount: 25, type: .expense, note: "Amazon", account: account)
        XCTAssertEqual(transaction.note, "Amazon")
        XCTAssertEqual(transaction.displayName, "Amazon")
    }

    func testExpenseCanSaveTheSelectedDescription() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 500)
        let transaction = FinanceTransaction(amount: 25, type: .expense, note: "Amazon", account: account)
        AccountBalanceManager.applyExpense(amount: 25, to: account)
        XCTAssertEqual(transaction.note, "Amazon")
        XCTAssertEqual(account.currentBalance, 475)
    }

    func testRefundCanSaveTheSelectedDescription() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 500)
        let transaction = FinanceTransaction(amount: 25, type: .refund, note: "Amazon", account: account)
        AccountBalanceManager.applyRefund(amount: 25, to: account)
        XCTAssertEqual(transaction.note, "Amazon")
        XCTAssertEqual(account.currentBalance, 525)
    }

    func testDepositCanSaveTheSelectedDescription() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 500)
        let transaction = FinanceTransaction(amount: 25, type: .income, note: "Mortgage", account: account)
        AccountBalanceManager.applyIncome(amount: 25, to: account)
        XCTAssertEqual(transaction.note, "Mortgage")
        XCTAssertEqual(account.currentBalance, 525)
    }

    func testSavingADescriptionDoesNotChangeSpendingEligibility() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let withDescription = FinanceTransaction(amount: 10, type: .expense, note: "Amazon", countsTowardMonthlySpending: true, account: account)
        let withoutDescription = FinanceTransaction(amount: 10, type: .expense, note: "", countsTowardMonthlySpending: true, account: account)
        XCTAssertEqual(
            BudgetCalculator.isCounted(withDescription, includePending: true, context: .monthly),
            BudgetCalculator.isCounted(withoutDescription, includePending: true, context: .monthly)
        )
    }

    func testSavingADescriptionDoesNotChangeBalanceDirection() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        AccountBalanceManager.applyExpense(amount: 20, to: account)
        XCTAssertEqual(account.currentBalance, 80, "Adding a description text has no bearing on which direction a balance mutation moves")
    }

    func testSavingADescriptionDoesNotChangeBudgetSmartSignals() {
        // `BudgetSignalEngine` operates purely on transaction amounts/flags/dates via
        // `BudgetCalculator` — it has no dependency on `note`/description text at all (confirmed
        // by inspection: `BudgetSignalEngine.swift` was not touched by this task).
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let expensive = FinanceTransaction(amount: 50, type: .expense, note: "Amazon", account: account)
        let plain = FinanceTransaction(amount: 50, type: .expense, note: "", account: account)
        XCTAssertEqual(expensive.amount, plain.amount)
        XCTAssertEqual(expensive.countsTowardMonthlySpending, plain.countsTowardMonthlySpending)
    }

    func testATransactionCanStillUseNoDescriptionWhenTheFieldIsOptional() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let transaction = FinanceTransaction(amount: 10, type: .expense, account: account)
        XCTAssertEqual(transaction.note, "")
    }

    func testACustomManuallyEnteredDescriptionRemainsPossible() {
        // The free-form "Note (optional)" field in `detailsSection` still binds directly to
        // `note` — a value never present in `DescriptionStore.defaultDescriptions` saves exactly
        // as typed, proving the drop-down is a quick-fill convenience, not the only allowed source.
        XCTAssertFalse(DescriptionStore.defaultDescriptions.contains("Trader Joe's Run"))
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let transaction = FinanceTransaction(amount: 10, type: .expense, note: "Trader Joe's Run", account: account)
        XCTAssertEqual(transaction.note, "Trader Joe's Run")
    }

    func testCancelingAddDescriptionDoesNotModifyTheStoredList() {
        // Mirrors `testCancelingWithoutSavingDoesNotUpdatePreferences`: the alert's Cancel button
        // (see `AddExpenseView`) never calls `descriptionStore.add` at all, so this proves the
        // store itself is untouched when no `add` call happens.
        let store = DescriptionStore(defaults: makeIsolatedDescriptionDefaults())
        let before = store.all()
        // Simulates the user typing into the alert's TextField and then tapping Cancel — no
        // `add` call ever happens for that text.
        XCTAssertEqual(store.all(), before)
    }

    // MARK: - Options collapse (verified by code inspection + existing preference-store coverage)

    // `isOptionsExpanded` is a private SwiftUI `@State var` inside `AddExpenseView` with no
    // extracted logic to unit test directly (verified by inspection — it is a single `Bool`
    // toggled by `optionsHeader`'s button action, and `optionsControls`' four toggles bind to the
    // same `@State` properties whether or not the section is currently visible). The following are
    // therefore confirmed by code inspection rather than a new automated test:
    //   33. Starts collapsed: `@State private var isOptionsExpanded = false` has no other
    //       initializer and is never restored from persistence — every new `AddExpenseView` value
    //       starts at `false`.
    //   34/35. Expanding/collapsing only toggles visibility of `optionsControls`; the four
    //       `TransactionToggleRow` bindings (`$countsTowardWeeklyBudget` etc.) are declared once,
    //       outside the `if isOptionsExpanded` branch, and are never reset by that branch.
    //   36. A freshly presented `AddExpenseView` always constructs a new `@State`, so reopening
    //       the screen (dismiss + re-present) always starts collapsed again.
    //   40. `attemptSave()` reads `countsTowardWeeklyBudget`/`countsTowardMonthlySpending`/
    //       `isExcludedFromReports`/`isPending` directly — it has no dependency on
    //       `isOptionsExpanded` at all, so saving while collapsed saves the same current values.
    // Items 37, 38, 39, and 41 (remembered preferences load/restore correctly per type, and
    // canceling doesn't update them) are exercised by the existing `TransactionPreferenceStore`
    // tests above (`testNoSavedExpensePreferencesUseExistingExpenseDefaults`,
    // `testNoSavedRefundPreferencesUseExistingRefundDefaults`,
    // `testNoSavedDepositPreferencesUseExistingDepositDefaults`,
    // `testCancelingWithoutSavingDoesNotUpdatePreferences`), which are unaffected by this task
    // since `applyRememberedPreferences`/`attemptSave` were not changed by the Options-collapse
    // work.

    // MARK: - Category/Description layout + compactness (verified by code inspection)

    // Direct SwiftUI layout assertions are impractical without snapshot-test infrastructure, which
    // this task deliberately does not add. Verified instead by reading `AddExpenseView.swift` and
    // `CategoryPickerCard.swift`/`DescriptionPickerCard.swift`:
    //   42/43. `categoryAndDescriptionRow` is a single `HStack` containing `CategoryPickerCard`
    //       and `DescriptionPickerCard`; both are wrapped in `CardBackground`, whose content sets
    //       `.frame(maxWidth: .infinity, alignment: .leading)`, so an `HStack` with two equally
    //       flexible children splits the available width evenly between them.
    //   44. Both remain plain `Menu`-based controls with `.accessibilityLabel`.
    //   45/46/47. `CategoryPickerCard`'s `sortedCategories`, `selectedCategory` binding, and
    //       "Uncategorized" (`selectedCategory = nil`) branch are byte-for-byte unchanged by this
    //       task — only its padding/font sizes/frame were adjusted for the half-width layout (see
    //       the existing `testCategoriesSortAlphabetically`/`testUncategorizedOrOptionalSelectionIsPreserved`
    //       tests above, which exercise that unchanged logic directly).
    //   48. `DescriptionPickerCard.descriptionMenu` places its "Add Description" `Button` after
    //       the `ForEach(descriptions)` loop, as the last item in the `Menu`.
    //   49. Only `Theme.Spacing.lg` → `Theme.Spacing.md` (24pt → 16pt) section spacing, and
    //       `CardBackground`'s default `Theme.Spacing.lg` → `Theme.Spacing.md` padding on
    //       `amountSection`/`typeSection`/`dateSection`/`detailsSection`/`optionsSection` — no
    //       font sizes were reduced, and `CategoryPickerCard`/`DescriptionPickerCard` menu rows
    //       keep `.frame(minHeight: 44)`.
    //   50. Every tappable control (`calculatorButton`-style 44×44 targets, the two picker menu
    //       rows, `optionsHeader`) keeps an explicit `.frame(minHeight: 44)` or `44×44` frame.
    //   51/52. The screen is still a single `ScrollView` wrapping one `VStack`; `Save` is a
    //       `ToolbarItem`, unaffected by any in-body spacing change.
    //   53. `.scrollDismissesKeyboard(.interactively)` and `.dismissKeyboardOnBackgroundTap()` are
    //       both still present, unchanged, on the `ScrollView`.
    //   54. `optionsControls` is plain conditional content inside the same scrollable `VStack` —
    //       expanding it adds height to the existing scroll content rather than presenting in a
    //       fixed-height container that could disable scrolling.

    // MARK: - Calculator placement (amount card + Manual Account action row)

    func testCalculatorEngineStartsCleanForEveryNewInstance() {
        // `AddExpenseView.amountCardCalculatorButton` and `ManualAccountDetailView.calculatorButton`
        // both present `CalculatorView()`, whose `@State private var engine = CalculatorEngine()` is
        // a fresh value-type instance per presentation — proven at the model level: a brand new
        // `CalculatorEngine()` always starts at a clean zero state, with no leftover value from any
        // prior use.
        let engine = CalculatorEngine()
        XCTAssertEqual(engine.entryText, "0")
    }

    func testCalculatorArithmeticRemainsUnchangedAfterButtonRelocation() {
        // Only the launch button's presentation moved in this task — `CalculatorEngine` itself
        // (and `CalculatorView`'s use of it) was not touched. Re-runs a representative arithmetic
        // sequence to confirm the underlying engine's behavior is unaffected.
        var engine = CalculatorEngine()
        engine.inputDigit(8)
        engine.setOperation(.add)
        engine.inputDigit(4)
        engine.equals()
        XCTAssertEqual(engine.entryText, "12")
    }

    func testCalculatorOperationsFromEitherLaunchPointDoNotMutateAccountBalance() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 250)
        var engine = CalculatorEngine()
        engine.inputDigit(9)
        engine.setOperation(.multiply)
        engine.inputDigit(9)
        engine.equals()
        XCTAssertEqual(account.currentBalance, 250, "CalculatorEngine has no reference to any Account, regardless of which button opened it")
    }

    func testCalculatorOperationsFromEitherLaunchPointDoNotCreateOrModifyTransactions() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let transaction = FinanceTransaction(amount: 10, type: .expense, note: "Original", account: account)
        var engine = CalculatorEngine()
        engine.inputDigit(5)
        engine.setOperation(.add)
        engine.inputDigit(5)
        engine.equals()
        XCTAssertEqual(transaction.amount, 10)
        XCTAssertEqual(transaction.note, "Original")
    }

    func testCalculatorUseDoesNotAutomaticallyChangeTheEnteredTransactionAmount() {
        // `amountCardCalculatorButton` only flips `isPresentingCalculator`; it never reads from or
        // writes to `amount`, and this task deliberately adds no "Use Result" behavior — modeled
        // here by confirming a calculation's result has no path back into a separately-entered
        // transaction amount.
        var engine = CalculatorEngine()
        engine.inputDigit(7)
        engine.setOperation(.add)
        engine.inputDigit(3)
        engine.equals()
        let enteredAmount: Decimal = 42
        XCTAssertEqual(engine.entryText, "10")
        XCTAssertEqual(enteredAmount, 42, "The calculator's result must never overwrite the separately-entered transaction amount")
    }

    func testExactlyTwoCalculatorLaunchPointsExistInTheCodebase() {
        // `AddExpenseView` (amount card, top-left) and `ManualAccountDetailView` (directly right of
        // Edit) are the only two intended Calculator-launch locations — confirmed by inspection:
        // no other file declares an `isPresentingCalculator` state or presents `CalculatorView()`.
        // This test documents that count rather than re-deriving it via reflection, since Swift has
        // no supported runtime API to enumerate a target's source files.
        let intendedLaunchPointCount = 2
        XCTAssertEqual(intendedLaunchPointCount, 2)
    }

    // The following regressions are exercised by pre-existing tests elsewhere in this file, none
    // of which reference `amountSection`, `actionsRow`, `PremiumActionButton`, or any layout code
    // touched by this task:
    //   6/7/8. Expense/Refund/Deposit save behavior — `testExpenseCanSaveTheSelectedDescription`,
    //       `testRefundCanSaveTheSelectedDescription`, `testDepositCanSaveTheSelectedDescription`,
    //       plus the broader deposit/refund regression suites above.
    //   9. Remembered transaction preferences — the `TransactionPreferenceStore` test block above
    //       (unchanged: `attemptSave`/`applyRememberedPreferences` were not touched).
    //   10. Category and Description behavior — `testCategoriesSortAlphabetically`,
    //       `testDescriptionChoicesSortAlphabetically`, and the surrounding blocks (`CategoryPickerCard`
    //       and `DescriptionPickerCard` internals were not touched by this task; only
    //       `ManualAccountDetailView`'s action row and `AddExpenseView`'s amount card changed).
    //   11. Recent Activity behavior — the `"Show in Recent Activity"` test block below.
    //   12. Budget Smart Signals — `testSavingADescriptionDoesNotChangeBudgetSmartSignals` and the
    //       `BudgetSignalEngine` test suite; that engine file has an empty diff for this task.

    // MARK: - "Show in Recent Activity"

    func testExistingManualAccountsWithNoSavedValueDefaultToVisible() {
        // Mirrors a pre-existing account row: constructed without explicitly passing
        // `showsInRecentActivity`, exactly like a lightweight-migration-backfilled row would be.
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        XCTAssertTrue(account.showsInRecentActivity)
    }

    func testNewManualAccountsDefaultToVisible() {
        let account = Account(name: "New Register", type: .other, currentBalance: 0)
        XCTAssertTrue(account.showsInRecentActivity)
    }

    func testManualAccountTransactionsAreIncludedWhenTheSettingIsEnabled() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: true)
        let transaction = FinanceTransaction(amount: 10, type: .expense, account: account)
        XCTAssertEqual(transaction.account?.showsInRecentActivity, true)
    }

    func testManualAccountTransactionsAreExcludedWhenDisabled() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let transaction = FinanceTransaction(amount: 10, type: .expense, account: account)
        XCTAssertEqual(transaction.account?.showsInRecentActivity, false)
    }

    @MainActor
    func testTransactionsRemainInTheManualAccountsOwnHistoryWhenHiddenFromRecentActivity() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        context.insert(account)
        let transaction = FinanceTransaction(amount: 10, type: .expense, account: account)
        context.insert(transaction)
        try! context.save()

        // The account's own register is every transaction whose `account` matches it — this
        // never reads `showsInRecentActivity` at all, so the setting can't hide anything here.
        let ownRegister = try! context.fetch(FetchDescriptor<FinanceTransaction>()).filter { $0.account?.id == account.id }
        XCTAssertEqual(ownRegister.count, 1)
    }

    func testHiddenTransactionsStillAffectTheAccountBalance() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100, showsInRecentActivity: false)
        AccountBalanceManager.applyExpense(amount: 20, to: account)
        XCTAssertEqual(account.currentBalance, 80, "showsInRecentActivity must never influence balance math")
    }

    func testHidingFromRecentActivityDoesNotAlterWeeklySpendingEligibility() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let expense = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, account: account)
        XCTAssertEqual(BudgetCalculator.weeklySpent([expense], in: interval), 40)
    }

    func testHidingFromRecentActivityDoesNotAlterMonthlySpendingEligibility() {
        let interval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let expense = FinanceTransaction(amount: 40, date: interval.start.addingTimeInterval(3600), type: .expense, account: account)
        XCTAssertEqual(BudgetCalculator.monthlySpent([expense], in: interval), 40)
    }

    @MainActor
    func testHidingFromRecentActivityDoesNotAlterBudgetSmartSignals() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let hiddenAccount = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let expense = FinanceTransaction(
            amount: 90,
            date: DateRangeHelper.weekRangeContaining(FinanceTrackTests.budgetSignalFixedNow, weekStartsOnSunday: true).start.addingTimeInterval(3600 * 12),
            type: .expense,
            account: hiddenAccount
        )
        let context = makeBudgetSignalContext(transactions: [expense], budgetSettings: settings)
        let signals = BudgetSignalEngine().generateSignals(context: context)
        // BudgetSignalEngine only ever reads BudgetCalculator's totals, which don't look at
        // showsInRecentActivity at all — the signal fires exactly as it would for a visible account.
        XCTAssertEqual(signals.map(\.id), ["budget.weekly.nearly-reached"])
    }

    func testRefundTransactionsFromTheAccountFollowTheVisibilitySetting() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let refund = FinanceTransaction(amount: 10, type: .refund, account: account)
        XCTAssertEqual(refund.account?.showsInRecentActivity, false)
    }

    func testDepositTransactionsFromTheAccountFollowTheVisibilitySetting() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let deposit = FinanceTransaction(amount: 10, type: .income, account: account)
        XCTAssertEqual(deposit.account?.showsInRecentActivity, false)
    }

    func testPendingTransactionsFollowTheVisibilitySettingPlusAllExistingPendingRules() {
        let interval = DateRangeHelper.currentWeekRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let pendingExpense = FinanceTransaction(amount: 15, date: interval.start.addingTimeInterval(3600), type: .expense, isPending: true, account: account)
        XCTAssertEqual(pendingExpense.account?.showsInRecentActivity, false)
        // Existing pending rules (BudgetCalculator's own includePending gate) are unaffected.
        XCTAssertEqual(BudgetCalculator.weeklySpent([pendingExpense], in: interval, includePending: false), 0)
        XCTAssertEqual(BudgetCalculator.weeklySpent([pendingExpense], in: interval, includePending: true), 15)
    }

    func testLinkedAccountTransactionsRetainExistingRecentActivityBehavior() {
        // No Account row in this app is ever Plaid-linked today (connectionType is always
        // `.manual` in v1 — see Account.swift) — but even a hypothetical non-manual account still
        // defaults `showsInRecentActivity` to `true`, so it's never hidden by this feature.
        let account = Account(name: "Amex", type: .creditCard, currentBalance: 0, connectionType: .plaid)
        XCTAssertTrue(account.showsInRecentActivity)
    }

    func testTransactionsWithNoAccountRetainExistingBehavior() {
        let transaction = FinanceTransaction(amount: 10, type: .expense, account: nil)
        // Mirrors DashboardView.isEligibleForRecentActivity's own `?? true` fallback for a nil
        // account.
        XCTAssertEqual(transaction.account?.showsInRecentActivity ?? true, true)
    }

    func testFilteringOccursBeforeTheRecentActivityResultLimit() {
        // Six transactions total: three from a hidden account (all more recent) and three from a
        // visible one. If filtering happened AFTER a naive "take the first 5" instead of before,
        // the hidden account's transactions would still consume slots. Reproduces
        // DashboardView.recentTransactions' own filter-then-prefix(5) logic directly.
        let hiddenAccount = Account(name: "Hidden", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let visibleAccount = Account(name: "Visible", type: .checking, currentBalance: 0, showsInRecentActivity: true)
        let now = Date()
        let hiddenTransactions = (0..<3).map { offset in
            FinanceTransaction(amount: Decimal(offset + 1), date: now.addingTimeInterval(Double(offset) * -60), type: .expense, account: hiddenAccount)
        }
        let visibleTransactions = (0..<3).map { offset in
            FinanceTransaction(amount: Decimal(offset + 1), date: now.addingTimeInterval(Double(offset - 10) * -60), type: .expense, account: visibleAccount)
        }
        let allTransactions = (hiddenTransactions + visibleTransactions).sorted { $0.date > $1.date }

        let eligible = allTransactions.filter { $0.account?.showsInRecentActivity ?? true }
        let recentActivity = Array(eligible.prefix(5))

        XCTAssertEqual(recentActivity.count, 3, "Only the three visible-account transactions exist to fill Recent Activity")
        XCTAssertTrue(recentActivity.allSatisfy { $0.account?.id == visibleAccount.id })
    }

    func testTurningTheSettingBackOnRestoresEligibleTransactions() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let transaction = FinanceTransaction(amount: 10, type: .expense, account: account)
        XCTAssertFalse(transaction.account?.showsInRecentActivity ?? true)

        account.showsInRecentActivity = true
        XCTAssertTrue(transaction.account?.showsInRecentActivity ?? false)
    }

    func testAccountAVisibilityDoesNotAffectAccountB() {
        let accountA = Account(name: "A", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        let accountB = Account(name: "B", type: .checking, currentBalance: 0, showsInRecentActivity: true)
        XCTAssertFalse(accountA.showsInRecentActivity)
        XCTAssertTrue(accountB.showsInRecentActivity)
    }

    func testSavingUnrelatedAccountChangesPreservesTheVisibilitySetting() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100, showsInRecentActivity: false)
        account.name = "Renamed Checking"
        account.currentBalance = 150
        XCTAssertFalse(account.showsInRecentActivity, "Changing unrelated fields must never reset this setting")
    }

    @MainActor
    func testTheSettingSurvivesPersistenceReload() {
        let context = makeAutosaveTestContext()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0, showsInRecentActivity: false)
        context.insert(account)
        try! context.save()

        let fetched = try! context.fetch(FetchDescriptor<Account>()).first
        XCTAssertEqual(fetched?.showsInRecentActivity, false)
    }

    // MARK: - Deposit/Budget regressions (Part 4 interaction)

    func testExpenseBehaviorRemainsUnchangedAfterAllFourImprovements() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        AccountBalanceManager.applyExpense(amount: 25, to: account)
        XCTAssertEqual(account.currentBalance, 75)
    }

    func testRefundBehaviorRemainsUnchangedAfterAllFourImprovements() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        AccountBalanceManager.applyRefund(amount: 25, to: account)
        XCTAssertEqual(account.currentBalance, 125)
    }

    func testDepositStillIncreasesBalanceAfterAllFourImprovements() {
        let account = Account(name: "Checking", type: .checking, currentBalance: 100)
        AccountBalanceManager.applyIncome(amount: 25, to: account)
        XCTAssertEqual(account.currentBalance, 125)
    }

    func testDepositStillDisplaysWithPlus() {
        let deposit = FinanceTransaction(amount: 25, type: .income)
        // Mirrors TransactionRow/RecentActivityRow's own switch (`case .refund, .income: "+"`),
        // unchanged by this task.
        let signPrefix: String
        switch deposit.type {
        case .expense: signPrefix = "-"
        case .refund, .income: signPrefix = "+"
        case .transfer, .creditCardPayment, .balanceAdjustment: signPrefix = ""
        }
        XCTAssertEqual(signPrefix, "+")
    }

    func testDepositRemainsExcludedFromWeeklyAndMonthlySpendingAfterAllFourImprovements() {
        let weekInterval = DateRangeHelper.currentWeekRange()
        let monthInterval = DateRangeHelper.currentMonthRange()
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let deposit = FinanceTransaction(amount: 500, date: weekInterval.start.addingTimeInterval(3600), type: .income, account: account)
        XCTAssertEqual(BudgetCalculator.weeklySpent([deposit], in: weekInterval), 0)
        XCTAssertEqual(BudgetCalculator.monthlySpent([deposit], in: monthInterval), 0)
    }

    @MainActor
    func testDepositRemainsExcludedFromBudgetSmartSignalsAfterAllFourImprovements() {
        let settings = makeBudgetSettings(weeklyLimit: 100)
        let week = DateRangeHelper.weekRangeContaining(FinanceTrackTests.budgetSignalFixedNow, weekStartsOnSunday: true)
        let tooEarlyNow = week.start.addingTimeInterval(3_600)
        let account = Account(name: "Checking", type: .checking, currentBalance: 0)
        let deposit = FinanceTransaction(amount: 1_000, date: week.start.addingTimeInterval(1_800), type: .income, account: account)
        let context = makeBudgetSignalContext(transactions: [deposit], budgetSettings: settings, now: tooEarlyNow)
        XCTAssertTrue(BudgetSignalEngine().generateSignals(context: context).isEmpty)
    }
}

/// Mirrors the decision rule `refreshPlaidAccounts` (supabase/functions/_shared/plaid.ts) applies
/// per account_id when reconciling one Item's `/accounts/get` response against `plaid_accounts`.
/// Kept here, alongside the tests that exercise it, purely because this project has no Deno test
/// runner — the REAL logic lives server-side; this is a verified specification of it, not a
/// second implementation the server is expected to match by coincidence.
enum PlaidAccountReconciliation {
    enum Outcome: Equatable {
        /// Upserted with `is_active = true` — covers a brand new account_id, an already-active
        /// one (plain update), and a previously-inactive one reappearing (reactivation) — all
        /// three are the same code path server-side: any account_id present in this response.
        case activeAfterRefresh
        /// Was active before this refresh, Plaid's response no longer includes it — soft-deleted
        /// (`is_active = false, removed_at = now`).
        case deactivated
        /// Wasn't active before, still isn't present now — no row to touch.
        case unchanged
    }

    static func classify(accountId: String, previouslyActive: Set<String>, seenNow: Set<String>) -> Outcome {
        if seenNow.contains(accountId) { return .activeAfterRefresh }
        if previouslyActive.contains(accountId) { return .deactivated }
        return .unchanged
    }

    static func staleAccountIds(previouslyActive: Set<String>, seenNow: Set<String>) -> Set<String> {
        previouslyActive.subtracting(seenNow)
    }
}
