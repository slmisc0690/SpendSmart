import SwiftUI

/// Central design system for FinanceTrack. Dark-mode-first, premium finance-app aesthetic.
enum Theme {

    // MARK: - Background

    static let backgroundTop = Color(red: 0.055, green: 0.063, blue: 0.086)
    static let backgroundBottom = Color(red: 0.020, green: 0.024, blue: 0.035)

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Surfaces

    static let cardSurface = Color(red: 0.098, green: 0.110, blue: 0.145)
    static let cardSurfaceElevated = Color(red: 0.133, green: 0.149, blue: 0.192)
    static let cardStroke = Color.white.opacity(0.06)

    static func cardGradient(_ tint: Color = cardSurfaceElevated) -> LinearGradient {
        LinearGradient(
            colors: [tint.opacity(0.9), cardSurface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Brand / Accent

    static let accent = Color(red: 0.365, green: 0.616, blue: 1.0)      // premium blue
    static let accentSecondary = Color(red: 0.545, green: 0.404, blue: 1.0) // violet

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Status colors (spending state)

    static let statusGood = Color(red: 0.298, green: 0.851, blue: 0.592)
    static let statusWarning = Color(red: 1.0, green: 0.722, blue: 0.302)
    static let statusOver = Color(red: 1.0, green: 0.365, blue: 0.365)

    static func statusColor(for status: SpendingStatus) -> Color {
        switch status {
        case .good: return statusGood
        case .warning: return statusWarning
        case .over: return statusOver
        }
    }

    // MARK: - Category colors

    /// Resolves a `Category.colorName` (a semantic key like "blue" or "orange") to an actual
    /// color from the app's palette. Unknown names fall back to `accent` so a bad/legacy value
    /// never crashes or renders invisibly.
    static func categoryColor(named name: String) -> Color {
        switch name {
        case "blue": return accent
        case "indigo": return accentSecondary
        case "purple": return Color(red: 0.694, green: 0.518, blue: 0.996)
        case "green": return statusGood
        case "mint": return Color(red: 0.463, green: 0.867, blue: 0.769)
        case "teal": return Color(red: 0.302, green: 0.784, blue: 0.784)
        case "yellow": return Color(red: 1.0, green: 0.816, blue: 0.302)
        case "orange": return statusWarning
        case "red": return statusOver
        case "pink": return Color(red: 1.0, green: 0.451, blue: 0.686)
        case "gray": return Color.white.opacity(0.5)
        default: return accent
        }
    }

    // MARK: - Text

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    // MARK: - Typography

    static func amountFont(_ size: CGFloat = 34) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static let titleFont: Font = .system(size: 22, weight: .bold, design: .rounded)
    static let headlineFont: Font = .system(size: 17, weight: .semibold, design: .rounded)
    static let bodyFont: Font = .system(size: 15, weight: .medium, design: .rounded)
    static let captionFont: Font = .system(size: 13, weight: .medium, design: .rounded)

    // MARK: - Spacing & Radius

    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 24
        static let control: CGFloat = 14
        static let pill: CGFloat = 100
    }

    // MARK: - Shadow

    static let cardShadowColor = Color.black.opacity(0.35)
}

/// Represents whether spending is under, near, or over the configured budget.
enum SpendingStatus: Equatable {
    case good
    case warning
    case over

    /// Short label for compact UI like `StatusBadge`.
    var label: String {
        switch self {
        case .good: return "On Track"
        case .warning: return "Getting Close"
        case .over: return "Over Budget"
        }
    }

    /// Full-sentence status message shown on the dashboard's weekly spending hero card.
    var dashboardMessage: String {
        switch self {
        case .good: return "You're on track"
        case .warning: return "Getting close"
        case .over: return "Over weekly limit"
        }
    }
}
