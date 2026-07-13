import SwiftUI

/// Standard premium card container used across the dashboard, accounts, and settings screens.
struct CardBackground<Content: View>: View {
    var tint: Color = Theme.cardSurfaceElevated
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Spacing.lg)
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
