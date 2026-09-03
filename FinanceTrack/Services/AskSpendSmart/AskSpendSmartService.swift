import Foundation

/// One message in an Ask SpendSmart conversation, for on-screen display only — never persisted to
/// SwiftData or sent anywhere beyond this device/the on-device model itself.
struct AskSpendSmartMessage: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// Whether Ask SpendSmart's on-device model can currently answer a question. Deliberately mirrors
/// `SystemLanguageModel.Availability.UnavailableReason`'s cases (see `AskSpendSmartToolProvider`'s
/// `@available(iOS 26.0, *)`-gated mapping) PLUS one reason that type can't itself express: the
/// running OS predates iOS 26, so `FoundationModels` isn't linkable at all. Kept as its own,
/// non-`@available`-gated enum so `AskSpendSmartConversationModel`/`AskSpendSmartView` (which must
/// run on every deployment target this app supports, iOS 17+) can read it without ever importing
/// `FoundationModels` themselves.
enum AskSpendSmartAvailability: Equatable, Sendable {
    case available
    case unavailableOSVersionTooOld
    case unavailableDeviceNotEligible
    case unavailableAppleIntelligenceNotEnabled
    case unavailableModelNotReady
    case unavailableOther(String)

    var isAvailable: Bool { self == .available }

    /// Plain-English explanation shown in `AskSpendSmartView`'s unavailable state — never a raw
    /// system error string, so this reads correctly regardless of iOS version.
    var explanation: String {
        switch self {
        case .available:
            return ""
        case .unavailableOSVersionTooOld:
            return "SpendAI needs iOS 26 or later. Update iOS to use it."
        case .unavailableDeviceNotEligible:
            return "SpendAI needs a device that supports Apple Intelligence."
        case .unavailableAppleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use SpendAI."
        case .unavailableModelNotReady:
            return "Apple Intelligence is still getting ready on this device. Try again in a bit."
        case .unavailableOther:
            return "SpendAI isn't available right now. Try again later."
        }
    }
}

/// PHASE 2 — APP-WIDE ACCESS: a lightweight HINT identifying which screen an Ask SpendSmart
/// presentation was opened from, so the assistant can answer contextual follow-ups like "why is
/// this lower this week?" Deliberately just a fixed, strongly-typed enum with a short display
/// sentence — never an arbitrary string threaded through views, never a screen's live data model,
/// and never itself a source of financial figures (see `contextHint`'s own header). Every case
/// maps to exactly one of this app's primary screens; there is no "none" case because every
/// `AskSpendSmartView` presentation is opened from a specific, known screen.
enum AskSpendSmartScreenContext: Equatable, Sendable {
    case dashboard
    case weekly
    case activity
    case manualAccounts
    case monthlyPlan
    case settings

    /// A single plain-English sentence appended to the model's instructions at session creation
    /// (see `SystemAskSpendSmartService.init`) — purely descriptive of WHERE the conversation was
    /// opened from. Contains no dollar amounts, dates, account identifiers, or any other figure a
    /// deterministic tool could instead compute — screen context must never become a second,
    /// competing source of financial data (see this type's own header).
    var contextHint: String {
        switch self {
        case .dashboard: return "This conversation was opened from the Dashboard."
        case .weekly: return "This conversation was opened from the Weekly Spending screen."
        case .activity: return "This conversation was opened from the Activity screen."
        case .manualAccounts: return "This conversation was opened from the Manual Accounts screen."
        case .monthlyPlan: return "This conversation was opened from the Monthly Plan screen."
        case .settings: return "This conversation was opened from Settings."
        }
    }
}

