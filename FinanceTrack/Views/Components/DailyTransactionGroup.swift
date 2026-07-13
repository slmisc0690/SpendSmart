import SwiftUI

/// One day's section in the Weekly screen's daily breakdown: day name/date, that day's net
/// total, and the day's transactions (reusing `TransactionRow`).
struct DailyTransactionGroup: View {
    let day: Date
    let transactions: [FinanceTransaction]
    let dailyTotal: Decimal
    var isPrivacyModeEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                PrivacyAmountView(
                    amount: dailyTotal,
                    isPrivacyModeEnabled: isPrivacyModeEnabled,
                    font: Theme.bodyFont,
                    color: Theme.textSecondary
                )
            }

            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                        TransactionRow(transaction: transaction, isPrivacyModeEnabled: isPrivacyModeEnabled)
                        if index < transactions.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    DailyTransactionGroup(
        day: .now,
        transactions: [
            FinanceTransaction(amount: 42.18, type: .expense, note: "Trader Joe's"),
            FinanceTransaction(amount: 9.75, type: .expense, note: "Blue Bottle Coffee"),
        ],
        dailyTotal: 51.93
    )
    .padding()
    .background(Theme.backgroundGradient)
}
