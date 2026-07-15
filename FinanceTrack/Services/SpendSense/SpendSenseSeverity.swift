import Foundation

/// How strongly a `SpendSenseSignal` should draw the user's attention. Deliberately calm language
/// (never "critical"/"urgent") — Spend Sense observes, it doesn't alarm.
enum SpendSenseSeverity: String, Codable, CaseIterable, Sendable {
    case positive
    case information
    case headsUp
    case important
}
