import XCTest
@testable import FinanceTrack

/// The four spending fixes: Auto Calculate switches decide what counts and what the Exclude list
/// shows; register entries never count; Saved moves only with savings transfers/deposits; Auto
/// Deposit is gone.
@MainActor
final class SpendingFixesTests: XCTestCase {

    private let week = DateInterval(
        start: Date(timeIntervalSince1970: 1_800_000_000),
        end: Date(timeIntervalSince1970: 1_800_000_000 + 7 * 86_400)
    )
    private var inWeek: Date { week.start.addingTimeInterval(86_400) }

    private func plaid(_ account: String, _ amount: Decimal = 10, _ type: TransactionType = .expense) -> FinanceTransaction {
        FinanceTransaction(amount: amount, date: inWeek, type: type, source: .plaid, countsTowardWeeklyBudget: false,
                           countsTowardMonthlySpending: false, isExcludedFromReports: true, plaidAccountId: account)
    }

    // MARK: 1. Auto Calculate switches

    func testOnlySwitchedOnAccountsCountAndAppearInTheExcludeList() {
        let amex = plaid("amex", 80), wells = plaid("wells", 500)
        XCTAssertEqual(BudgetCalculator.weeklyActualSpending([amex, wells], in: week, autoTrackedAccountIds: ["amex"]), 80)
        XCTAssertTrue(ExcludeTransactionsView.isSelectable(amex, autoTrackedAccountIds: ["amex"], excludedIDs: []))
        XCTAssertFalse(ExcludeTransactionsView.isSelectable(wells, autoTrackedAccountIds: ["amex"], excludedIDs: []))
    }

    func testSwitchingAnAccountOnMakesItCountAndAppear() {
        let wells = plaid("wells", 500)
        XCTAssertEqual(BudgetCalculator.weeklyActualSpending([wells], in: week, autoTrackedAccountIds: ["amex", "wells"]), 500)
        XCTAssertTrue(ExcludeTransactionsView.isSelectable(wells, autoTrackedAccountIds: ["amex", "wells"], excludedIDs: []))
    }

    func testDepositsOnASwitchedOnAccountAreNotListed() {
        XCTAssertFalse(ExcludeTransactionsView.isSelectable(plaid("amex", 10, .creditCardPayment), autoTrackedAccountIds: ["amex"], excludedIDs: []))
    }

    func testAlreadyExcludedRowStaysListed() {
        let wells = plaid("wells")
        XCTAssertTrue(ExcludeTransactionsView.isSelectable(wells, autoTrackedAccountIds: [], excludedIDs: [wells.id]))
    }

    // MARK: 2. Register entries never count

    func testRegisterEntryNeverCountsOrAppearsInTheExcludeList() {
        let register = Account(name: "Wells Fargo Checking", type: .checking)
        let entry = FinanceTransaction(amount: 3875.10, date: inWeek, type: .expense, source: .manual, account: register)
        XCTAssertEqual(BudgetCalculator.weeklyActualSpending([entry], in: week), 0)
        XCTAssertEqual(BudgetCalculator.monthlyActualSpending([entry], in: week), 0)
        XCTAssertFalse(BudgetCalculator.isCounted(entry, includePending: true, context: .weekly))
        XCTAssertFalse(ExcludeTransactionsView.isSelectable(entry, autoTrackedAccountIds: ["amex"], excludedIDs: []))
    }

    func testDashboardExpenseWithNoRegisterStillCountsAndAppears() {
        let entry = FinanceTransaction(amount: 30, date: inWeek, type: .expense, source: .manual)
        XCTAssertEqual(BudgetCalculator.weeklyActualSpending([entry], in: week), 30)
        XCTAssertTrue(ExcludeTransactionsView.isSelectable(entry, autoTrackedAccountIds: [], excludedIDs: []))
    }

    // MARK: 3. Saved

