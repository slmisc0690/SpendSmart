#if DEBUG
import SwiftUI
import SwiftData

/// One built-in scenario `SmartSignalsTestView` can drive the real `SmartSignalsEngine` against.
/// Purely a DEBUG identifier list — carries no data itself.
enum SmartSignalsTestScenario: String, CaseIterable, Identifiable {
    case noSignals = "No Signals"
    case budgetExceeded = "Budget Exceeded"
    case budgetNearlyReached = "Budget Nearly Reached"
    case budgetHalfway = "Budget Halfway"
    case budgetOnTrack = "Budget On Track"
    case weeklySpendingIncrease = "Weekly Spending Increase"
    case monthlySpendingIncrease = "Monthly Spending Increase"
    case subscriptionFixedExpenseRatio = "Subscription Fixed-Expense Ratio"
    case incomeConcentration = "Income Concentration"
    case allSignals = "All Signals"

    var id: String { rawValue }
}

/// Builds a deterministic, in-memory-only `SmartSignalContext` for each `SmartSignalsTestScenario`
/// — never inserts into a `ModelContext`, never saves, never touches the user's real data. Every
/// model value here is a plain, un-persisted Swift object; nothing in this type has a code path
/// that reaches SwiftData. DEBUG-only, exists solely to drive `SmartSignalsTestView` (and its
/// factory-level unit tests) against the real `SmartSignalsEngine` and real calculators — it
/// never fabricates a `SmartSignal` directly.
enum SmartSignalsTestScenarioFactory {
    /// `SmartSignalsEngine` has no parameterless initializer — this mirrors the project's own
    /// established default engine composition and order (see `SmartSignalsEngine`'s doc comments
    /// and `testRemainingPlaceholderEnginesHandleEmptyAndSparseContextsSafely`), so both the DEBUG
    /// harness and its tests exercise the exact same real coordinator setup a production call
    /// site would use.
    static var defaultEngines: [any SmartSignalEngine] {
        [
            BudgetSignalEngine(),
            SpendingSignalEngine(),
            SubscriptionSignalEngine(),
            IncomeSignalEngine(),
            CashFlowSignalEngine(),
            SavingsSignalEngine(),
            CreditCardSignalEngine(),
        ]
    }

