import Foundation
import SwiftData

/// SCHEDULED TRANSFERS — checks every `ScheduledTransfer` for whether its scheduled day has
/// arrived and it hasn't already posted for the current month, and if so creates the real
/// `FinanceTransaction` + applies whichever local Manual Account balance(s) it touches, exactly
/// mirroring what a manual Transfer To Savings/Transfer to Checking entry already does via
/// `AddExpenseView.performSave()` — never a second, divergent transaction shape. See
/// `ScheduledTransfer`'s own header for why this can only ever be checked on app open (no
/// background-task infrastructure exists anywhere in this app) and for the exact missed-month
/// behavior (posts once, dated the scheduled day).
enum ScheduledTransferPostingService {

    /// Maps this schedule's `PlanTiming` to the actual day-of-month it resolves to, reusing
    /// `MonthlyDepositDay`'s existing short-month clamping (see that type's own header) rather
    /// than a second day-resolution implementation. `.weekly`/`.customDate` are never offered by
    /// the add/edit UI for a `ScheduledTransfer` — `.beginningMonth` is a safe, harmless fallback
    /// should either ever reach here regardless.
    private static func monthlyDepositDay(for timing: PlanTiming) -> MonthlyDepositDay {
        switch timing {
        case .beginningMonth, .weekly, .customDate: return .numericDay(1)
        case .midMonth: return .numericDay(15)
        case .endMonth: return .lastDayOfMonth
        }
    }

    /// This schedule's actual calendar date within the month containing `referenceDate`.
    static func scheduledDate(for schedule: ScheduledTransfer, inMonthContaining referenceDate: Date, calendar: Calendar = .current) -> Date {
        monthlyDepositDay(for: schedule.timing).resolvedDate(inMonthContaining: referenceDate, calendar: calendar)
    }

    private static func isConfigured(_ schedule: ScheduledTransfer) -> Bool {
        let hasSource = schedule.sourceAccount != nil || schedule.sourceConnectedAccountId != nil
        let hasDestination = schedule.destinationAccount != nil || schedule.destinationConnectedAccountId != nil
        // AT LEAST ONE side must be a real local Manual Account — a Connected account has no
        // local `Account` object at all, so a Connected-to-Connected schedule would have nothing
        // to post a transaction against or mutate. The add/edit UI already prevents saving one
        // this way; this is the same guarantee enforced again here, defensively.
        let hasLocalSide = schedule.sourceAccount != nil || schedule.destinationAccount != nil
        return hasSource && hasDestination && hasLocalSide
    }

    /// True when `schedule` is active, fully and validly configured, its scheduled day for the
    /// CURRENT month has already arrived (relative to `now`), and it hasn't already posted for
    /// this calendar month — the exact idempotency guarantee `lastPostedMonth` exists for.
    static func isDue(_ schedule: ScheduledTransfer, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard schedule.isActive, isConfigured(schedule) else { return false }
        let scheduled = scheduledDate(for: schedule, inMonthContaining: now, calendar: calendar)
        guard calendar.startOfDay(for: now) >= calendar.startOfDay(for: scheduled) else { return false }
        guard let lastPostedMonth = schedule.lastPostedMonth else { return true }
        return !calendar.isDate(lastPostedMonth, equalTo: now, toGranularity: .month)
    }

    /// Posts every due schedule in `schedules` — never throws, never blocks the caller (matching
    /// this app's own "a background check never surfaces a blocking error" convention, e.g.
    /// `PlaidConnectionManager`'s sync failures) — and returns how many were actually posted.
    /// Dated the schedule's own scheduled day for THIS month, never `now`, so a schedule checked
    /// late (app not opened until the 20th for a Mid-Month schedule) still lands on the 15th —
    /// Scott's own explicit choice. `savingsPlaidAccountIds` (Plaid `account_id`s reported with
    /// `subtype == "savings"`, resolved by the caller exactly like every other consumer of this
    /// convention — see `SavedViaTransferCalculator`'s own parameter of the same name) lets a
    /// Connected Savings destination correctly post as `.transferToSavings` too; omitting it still
    /// posts correctly, just always as `.transferDeposit` for a Connected destination.
    @discardableResult
    static func postDueTransfers(
        _ schedules: [ScheduledTransfer],
        modelContext: ModelContext,
        savingsPlaidAccountIds: Set<String> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        var postedCount = 0
        for schedule in schedules where isDue(schedule, now: now, calendar: calendar) {
            guard postOne(schedule, modelContext: modelContext, savingsPlaidAccountIds: savingsPlaidAccountIds, now: now, calendar: calendar) else { continue }
            postedCount += 1
        }
        return postedCount
    }

