import Foundation

/// How much data an engine had to work with when it produced a `SmartSignal` — lets the UI (later)
/// soften language for a signal built on a thin sample, rather than stating it with the same
/// certainty as one backed by months of history.
enum SmartSignalConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case limitedData
}