    /// Wednesday, July 15 2026, noon — a fixed, deterministic scenario "now" nowhere near a month
    /// boundary or a US daylight-saving transition. Computed via `Calendar` components, never
    /// `Date()`/`.now`.
    static let evaluationDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 15
        components.hour = 12
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 1_784_203_200)
    }()

    private static let calendar = Calendar.current

    private static var currentWeek: DateInterval {
        DateRangeHelper.weekRangeContaining(evaluationDate, weekStartsOnSunday: true, calendar: calendar)
    }

    private static var previousWeek: DateInterval {
        let reference = calendar.date(byAdding: .day, value: -7, to: evaluationDate) ?? evaluationDate
        return DateRangeHelper.weekRangeContaining(reference, weekStartsOnSunday: true, calendar: calendar)
    }

    private static var currentMonth: DateInterval {
        DateRangeHelper.monthRangeContaining(evaluationDate, calendar: calendar)
    }

    private static var previousMonth: DateInterval {
        DateRangeHelper.lastMonthRange(relativeTo: evaluationDate, calendar: calendar)
    }

    private static func expense(_ amount: Decimal, _ date: Date) -> FinanceTransaction {
        FinanceTransaction(amount: amount, date: date, type: .expense)
    }

    private static func makeContext(
        transactions: [FinanceTransaction] = [],
        incomeSources: [IncomeSource] = [],
        recurringExpenses: [RecurringExpense] = [],
        budgetSettings: BudgetSettings? = nil
    ) -> SmartSignalContext {
        SmartSignalContext(
            transactions: transactions,
            accounts: [],
            categories: [],
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            budgetSettings: budgetSettings,
            monthlyPlanSettings: nil,
            now: evaluationDate
        )
    }

    static func context(for scenario: SmartSignalsTestScenario) -> SmartSignalContext {
        switch scenario {
        case .noSignals:
            return makeContext()

        case .budgetExceeded:
            let settings = BudgetSettings(weeklySpendingLimit: 100)
            let tx = expense(142, currentWeek.start.addingTimeInterval(3_600))
            return makeContext(transactions: [tx], budgetSettings: settings)

        case .budgetNearlyReached:
            let settings = BudgetSettings(weeklySpendingLimit: 100)
            let tx = expense(90, currentWeek.start.addingTimeInterval(3_600))
            return makeContext(transactions: [tx], budgetSettings: settings)

        case .budgetHalfway:
            let settings = BudgetSettings(weeklySpendingLimit: 100)
            let tx = expense(60, currentWeek.start.addingTimeInterval(3_600))
            return makeContext(transactions: [tx], budgetSettings: settings)

        case .budgetOnTrack:
            let settings = BudgetSettings(weeklySpendingLimit: 100)
            let tx = expense(30, currentWeek.start.addingTimeInterval(3_600))
            return makeContext(transactions: [tx], budgetSettings: settings)

        case .weeklySpendingIncrease:
            let previousTx = expense(100, previousWeek.start.addingTimeInterval(3_600))
            let currentTx = expense(160, currentWeek.start.addingTimeInterval(3_600))
            return makeContext(transactions: [previousTx, currentTx])

        case .monthlySpendingIncrease:
            let previousTx = expense(400, previousMonth.start.addingTimeInterval(3_600))
            let currentTx = expense(550, currentMonth.start.addingTimeInterval(3_600))
            return makeContext(transactions: [previousTx, currentTx])

        case .subscriptionFixedExpenseRatio:
            let income = [IncomeSource(name: "Job", amount: 4_000, frequency: .monthly)]
            let expenses = [RecurringExpense(name: "Rent", amount: 2_400, frequency: .monthly)]
            return makeContext(incomeSources: income, recurringExpenses: expenses)

        case .incomeConcentration:
            let income = [
                IncomeSource(name: "Primary Job", amount: 4_000, frequency: .monthly),
                IncomeSource(name: "Side Gig", amount: 1_000, frequency: .monthly),
            ]
            return makeContext(incomeSources: income)

        case .allSignals:
            // Total income (3,200 + 800 = 4,000) and total fixed expenses (2,400) are chosen so
            // the Subscription ratio (2,400/4,000 = 60%) and Income concentration
            // (3,200/4,000 = 80%) both land exactly on their documented thresholds regardless of
            // how the income total is split across sources.
            let settings = BudgetSettings(weeklySpendingLimit: 100)
            let previousWeekTx = expense(100, previousWeek.start.addingTimeInterval(3_600))
            let currentWeekTx = expense(200, currentWeek.start.addingTimeInterval(3_600))
            let previousMonthTx = expense(400, previousMonth.start.addingTimeInterval(3_600))
            let currentMonthTx = expense(550, currentMonth.start.addingTimeInterval(3_600))
            let income = [
                IncomeSource(name: "Primary Job", amount: 3_200, frequency: .monthly),
                IncomeSource(name: "Side Gig", amount: 800, frequency: .monthly),
            ]
            let expenses = [RecurringExpense(name: "Rent", amount: 2_400, frequency: .monthly)]
            return makeContext(
                transactions: [previousWeekTx, currentWeekTx, previousMonthTx, currentMonthTx],
                incomeSources: income,
                recurringExpenses: expenses,
                budgetSettings: settings
            )
        }
    }
}