    /// Posts a single already-confirmed-due schedule. Returns `false` (no-op — never a crash) for
    /// the one combination this app cannot express as a single transaction: a Manual source
    /// paired with a Connected, NON-savings destination (there is no transaction type whose
    /// convention has "this account" be a Connected reference with no local balance while still
    /// being the side that's debited) — `isConfigured` lets it through since both sides ARE set
    /// and one IS local, but posting still can't proceed for that specific shape. Every other
    /// combination (Manual-to-Manual, Manual-to-Connected-Savings, Connected-to-Manual-of-any-type)
    /// posts correctly.
    private static func postOne(
        _ schedule: ScheduledTransfer,
        modelContext: ModelContext,
        savingsPlaidAccountIds: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let destinationIsSavings: Bool
        if let destinationAccount = schedule.destinationAccount {
            destinationIsSavings = destinationAccount.type == .savings
        } else if let destinationConnectedAccountId = schedule.destinationConnectedAccountId {
            destinationIsSavings = savingsPlaidAccountIds.contains(destinationConnectedAccountId)
        } else {
            destinationIsSavings = false
        }
        let postedDate = scheduledDate(for: schedule, inMonthContaining: now, calendar: calendar)

        let transaction: FinanceTransaction
        if destinationIsSavings, let source = schedule.sourceAccount {
            // SAVED-TRACKING PARITY — "this account" is the Manual source (debited), matching
            // every other `.transferToSavings` entry's own established convention (see
            // `ManualTransactionDeletionService.reverseBalanceEffect`) — feeds the Dashboard's
            // "Saved" Quick Stat exactly like a manual entry to the same destination would.
            transaction = FinanceTransaction(
                amount: schedule.amount, date: postedDate, type: .transferToSavings, source: .manual,
                note: schedule.note.isEmpty ? "Scheduled Transfer" : schedule.note,
                account: source,
                transferCounterpartyAccount: schedule.destinationAccount,
                transferCounterpartyPlaidAccountId: schedule.destinationConnectedAccountId,
                ownerUserID: source.ownerUserID
            )
            modelContext.insert(transaction)
            AccountBalanceManager.applyExpense(amount: schedule.amount, to: source)
            if let destinationAccount = schedule.destinationAccount {
                AccountBalanceManager.applyIncome(amount: schedule.amount, to: destinationAccount)
            }
        } else if let destination = schedule.destinationAccount {
            // "This account" is the Manual destination (credited) — matching `.transferDeposit`
            // ("Transfer to Checking")'s own established convention. Covers both Manual-to-Manual
            // (non-Savings) and Connected-source-to-Manual — the source's balance is only mutated
            // when it's a real local Manual Account; a Connected source is a reference tag only,
            // exactly like a manual Transfer Dep entry with a Connected counterparty.
            transaction = FinanceTransaction(
                amount: schedule.amount, date: postedDate, type: .transferDeposit, source: .manual,
                note: schedule.note.isEmpty ? "Scheduled Transfer" : schedule.note,
                account: destination,
                transferCounterpartyAccount: schedule.sourceAccount,
                transferCounterpartyPlaidAccountId: schedule.sourceConnectedAccountId,
                ownerUserID: destination.ownerUserID
            )
            modelContext.insert(transaction)
            AccountBalanceManager.applyIncome(amount: schedule.amount, to: destination)
            if let sourceAccount = schedule.sourceAccount {
                AccountBalanceManager.applyExpense(amount: schedule.amount, to: sourceAccount)
            }
        } else {
            // Manual source + Connected non-savings destination — cannot be expressed; skip
            // rather than guess at a shape nothing else in the app already establishes.
            return false
        }

        schedule.lastPostedMonth = now
        schedule.updatedAt = .now
        return true
    }
}
