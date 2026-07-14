import Foundation

/// One piece of structured supporting evidence for a `SmartSignal` — deliberately typed rather
/// than pre-formatted, so a future UI can apply its own currency/percent formatting (and privacy
/// mode, locale, Dynamic Type) instead of parsing a display string back apart. No SwiftUI/Color
/// types belong here — this is pure data.
struct SmartSignalMetric: Identifiable, Equatable, Codable, Sendable {
    enum Value: Equatable, Codable, Sendable {
        case currency(Decimal)
        case percentage(Double)
        case count(Int)
        case number(Double)
        case text(String)
    }

    let id: String
    let label: String
    let value: Value
}
