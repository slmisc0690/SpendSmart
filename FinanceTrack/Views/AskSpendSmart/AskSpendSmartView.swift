import SwiftUI
import SwiftData
import UIKit

/// ASK SPENDSMART — the always-available conversational financial assistant, replacing the old
/// preset-question "Insights" screen. Free-form text is the ONLY way to ask a question; there is no
/// requirement to pick from a fixed list. Every dollar figure the assistant states comes from a
/// deterministic tool call into `AskSpendSmartToolContext` (which itself calls the app's existing
/// authoritative calculators) — the on-device model only decides which tool to call and explains
/// the result conversationally, never invents a number itself. See `AskSpendSmartService.swift`'s
/// own header for the provider abstraction, and `AskSpendSmartToolProvider.swift` for the
/// `@available(iOS 26.0, *)`-gated Foundation Models integration.
struct AskSpendSmartView: View {
    @Query private var transactions: [FinanceTransaction]
    @Query private var accounts: [Account]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var budgetSettingsList: [BudgetSettings]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]
    @Query private var savingsEntries: [SavingsEntry]

    @Environment(\.dismiss) private var dismiss
    @Environment(PlaidConnectionManager.self) private var plaidConnection

    /// PHASE 2 — APP-WIDE ACCESS: which screen this presentation was opened from, a lightweight
    /// hint only (see `AskSpendSmartScreenContext`'s own header) — never restricts which tools are
    /// available or what the user can ask. Defaults to `.dashboard` since every pre-Phase-2 call
    /// site (the Dashboard favorite) already represents that screen.
    var screenContext: AskSpendSmartScreenContext = .dashboard

    @State private var conversationModel: AskSpendSmartConversationModel?
    @State private var inputText = ""

    private static let examplePrompts = [
        "How much have I spent on restaurants this month?",
        "What bills are due before my next paycheck?",
        "If I want to save $1,000 this month, what's left to spend after bills?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let conversationModel {
                    if conversationModel.availability.isAvailable {
                        conversationBody(conversationModel)
                    } else {
                        unavailableView(conversationModel.availability)
                    }
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .principal) { headerBrand }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                if let conversationModel, !conversationModel.messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            startNewConversation()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New Conversation")
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            if conversationModel == nil {
                startNewConversation()
            }
        }
    }

    // MARK: - Header

    // USER-FACING BRANDING CORRECTION — the screen title now reads "Ask SpendAI" (the active
    // user-facing brand), replacing the earlier assistant brand text. Internal Swift type names/
    // asset name (`AskSpendSmartView`/`AskSpendSmartIcon`) are unaffected — visible text only.
    private var headerBrand: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image("AskSpendSmartIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Ask SpendAI")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Available conversation

    @ViewBuilder
    private func conversationBody(_ conversationModel: AskSpendSmartConversationModel) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if conversationModel.messages.isEmpty {
                        emptyStateGuidance
                    }
                    ForEach(conversationModel.messages) { message in
                        AskSpendSmartMessageBubble(message: message)
                            .id(message.id)
                    }
                    if conversationModel.sendState == .thinking {
                        AskSpendSmartThinkingIndicator()
                    }
                    if case .failed(let errorText) = conversationModel.sendState {
                        Text(errorText)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.statusOver)
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .onChange(of: conversationModel.messages.count) {
                if let lastId = conversationModel.messages.last?.id {
                    withAnimation { scrollProxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .scrollDismissesKeyboard(.interactively)
        }
        inputBar(conversationModel)
    }

    private var emptyStateGuidance: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Ask anything about your money")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Text("Type a question in your own words — no need to pick from a list. For example:")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.examplePrompts, id: \.self) { prompt in
                    Text("• \(prompt)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func inputBar(_ conversationModel: AskSpendSmartConversationModel) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("Ask SpendAI a question", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(Theme.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                .foregroundStyle(Theme.textPrimary)
                .disabled(!conversationModel.canSend)
                .onSubmit { send(conversationModel) }

            Button {
                send(conversationModel)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSubmit(conversationModel) ? Theme.accent : Theme.textTertiary)
            }
            .disabled(!canSubmit(conversationModel))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func canSubmit(_ conversationModel: AskSpendSmartConversationModel) -> Bool {
        conversationModel.canSend && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// FRESH SNAPSHOT PHASE — built fresh from this `body` evaluation's OWN `@Query`
    /// property-wrapper values (never a value captured earlier and reused), so every call reflects
    /// whatever is currently in the local SwiftData store/Plaid cache — never a stale snapshot from
    /// whenever this presentation's conversation started.
    @MainActor
    private func currentToolContext() -> AskSpendSmartToolContext {
        AskSpendSmartToolContext(
            transactions: transactions,
            accounts: accounts,
            plaidConnections: plaidConnection.connections,
            incomeSources: incomeSources,
            recurringExpenses: recurringExpenses,
            budgetSettings: budgetSettingsList.first,
            monthlyPlanSettings: monthlyPlanSettingsList.first,
            savingsEntries: savingsEntries
        )
    }

    private func send(_ conversationModel: AskSpendSmartConversationModel) {
        guard canSubmit(conversationModel) else { return }
        let text = inputText
        inputText = ""
        dismissKeyboard()
        let freshContext = currentToolContext()
        Task { await conversationModel.send(text, context: freshContext) }
    }

    // MARK: - Unavailable

    private func unavailableView(_ availability: AskSpendSmartAvailability) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image("AskSpendSmartIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .opacity(0.6)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Ask SpendAI Isn't Available Yet")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Text(availability.explanation)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
        }
    }

    // MARK: - Actions

    @MainActor
    private func startNewConversation() {
        let context = currentToolContext()
        let availability = AskSpendSmartServiceFactory.currentAvailability()
        let service = AskSpendSmartServiceFactory.makeService(toolContext: context, screenContext: screenContext)
        conversationModel = AskSpendSmartConversationModel(availability: availability, service: service)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Message bubble

private struct AskSpendSmartMessageBubble: View {
    let message: AskSpendSmartMessage

    var body: some View {
        HStack {
            if message.role == .assistant { bubble; Spacer(minLength: 40) } else { Spacer(minLength: 40); bubble }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var bubble: some View {
        Text(message.text)
            .font(Theme.bodyFont)
            .foregroundStyle(message.role == .assistant ? Theme.textPrimary : Color.white)
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(message.role == .assistant ? Theme.cardSurface : Theme.accent)
            )
    }
}

private struct AskSpendSmartThinkingIndicator: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView()
            Text("Thinking…")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }
}

#Preview {
    AskSpendSmartView()
        .modelContainer(SampleData.previewContainer)
        .environment(PlaidConnectionManager())
}
