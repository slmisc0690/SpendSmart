import SwiftUI

/// Standard premium card container used across the dashboard, accounts, and settings screens.
struct CardBackground<Content: View>: View {
    var tint: Color = Theme.cardSurfaceElevated
    /// Defaults to the standard card padding used everywhere else; pass a smaller value only for
    /// intentionally compact cards (e.g. a half-width picker sitting in a row).
    var padding: CGFloat = Theme.Spacing.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.cardGradient(tint))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadowColor, radius: 20, x: 0, y: 10)
    }
}
