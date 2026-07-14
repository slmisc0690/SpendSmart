import Foundation

/// Plain metadata describing a suggested next step for a `SmartSignal` — deliberately not
/// executable. Whatever eventually renders this (a future UI) decides what tapping it does; this
/// type carries no closure, navigation destination, deep link, or URL, so the Smart Signals
/// foundation stays fully decoupled from SwiftUI/navigation.
struct SmartSignalAction: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let description: String?
}