/// RUNTIME RELIABILITY PHASE — distinct, user-facing failure categories, replacing the old
/// one-size-fits-all "SpendAI couldn't answer that. Please try again." for every possible failure
/// (Part 13's own explicit requirement). Deliberately plain `Error`/`Sendable` with no
/// `FoundationModels` dependency, so `AskSpendSmartConversationModel`/tests can reference it without
/// pulling in that import — the actual mapping FROM `LanguageModelSession.GenerationError` lives in
/// `AskSpendSmartToolProvider.swift` (`@available(iOS 26.0, *)`, imports `FoundationModels`) as an
/// `@available`-gated extension on this type, keeping this file itself import-clean.
enum AskSpendSmartError: Error, Equatable, Sendable {
    /// The session's transcript grew too large for the model to continue — `SystemAskSpendSmartService`
    /// already retries once against a freshly recreated session before this ever reaches the UI; it
    /// only surfaces here if that retry ALSO failed.
    case contextSizeExceeded
    case guardrailViolation
    case unsupportedLanguage
    case modelBusy
    /// A tool's output failed to encode/decode across the model boundary — the closest analog this
    /// architecture has to "local data access failure," since every tool reads already-fetched,
    /// already-validated Swift values (see `AskSpendSmartToolContext`'s own header) and never
    /// touches a live `ModelContext`.
    case localDataAccessFailure
    case other(String)

    var userFacingMessage: String {
        switch self {
        case .contextSizeExceeded:
            return "This conversation has gotten long for SpendAI to track. Please start a New Conversation and ask again."
        case .guardrailViolation:
            return "SpendAI can't help with that particular request. Try rephrasing your question."
        case .unsupportedLanguage:
            return "SpendAI doesn't support that language yet. Try asking in English."
        case .modelBusy:
            return "SpendAI is busy right now. Please try again in a moment."
        case .localDataAccessFailure:
            return "SpendAI could not read the current local data. No information was changed."
        case .other:
            return "SpendAI couldn't answer that. Please try again."
        }
    }
}

/// PROVIDER ABSTRACTION — the one seam between Ask SpendSmart's conversation/UI layer and whatever
/// actually generates a response. Every method here works with plain `String`/`Sendable` types
/// only, never a `FoundationModels` type, so a future stronger/cloud provider could conform to this
/// same protocol without touching `AskSpendSmartConversationModel`, `AskSpendSmartView`, or any of
/// the deterministic financial tools in `AskSpendSmartToolContext`. The on-device
/// `SystemAskSpendSmartService` (see `AskSpendSmartToolProvider.swift`, `@available(iOS 26.0, *)`)
/// is the only conformer implemented in this phase.
protocol AskSpendSmartServicing: AnyObject {
    /// Sends one user message to the model and returns its conversational reply. Multi-turn
    /// context (prior messages in this presentation) is retained internally by the conformer — see
    /// `SystemAskSpendSmartService`'s own header for why the underlying session, not this protocol,
    /// owns that state.
    func send(_ userMessage: String) async throws -> String

    /// FRESH SNAPSHOT PHASE — refreshes the local app data this service's tools read from,
    /// immediately before the next `send(_:)`. `AskSpendSmartToolContext` has no `FoundationModels`
    /// dependency of its own (see its own header), so it's safe to name directly in this
    /// FoundationModels-agnostic protocol. A conformer with nothing to refresh (a test double, a
    /// future non-tool-based provider) may implement this as a no-op.
    func updateToolContext(_ context: AskSpendSmartToolContext)
}

/// Builds the current `AskSpendSmartAvailability` and, when available, a real
/// `AskSpendSmartServicing` instance. The ONLY place in this file that touches `#available` — every
/// other Ask SpendSmart type (conversation model, view) calls through here instead of checking iOS
/// version itself, so a future second provider only ever needs to change this one factory.
enum AskSpendSmartServiceFactory {
    @MainActor
    static func currentAvailability() -> AskSpendSmartAvailability {
        guard #available(iOS 26.0, *) else { return .unavailableOSVersionTooOld }
        return SystemAskSpendSmartService.currentAvailability()
    }

    /// `nil` whenever `currentAvailability()` isn't `.available` — callers must check availability
    /// first and show the unavailable state rather than calling this and force-unwrapping.
    @MainActor
    static func makeService(toolContext: AskSpendSmartToolContext, screenContext: AskSpendSmartScreenContext) -> (any AskSpendSmartServicing)? {
        guard #available(iOS 26.0, *) else { return nil }
        guard SystemAskSpendSmartService.currentAvailability() == .available else { return nil }
        return SystemAskSpendSmartService(toolContext: toolContext, screenContext: screenContext)
    }
}
