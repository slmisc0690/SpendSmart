import Foundation

/// How strongly a `SmartSignal` should draw the user's attention. Deliberately calm language
/// (never "critical"/"urgent") — Smart Signals observes, it doesn't alarm.
enum SmartSignalSeverity: String, Codable, CaseIterable, Sendable {
    case positive
    case information
    case headsUp
    case important
}
