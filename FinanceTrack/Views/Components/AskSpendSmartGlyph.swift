import SwiftUI

/// THE ONE consistent SpendAI icon rendering. Used directly by `MonthlyPlanView`'s own toolbar
/// entry point, and indirectly by Weekly/Activity/Manual Accounts via the shared
/// `SpendAILauncherControl` (which wraps this glyph above its "SpendAI" label — see that
/// component's own header). Dashboard reaches the assistant only through the Favorites bar
/// (`FavoriteDestinationIconBadge`, a separate rendering path), and Settings has no assistant entry
/// point at all — see `SettingsView`'s own header note on that removal.
///
/// Always renders `AskSpendSmartIcon` (the Phase 1 asset copied from `spendai.png` — never
/// modified, never regenerated, never swapped for an SF Symbol) at a small, explicit size with
/// `.resizable().scaledToFit()` so it never stretches and always preserves its original aspect
/// ratio. Deliberately just the glyph itself, with NO button chrome — each caller wraps this in
/// whatever button/toolbar style already matches its own native header idiom. Visual consistency
/// comes from this one glyph treatment, not from forcing every screen's surrounding chrome to match.
struct AskSpendSmartGlyph: View {
    var size: CGFloat = 20

    var body: some View {
        Image("AskSpendSmartIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

#Preview {
    AskSpendSmartGlyph()
        .padding()
        .background(Theme.backgroundGradient)
}
