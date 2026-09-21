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
    @Environment(AuthenticationService.self) private var authService

    /// SESSION HISTORY — persists this conversation across app launches for the current calendar
    /// day only (Scott's explicit request); see `AskSpendSmartConversationStore`'s own header.
    private let conversationStore = AskSpendSmartConversationStore()

    /// PHASE 2 — APP-WIDE ACCESS: which screen this presentation was opened from, a lightweight
    /// hint only (see `AskSpendSmartScreenContext`'s own header) — never restricts which tools are
    /// available or what the user can ask. Defaults to `.dashboard` since every pre-Phase-2 call
    /// site (the Dashboard favorite) already represents that screen.
    var screenContext: AskSpendSmartScreenContext = .dashboard

    @State private var conversationModel: AskSpendSmartConversationModel?
    @State private var inputText = ""

    /// VOICE-FIRST OPEN — SpendAI defaults to listening for your question every time it opens
    /// (Scott's explicit request); `.keyboard` is both the fallback when permission is denied and
    /// the mode every SUBSEQUENT message in the conversation uses once the first question has been
    /// asked (voice-first only applies to how a session STARTS, not the whole conversation).
    private enum SpendAIInputMode {
        case voice
        case keyboard
    }
    @State private var inputMode: SpendAIInputMode = .keyboard
    @State private var voiceInput = SpendAIVoiceInputService()

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
                            startNewConversation(restoring: false)
                            Task { await beginVoiceModeIfPossible() }
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("Clear Conversation")
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            guard conversationModel == nil else { return }
            startNewConversation(restoring: true)
            // Voice-first only applies to a genuinely fresh conversation — restoring an earlier
            // history you're coming back to read is shown in keyboard mode first, never grabbing
            // the microphone the instant you open it to review past answers. Asking a NEW question
            // (by typing, or via the bottom "Ask another question" prompt once one exists) still
            // resumes voice for the next turn, same as any other answer.
            if conversationModel?.messages.isEmpty == true {
                await beginVoiceModeIfPossible()
            }
        }
        .onDisappear {
            voiceInput.stopListening()
        }
    }

    /// Checks (never re-prompts beyond iOS's own one-time system dialog) whether voice input is
    /// usable, then either starts listening immediately or falls back to `.keyboard` — silently,
    /// per Scott's explicit choice: a denied/restricted permission is never an error state the
    /// user has to dismiss, SpendAI just opens exactly like it always has.
    @MainActor
    private func beginVoiceModeIfPossible() async {
        var state = voiceInput.currentPermissionState()
        if state == .notDetermined {
            state = await voiceInput.requestPermissionIfNeeded()
        }
        guard state == .authorized, let conversationModel else {
            inputMode = .keyboard
            return
        }
        startVoiceListening(conversationModel)
    }

    /// ASK-ANOTHER-QUESTION — the single place voice listening is (re)started, used both for the
    /// very first question and for every subsequent one once an answer arrives (`send(_:)`, below)
    /// — Scott's explicit request that voice stays available turn after turn, not just on open.
    private func startVoiceListening(_ conversationModel: AskSpendSmartConversationModel) {
        inputMode = .voice
        voiceInput.startListening { [weak conversationModel] transcript in
            guard let conversationModel else { return }
            inputText = transcript
            send(conversationModel)
        }
    }

    private func switchToKeyboardInput() {
        voiceInput.stopListening()
        inputMode = .keyboard
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
        // FULL-SCREEN ONLY AT THE VERY START — once there's at least one exchange, the chat
        // history stays visible and voice mode instead shows as a compact bar under the last
        // answer (`voiceInputBar`, in `keyboardConversationBody` below) so asking a follow-up by
        // voice never hides what you already asked.
        if inputMode == .voice && conversationModel.messages.isEmpty {
            voiceListeningView
        } else {
            keyboardConversationBody(conversationModel)
        }
    }

    /// VOICE-FIRST OPEN — shown only for a genuinely fresh conversation, before the first question
    /// is asked. Tapping "Keyboard" cancels listening and drops straight into the exact same
    /// `keyboardConversationBody` every existing user already sees; auto-submit (3s of silence —
    /// see `SpendAIVoiceInputService`) routes through `startVoiceListening`'s closure to the same
    /// `send(_:)` every other submission path already uses, never a second send implementation.
    private var voiceListeningView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative, isActive: voiceInput.isListening)
            Text("What would you like to do?")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Text(voiceInput.transcript.isEmpty ? "Listening…" : voiceInput.transcript)
                .font(Theme.bodyFont)
                .foregroundStyle(voiceInput.transcript.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
                .animation(.default, value: voiceInput.transcript)
            Spacer()
            Button {
                switchToKeyboardInput()
            } label: {
                Label("Keyboard", systemImage: "keyboard")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func keyboardConversationBody(_ conversationModel: AskSpendSmartConversationModel) -> some View {
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
        if inputMode == .voice {
            voiceInputBar(conversationModel)
        } else {
            inputBar(conversationModel)
        }
    }

    /// ASK-ANOTHER-QUESTION — the compact, docked-at-bottom counterpart to `voiceListeningView`,
    /// shown under the existing chat history once at least one exchange has happened (Scott's
    /// explicit request: after SpendAI answers, voice stays available for a follow-up without
    /// losing sight of what was already asked). Sized bigger per Scott's own feedback (it read as
    /// too small), and the whole label area is now a real tappable `Button` — restarting listening
    /// if it isn't already active for any reason — rather than inert text that did nothing when
    /// tapped. "Keyboard" behaves identically to the full-screen version.
    private func voiceInputBar(_ conversationModel: AskSpendSmartConversationModel) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                guard !voiceInput.isListening, voiceInput.currentPermissionState() == .authorized else { return }
                startVoiceListening(conversationModel)
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: voiceInput.isListening)
                    Text(voiceInput.transcript.isEmpty ? "Ask another question…" : voiceInput.transcript)
                        .font(Theme.headlineFont)
                        .foregroundStyle(voiceInput.transcript.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(2)
                        .animation(.default, value: voiceInput.transcript)
                    Spacer(minLength: Theme.Spacing.sm)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                switchToKeyboardInput()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel("Keyboard")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(minHeight: 64)
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
                .padding(.vertical, Theme.Spacing.sm)
                .padding(.leading, Theme.Spacing.sm)
                .padding(.trailing, 36)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                // VOICE FROM THE KEYBOARD — a mic icon docked inside the trailing edge of the SAME
                // text-entry box (Scott's own explicit placement), always available regardless of
                // whether you've typed anything, so you're never stuck on keyboard-only once
                // you've switched away from voice.
                .overlay(alignment: .trailing) {
                    Button {
                        guard voiceInput.currentPermissionState() == .authorized else { return }
                        inputText = ""
                        startVoiceListening(conversationModel)
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.trailing, Theme.Spacing.sm)
                    .accessibilityLabel("Ask by voice")
                }
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

    /// ASK-ANOTHER-QUESTION + SESSION HISTORY — after the answer arrives, this is the ONE place
    /// that (1) persists the updated conversation (`AskSpendSmartConversationStore`, current
    /// calendar day only) and (2) resumes voice listening for a follow-up if the permission is
    /// still authorized — both the typed-question path (`inputBar`) and the voice-question path
    /// (`startVoiceListening`'s auto-submit closure) route through this single function, so neither
    /// persistence nor voice-resume needs a second implementation.
    private func send(_ conversationModel: AskSpendSmartConversationModel) {
        guard canSubmit(conversationModel) else { return }
        let text = inputText
        inputText = ""
        dismissKeyboard()
        inputMode = .keyboard
        let freshContext = currentToolContext()
        Task {
            await conversationModel.send(text, context: freshContext)
            conversationStore.save(conversationModel.messages, userId: authService.currentUserId)
            if voiceInput.currentPermissionState() == .authorized {
                startVoiceListening(conversationModel)
            }
        }
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

    /// `restoring: true` (the initial `.task`) loads today's saved conversation, if any — see
    /// `AskSpendSmartConversationStore`'s own header for exactly when that is/isn't available.
    /// `restoring: false` (the toolbar "Clear Conversation" button) explicitly wipes the stored
    /// conversation and starts genuinely empty — these are deliberately different, since restoring
    /// on every open would make "Clear Conversation" a no-op.
    @MainActor
    private func startNewConversation(restoring: Bool) {
        let context = currentToolContext()
        let availability = AskSpendSmartServiceFactory.currentAvailability()
        let service = AskSpendSmartServiceFactory.makeService(toolContext: context, screenContext: screenContext)
        let initialMessages: [AskSpendSmartMessage]
        if restoring {
            initialMessages = conversationStore.load(userId: authService.currentUserId)
        } else {
            conversationStore.clear(userId: authService.currentUserId)
            initialMessages = []
        }
        conversationModel = AskSpendSmartConversationModel(availability: availability, service: service, initialMessages: initialMessages)
        inputMode = .keyboard
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