/// DEBUG-only physical-device harness for exercising the real, completed `SmartSignalsEngine`.
/// Never writes to SwiftData in either mode: Live Data only *reads* the current `@Query` arrays,
/// and Test Scenarios builds entirely in-memory contexts via `SmartSignalsTestScenarioFactory`.
/// Excluded from Release by the `#if DEBUG` wrapping this entire file.
struct SmartSignalsTestView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case liveData = "Live Data"
        case testScenarios = "Test Scenarios"
        var id: String { rawValue }
    }

    @Query private var transactions: [FinanceTransaction]
    @Query private var accounts: [Account]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var budgetSettingsList: [BudgetSettings]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]

    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .liveData
    @State private var selectedScenario: SmartSignalsTestScenario = .noSignals
    @State private var signals: [SmartSignal] = []
    @State private var lastRefreshDate: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    notice
                    modePicker
                    if mode == .testScenarios {
                        scenarioPicker
                    }
                    summaryRow
                    signalList
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Smart Signals Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refresh") { refresh() }
                }
            }
            .onAppear { refresh() }
            .onChange(of: mode) { _, _ in refresh() }
            .onChange(of: selectedScenario) { _, _ in refresh() }
        }
        .preferredColorScheme(.dark)
    }

    private var notice: some View {
        Text("DEBUG ONLY \u{2014} This screen does not change or save financial data.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.statusWarning)
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.statusWarning.opacity(0.12))
            )
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { candidateMode in
                Text(candidateMode.rawValue).tag(candidateMode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var scenarioPicker: some View {
        Menu {
            ForEach(SmartSignalsTestScenario.allCases) { scenario in
                Button {
                    selectedScenario = scenario
                } label: {
                    if selectedScenario == scenario {
                        Label(scenario.rawValue, systemImage: "checkmark")
                    } else {
                        Text(scenario.rawValue)
                    }
                }
            }
        } label: {
            HStack {
                Text(selectedScenario.rawValue)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.cardSurface)
            )
        }
        .foregroundStyle(Theme.textPrimary)
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mode: \(mode.rawValue)")
            if mode == .testScenarios {
                Text("Scenario: \(selectedScenario.rawValue)")
            }
            if let lastRefreshDate {
                Text("Last refresh: \(lastRefreshDate.formatted(date: .abbreviated, time: .standard))")
            }
            Text("Signals: \(signals.count)")
        }
        .font(Theme.captionFont)
        .foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private var signalList: some View {
        if signals.isEmpty {
            Text("No Smart Signals qualified for this data.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(signals) { signal in
                    signalCard(signal)
                }
            }
        }
    }

    private func signalCard(_ signal: SmartSignal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(signal.title)
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Text(signal.explanation)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)

            Group {
                Text("category: \(signal.category.rawValue)")
                Text("severity: \(signal.severity.rawValue)")
                Text("confidence: \(signal.confidence.rawValue)")
                Text("priority: \(signal.priority)")
                Text("id: \(signal.id)")
                Text("deduplicationID: \(signal.deduplicationID)")
                Text("evaluatedAt: \(signal.evaluatedAt.formatted())")
                Text("relevantDate: \(signal.relevantDate.map { $0.formatted() } ?? "None")")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)

            if !signal.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(signal.metrics) { metric in
                        Text("\(metric.label): \(formattedMetricValue(metric.value))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            if let action = signal.action {
                Text("Action: \(action.title)\(action.description.map { " \u{2014} \($0)" } ?? "")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            } else {
                Text("No action")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.cardSurface)
        )
    }

    /// Follows this codebase's existing formatting convention exactly (same as
    /// `BudgetSignalEngine`/`SpendingSignalEngine`/`SubscriptionSignalEngine`/`IncomeSignalEngine`'s
    /// private helpers): `en_US` currency style, and a percentage fraction (`0.60`) rendered as a
    /// rounded whole percent (`60%`).
    private func formattedMetricValue(_ value: SmartSignalMetric.Value) -> String {
        switch value {
        case .currency(let amount):
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = Locale(identifier: "en_US")
            return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
        case .percentage(let fraction):
            return "\(Int((fraction * 100).rounded()))%"
        case .count(let count):
            return "\(count)"
        case .number(let number):
            return "\(number)"
        case .text(let text):
            return text
        }
    }

    /// `Date()` is allowed only here, only for Live Data mode, only because the user explicitly
    /// tapped Refresh (or the screen just appeared) to evaluate against the current moment on
    /// their own device — never inside a Smart Signal engine, which always takes its evaluation
    /// date from the caller-supplied `context.now`.
    private func refresh() {
        let context: SmartSignalContext
        switch mode {
        case .liveData:
            let evaluationDate = Date()
            context = SmartSignalContext(
                transactions: transactions,
                accounts: accounts,
                categories: categories,
                incomeSources: incomeSources,
                recurringExpenses: recurringExpenses,
                budgetSettings: budgetSettingsList.first,
                monthlyPlanSettings: monthlyPlanSettingsList.first,
                now: evaluationDate
            )
            lastRefreshDate = evaluationDate
        case .testScenarios:
            context = SmartSignalsTestScenarioFactory.context(for: selectedScenario)
            lastRefreshDate = context.now
        }
        let engine = SmartSignalsEngine(engines: SmartSignalsTestScenarioFactory.defaultEngines)
        signals = engine.generateSignals(context: context)
    }
}

#Preview {
    SmartSignalsTestView()
        .modelContainer(SampleData.previewContainer)
}
#endif
