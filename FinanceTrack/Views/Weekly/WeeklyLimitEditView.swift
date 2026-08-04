import SwiftUI

/// Read-only display of Effective Planned Weekly Spending — this value is always derived from
/// the Monthly Plan (`MonthlyPlanCalculator.effectivePlannedWeeklySpending`: a custom override
/// when one is set, otherwise Flexible Spending Available ÷ 4) and can never be manually edited
/// here, in `MonthlyGoalEditView`, or in `SettingsView`'s own inline Budget Settings fields. This
/// sheet exists only so the pre-existing entry points from the Dashboard's setup card and the
/// Weekly Budget screen's hero card still show something meaningful rather than disappearing
/// outright. WEEKLY SPENDING UNIFICATION — the caller passes the SAME live-computed value it
/// itself displays (never `BudgetSettings.weeklySpendingLimit` directly), so this sheet can never
/// show a stale/differently-synced number than the screen that opened it.
struct WeeklyLimitEditView: View {
    let limit: Decimal?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Weekly Spending Limit")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: .constant(limit),
                                style: .hero,
                                isDisabled: true,
                                accessibilityLabel: "Weekly spending limit"
                            )
                            Text("Automatically calculated from your Monthly Plan savings goal and projected savings.")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Weekly Limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    WeeklyLimitEditView(limit: 350)
}
