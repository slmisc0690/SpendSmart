import Foundation
import SwiftData

/// ONE-TIME RETROACTIVE BILL-PAYMENT TAGGING — links pre-existing Manual Account register
/// transactions (created by Pay Bills BEFORE `FinanceTransaction.linkedRecurringExpense` existed)
/// back to the Fixed Bill they paid, so `BudgetCalculator`'s existing-bill exclusion picks them up
/// exactly like a payment made after the feature shipped. Pay Bills always wrote the bill's name
/// as the transaction's `note` — the only signal available for this historical backfill — so the
/// match is a case-insensitive exact name comparison against `RecurringExpense.name`, never a
/// fuzzy/partial match. A transaction is left untouched (never guessed) whenever:
/// - it's already linked (`linkedRecurringExpense != nil`) or tagged `isOneTimeBillEntry`,
/// - it isn't a Manual Account expense (`account == nil`, `source != .manual`, or `type != .expense`),
/// - its note matches zero or more than one currently-active `RecurringExpense` name — an
///   ambiguous or since-renamed/deleted bill is safer left alone than silently mislinked.
enum BillPaymentBackfillService {
    @discardableResult
    static func backfillUnlinkedManualTransactions(in context: ModelContext) throws -> Int {
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let bills = try context.fetch(FetchDescriptor<RecurringExpense>()).filter(\.isActive)

        var billsByLowercasedName: [String: [RecurringExpense]] = [:]
        for bill in bills {
            billsByLowercasedName[bill.name.lowercased(), default: []].append(bill)
        }

        var backfilledCount = 0
        for transaction in transactions {
            guard transaction.account != nil,
                  transaction.source == .manual,
                  transaction.type == .expense,
                  transaction.linkedRecurringExpense == nil,
                  !transaction.isOneTimeBillEntry
            else { continue }

            guard let matches = billsByLowercasedName[transaction.note.lowercased()], matches.count == 1 else { continue }

            transaction.linkedRecurringExpense = matches[0]
            backfilledCount += 1
        }

        if backfilledCount > 0 {
            try context.save()
        }
        return backfilledCount
    }
}
