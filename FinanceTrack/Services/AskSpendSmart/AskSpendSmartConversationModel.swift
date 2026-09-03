import Foundation

/// Drives ONE Ask SpendSmart conversation/presentation: message history, availability, and
/// loading/error state. Deliberately never imports `FoundationModels` — it only ever talks to the
/// `AskSpendSmartServicing` protocol (see `AskSpendSmartService.swift`), so this type (and
/// `AskSpendSmartView`) compile and run on every deployment target this app supports (iOS 17+),
/// regardless of whether the on-device model itself is available on iOS 26+.
@Observable
final class AskSpendSmartConversationModel {
    enum SendState: Equatable {
        case idle
        case thinking
        case failed(String)
    }

    private(set) var messages: [AskSpendSmartMessage] = []
    private(set) var availability: AskSpendSmartAvailability
    private(set) var sendState: SendState = .idle

    /// `nil` whenever `availability` isn't `.available` — built once per presentation from the
    /// caller's already-fetched SwiftData snapshot, via `AskSpendSmartServiceFactory`.
    private var service: (any AskSpendSmartServicing)?

    init(availability: AskSpendSmartAvailability, service: (any AskSpendSmartServicing)?) {
        self.availability = availability
        self.service = service
    }

    var canSend: Bool {
        availability.isAvailable && sendState != .thinking
    }

    /// Sends `text` as a new user message and appends the assistant's reply once it arrives.
    /// A no-op (never appends a user message either) when `canSend` is `false` — mirrors this
    /// project's established double-submit-guard convention (e.g. `PayBillsView.submit()`).
    ///
    /// FRESH SNAPSHOT PHASE — `context`, when supplied, is pushed into the service via
    /// `updateToolContext(_:)` before this send, so a long-lived conversation still answers each
    /// question against CURRENT local data (see `AskSpendSmartToolContextBox`'s own header). `nil`
    /// skips the refresh entirely — used by tests that don't exercise this behavior.
    ///
    /// ERROR CLASSIFICATION — an `AskSpendSmartError` (see that type's own header) is shown via its
    /// specific `userFacingMessage`; any other error still falls back to the original generic text,
    /// so this remains a strict improvement with no behavior regression for an unclassified error.
    @MainActor
    func send(_ text: String, context: AskSpendSmartToolContext? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend, let service else { return }

        messages.append(AskSpendSmartMessage(role: .user, text: trimmed))
        sendState = .thinking
        if let context {
            service.updateToolContext(context)
        }
        do {
            let reply = try await service.send(trimmed)
            messages.append(AskSpendSmartMessage(role: .assistant, text: reply))
            sendState = .idle
        } catch let askError as AskSpendSmartError {
            sendState = .failed(askError.userFacingMessage)
        } catch {
            sendState = .failed("SpendAI couldn't answer that. Please try again.")
        }
    }
}
