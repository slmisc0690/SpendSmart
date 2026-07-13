import SwiftUI
import SwiftData
import UIKit

/// "Ask SpendSmart" — a local-only Q&A screen over your existing bills, income, and spending
/// data. Everything here runs on-device through `SpendSmartQueryEngine`: no external AI, no
/// networking, nothing ever leaves this device. Opened from Settings > Insights.
struct InsightsView: View {
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query(sort: \FinanceTransaction.date, order: .reverse) private var transactions: [FinanceTransaction]
    @Query private var accounts: [Account]
    @Query private var settingsList: [BudgetSettings]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]

    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyModeManager.self) private var privacyMode

    @State private var questionText = ""
    @State private var currentAnswer: SpendSmartQueryEngine.Answer?

    private var settings: BudgetSettings? { settingsList.first }

    private var context: SpendSmartQueryEngine.Context {
        let weekStartsOnSunday = settings?.weekStartsOnSunday ?? true
        return SpendSmartQueryEngine.Context(
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            transactions: transactions,
            accounts: accounts,
            planSettings: monthlyPlanSettingsList.first,
            weeklyBudgetLimit: settings?.weeklySpendingLimit ?? 0,
            month: DateRangeHelper.currentMonthRange(),
            week: DateRangeHelper.currentWeekRange(weekStartsOnSunday: weekStartsOnSunday),
            weekStartsOnSunday: weekStartsOnSunday,
            includePending: settings?.includePendingTransactions ?? true,
            warningThreshold: settings?.warningThreshold ?? 0.70
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header
                    questionInputCard
                    quickQuestionsSection

                    if let currentAnswer {
                        answerCard(currentAnswer)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ask SpendSmart")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Answers are computed on this device from your own data. Nothing is sent anywhere.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Question input

    private var questionInputCard: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Ask a question")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("e.g. How much is Electric?", text: $questionText)
                        .textFieldStyle(.plain)
                        .padding(Theme.Spacing.sm)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                        .foregroundStyle(Theme.textPrimary)
                        .submitLabel(.search)
                        .onSubmit { ask(questionText) }

                    Button {
                        ask(questionText)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.accent)
                    }
                    .disabled(questionText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Quick questions

    private var quickQuestionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Quick Questions")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.sm)], alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(SpendSmartQueryEngine.quickQuestions) { quick in
                    FilterChip(title: quick.title, isSelected: currentAnswer?.title == quick.title) {
                        ask(quick)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Answer

    @ViewBuilder
    private func answerCard(_ answer: SpendSmartQueryEngine.Answer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Answer")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(answer.title)
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.textPrimary)
                        if let totalAmount = answer.totalAmount {
                            PrivacyAmountView(
                                amount: totalAmount,
                                isPrivacyModeEnabled: privacyMode.isEnabled,
                                font: Theme.amountFont(28),
                                color: Theme.textPrimary
                            )
                        }
                    }

                    Text(answer.explanation)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textSecondary)

                    if !answer.breakdown.isEmpty {
                        Divider().overlay(Theme.cardStroke)
                        VStack(spacing: Theme.Spacing.sm) {
                            ForEach(answer.breakdown) { row in
                                HStack {
                                    Text(row.label)
                                        .font(Theme.captionFont)
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                    Spacer()
                                    PrivacyAmountView(
                                        amount: row.amount,
                                        isPrivacyModeEnabled: privacyMode.isEnabled,
                                        font: Theme.captionFont,
                                        color: Theme.textPrimary
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Actions

    private func ask(_ text: String) {
        dismissKeyboard()
        questionText = text
        let question = SpendSmartQueryEngine.parseQuestion(text)
        withAnimation(.easeInOut(duration: 0.2)) {
            currentAnswer = SpendSmartQueryEngine.answer(for: question, context: context)
        }
    }

    private func ask(_ quick: SpendSmartQueryEngine.QuickQuestion) {
        dismissKeyboard()
        questionText = quick.title
        withAnimation(.easeInOut(duration: 0.2)) {
            currentAnswer = SpendSmartQueryEngine.answer(for: quick.question, context: context)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

#Preview {
    InsightsView()
        .modelContainer(SampleData.previewContainer)
        .environment(PrivacyModeManager())
}
