import Foundation

/// One deterministic, local financial observation. Produced by a `SmartSignalEngine` from
/// existing calculation services — never from an external AI provider, and never networked.
///
/// `id` and `deduplicationID` are both supplied by the engine that creates the signal, never
/// generated here — this type has no `UUID()`/`Date()` defaults, so constructing one is always
/// fully deterministic and reproducible in tests.
struct SmartSignal: Identifiable, Equatable, Codable, Sendable {
    /// Stable identity for this exact signal instance (SwiftUI `List`/`ForEach` identity, etc.).
    let id: String
    /// The key `SmartSignalsEngine` deduplicates on — two signals sharing this value are treated
    /// as "the same observation," and only the higher-ranked one survives. Engines choose this
    /// deliberately (e.g. `"budget-pace-\(monthKey)"`), never derived from `id`.
    let deduplicationID: String
    let category: SmartSignalCategory
    let severity: SmartSignalSeverity
    let confidence: SmartSignalConfidence
    /// Higher sorts first. Scale and meaning are entirely up to the producing engine — the
    /// coordinator/ranking only ever compares these ordinally, never interprets the magnitude.
    let priority: Int
    let title: String
    let explanation: String
    let metrics: [SmartSignalMetric]
    let action: SmartSignalAction?
    /// The date this signal is actually ABOUT (e.g. the month it observed), if any — distinct from
    /// `evaluatedAt`. Used by ranking as the primary recency tiebreaker; falls back to
    /// `evaluatedAt` when nil (a signal with no natural subject date, e.g. an account-health
    /// snapshot).
    let relevantDate: Date?
    /// When this signal was computed — always supplied by the caller (via the injected `now` on
    /// `SmartSignalContext`), never `Date()` read inside this type.
    let evaluatedAt: Date
}