    func testSavedAddsTransferToSavingsAndDepositToSavingsAndSubtractsTransferToChecking() {
        let savings = Account(name: "Savings", type: .savings)
        let checking = Account(name: "Checking", type: .checking)
        let toSavings = FinanceTransaction(amount: 1000, date: inWeek, type: .transferToSavings, source: .manual, account: checking)
        let deposit = FinanceTransaction(amount: 800, date: inWeek, type: .income, source: .manual, account: savings)
        let toChecking = FinanceTransaction(amount: 300, date: inWeek, type: .transferDeposit, source: .manual, account: checking, transferCounterpartyAccount: savings)
        XCTAssertEqual(SavedViaTransferCalculator.savedThisMonth([toSavings, deposit, toChecking], in: week), 1500)
    }

    func testDepositIntoCheckingDoesNotAddToSaved() {
        let checking = Account(name: "Checking", type: .checking)
        let deposit = FinanceTransaction(amount: 800, date: inWeek, type: .income, source: .manual, account: checking)
        XCTAssertEqual(SavedViaTransferCalculator.savedThisMonth([deposit], in: week), 0)
    }

    func testSavedTransfersNeverCountAsSpending() {
        let checking = Account(name: "Checking", type: .checking)
        let toSavings = FinanceTransaction(amount: 1000, date: inWeek, type: .transferToSavings, source: .manual)
        _ = checking
        XCTAssertEqual(BudgetCalculator.weeklyActualSpending([toSavings], in: week), 0)
    }

    // MARK: Saved This Month and Saved

    func testSavedThisMonthCombinesManualSavingsTransfersAndDeposits() {
        let savings = Account(name: "Savings", type: .savings)
        let checking = Account(name: "Checking", type: .checking)
        let entries = [SavingsEntry(amount: 800, date: inWeek)]
        let transactions = [
            FinanceTransaction(amount: 300, date: inWeek, type: .transferToSavings, source: .manual, account: checking),
            FinanceTransaction(amount: 200, date: inWeek, type: .income, source: .manual, account: savings),
            FinanceTransaction(amount: 100, date: inWeek, type: .transferDeposit, source: .manual, account: checking, transferCounterpartyAccount: savings),
        ]
        XCTAssertEqual(SavedViaTransferCalculator.totalSavedThisMonth(entries: entries, transactions: transactions, in: week), 1200)
    }

    func testTransferBackToCheckingDeductsFromManualSavings() {
        let savings = Account(name: "Savings", type: .savings)
        let checking = Account(name: "Checking", type: .checking)
        let entries = [SavingsEntry(amount: 800, date: inWeek)]
        let transactions = [FinanceTransaction(amount: 300, date: inWeek, type: .transferDeposit, source: .manual, account: checking, transferCounterpartyAccount: savings)]
        XCTAssertEqual(SavedViaTransferCalculator.totalSavedThisMonth(entries: entries, transactions: transactions, in: week), 500)
        XCTAssertEqual(SavedViaTransferCalculator.totalSavedThisMonth(entries: [], transactions: transactions, in: week), 0, "never below zero")
    }

    func testSavedTileIsSavedThisMonthPlusMonthlyRemaining() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("FinanceTrack/Views/Dashboard/DashboardView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("amount: savedThisMonth + monthlySpendRemaining(summary: summary),"))
    }

    // MARK: Quick Stat subtitles wrap

    func testStatCardSubtitleWrapsInsteadOfTruncating() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("FinanceTrack/Views/Components/StatCard.swift"), encoding: .utf8)
        guard let range = source.range(of: "Text(subtitle)") else { return XCTFail("subtitle text not found") }
        let block = String(source[range.lowerBound...].prefix(300))
        XCTAssertTrue(block.contains(".lineLimit(2)"))
        XCTAssertFalse(block.contains(".lineLimit(1)"))
    }

    // MARK: 4. Auto Deposit is gone

    func testAutoDepositHasNoSettingsSwitchOrDashboardPrompt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["FinanceTrack/Views/Settings/AccountSettingsView.swift", "FinanceTrack/Views/Dashboard/DashboardView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("AutoDeposit"), path)
            XCTAssertFalse(source.contains("DepositReview"), path)
        }
    }
}
