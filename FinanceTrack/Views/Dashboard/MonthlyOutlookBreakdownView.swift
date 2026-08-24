import SwiftUI

/// Dashboard's Monthly Outlook drill-down — tap the card, see all 4 weeks at once (never having to
/// visit Week 1, note the number, go to Week 2, and so on), then tap any week to see exactly which
/// account its spending came from, and — for whichever account bills get paid from — how much that
/// week's bill payment(s) varied from what was planned.
struct MonthlyOutlookBreakdownView: View {
    let weeks: [WeeklyOutlookBreakdown]
    let connections: [PlaidConnection]
    var isPrivacyModeEnabled: Bool = false

    @State private var expandedWeekIndex: Int?
    @Environment(\.dismiss) private var dismiss

    private func accountLabel(for entry: WeeklyAccountSpendingEntry) -> String {
        if let manualAccountName = entry.manualAccountName { return manualAccountName }
        if let plaidAccountId = entry.plaidAccountId,
           let label = ConnectedAccountOptionPresenter.label(forAccountId: plaidAccountId, in: connections) {
            return label
        }
        return "Other"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(weeks) { week in
                        weekCard(week)
                    }
                }
                .padding()
            }
            .background(Theme.backgroundGradient)
            .navigationTitle("Monthly Outlook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func weekCard(_ week: WeeklyOutlookBreakdown) -> some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedWeekIndex = (expandedWeekIndex == week.weekIndex) ? nil : week.weekIndex
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Week \(week.weekIndex)")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textPrimary)
                            Text(DateRangeHelper.weekDisplayText(for: week.weekInterval))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        StatusBadge(status: week.status)
                        Image(systemName: expandedWeekIndex == week.weekIndex ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)

                HStack {
                    labeledAmount(title: "Recommended", amount: week.recommended)
                    Spacer()
                    labeledAmount(title: "Actual", amount: week.actualSpent)
                    Spacer()
                    let remaining = week.recommended - week.actualSpent
                    labeledAmount(
                        title: remaining >= 0 ? "Left" : "Over",
                        amount: abs(remaining),
                        color: remaining >= 0 ? Theme.statusGood : Theme.statusOver
                    )
                }

                if expandedWeekIndex == week.weekIndex {
                    Divider().background(Theme.textTertiary.opacity(0.2))
                    if week.accounts.isEmpty {
                        Text("No spending recorded for this week.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 2)
                    } else {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ForEach(week.accounts) { entry in
                                accountRow(entry)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ entry: WeeklyAccountSpendingEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(accountLabel(for: entry))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                PrivacyAmountView(amount: entry.spent, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.captionFont, color: Theme.textPrimary)
            }
            if let billVariance = entry.billVariance, billVariance != 0 {
                HStack(spacing: 4) {
                    Text(billVariance > 0 ? "Paid less than planned on bills" : "Paid more than planned on bills")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    PrivacyAmountView(
                        amount: abs(billVariance),
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: .system(size: 10, weight: .semibold, design: .rounded),
                        color: billVariance > 0 ? Theme.statusGood : Theme.statusOver
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func labeledAmount(title: String, amount: Decimal, color: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
            PrivacyAmountView(amount: amount, isPrivacyModeEnabled: isPrivacyModeEnabled, font: Theme.captionFont, color: color)
        }
    }
}
