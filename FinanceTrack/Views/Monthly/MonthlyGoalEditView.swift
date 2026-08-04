import SwiftUI

/// Read-only display of `BudgetSettings.monthlyGoal` — this value is always derived from the
/// Monthly Plan's own Monthly Savings Goal (see `BudgetSettings.applyMonthlyPlanAutoCalculate`)
/// and can never be manually edited here, in `WeeklyLimitEditView`, or in `SettingsView`'s own
/// inline Budget Settings fields. This sheet exists only so the pre-existing entry point from
/// `MonthlySummaryView` still shows something meaningful rather than disappearing outright.
struct MonthlyGoalEditView: View {
    let settings: BudgetSettings?
    @Environment(\.dismiss) private var dismiss

    private var goal: Decimal? { settings?.monthlyGoal }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    CardBackground {
                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Monthly Goal")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                            CurrencyAmountField(
                                amount: .constant(goal),
                                style: .hero,
                                isDisabled: true,
                                accessibilityLabel: "Monthly goal"
                            )
                            Text("Automatically calculated from your Monthly Plan savings goal.")
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
            .navigationTitle("Monthly Goal")
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
    MonthlyGoalEditView(settings: BudgetSettings(monthlyGoal: 1400))
}
