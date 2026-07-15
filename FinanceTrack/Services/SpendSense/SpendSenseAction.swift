import Foundation

/// Plain metadata describing a suggested next step for a `SpendSenseSignal` — deliberately not
/// executable. Whatever eventually renders this (a future UI) decides what tapping it does; this
/// type carries no closure, navigation destination, deep link, or URL, so the Spend Sense
/// foundation stays fully decoupled from SwiftUI/navigation.
struct SpendSenseAction: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let description: String?
}
