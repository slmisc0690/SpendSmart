import Foundation

/// SPENDAI CONVERSATION HISTORY — persists ONE Ask SpendSmart conversation across app launches for
/// exactly the current LOCAL calendar day, per Scott's own explicit spec: "if I have 5 questions, I
/// can go back to look, but come the next day, it resets." `load(userId:)` returns an empty history
/// whenever nothing is saved OR the saved conversation's `savedAt` isn't the SAME local calendar day
/// as now — matching this app's own established local-calendar-day convention for client-side
/// features (never a rolling 24-hour window, never UTC — see `BudgetCalculator`'s own half-open
/// month/week boundaries for the same convention elsewhere).
///
/// Backed by `UserDefaults`, namespaced per authenticated user — the same pattern
/// `TransactionPreferenceStore`/`PlaidConnectionManager` already use — so a shared device never
/// mixes one household member's chat history into another's. Deliberately still never leaves this
/// device: `AskSpendSmartMessage`'s own header already establishes it's never sent to a backend or
/// the cloud; this only adds LOCAL persistence across launches within the same calendar day.
struct AskSpendSmartConversationStore {
    private static let keyPrefix = "askSpendSmart.conversation.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(userId: UUID?) -> String {
        "\(Self.keyPrefix).\(userId?.uuidString ?? "anonymous")"
    }

    private struct StoredConversation: Codable {
        let messages: [AskSpendSmartMessage]
        let savedAt: Date
    }

    /// `[]` when there's nothing saved, or what's saved is from a prior calendar day — a stale
    /// conversation is never silently resurrected past its own day.
    func load(userId: UUID?, calendar: Calendar = .current, now: Date = .now) -> [AskSpendSmartMessage] {
        guard let data = defaults.data(forKey: key(userId: userId)),
              let stored = try? JSONDecoder().decode(StoredConversation.self, from: data),
              calendar.isDate(stored.savedAt, inSameDayAs: now)
        else { return [] }
        return stored.messages
    }

    /// Overwrites whatever was previously saved for this user — an empty `messages` array clears
    /// the stored conversation entirely rather than persisting a pointless empty record.
    func save(_ messages: [AskSpendSmartMessage], userId: UUID?, now: Date = .now) {
        guard !messages.isEmpty else {
            clear(userId: userId)
            return
        }
        let stored = StoredConversation(messages: messages, savedAt: now)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key(userId: userId))
    }

    func clear(userId: UUID?) {
        defaults.removeObject(forKey: key(userId: userId))
    }
}
