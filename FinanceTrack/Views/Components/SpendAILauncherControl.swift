import SwiftUI

/// THE ONE shared "SpendAI" header launcher control for screens that need a permanent, compact
/// header-area entry point into the assistant (Weekly/Activity/Manual Accounts — see each of
/// those screens' own call sites). Renders the canonical `AskSpendSmartGlyph` mascot artwork
/// ABOVE the canonical `SpendAIWordmark` image — never beside it, and never a plain
/// plain SwiftUI text label — matching Scott's exact requested layout. Deliberately a single shared
/// component, never duplicated per screen, so the artwork/sizing can never drift between screens.
///
/// USER-FACING BRANDING — the visible wordmark is "SpendAI" (the active assistant brand), not
/// the assistant's old name; tapping through still opens the same canonical `AskSpendSmartView`, whose own
/// header title reads "Ask SpendAI" once inside. Internal Swift type names
/// (`AskSpendSmartView`/`AskSpendSmartGlyph`/etc.) are unaffected — this is a user-facing visual
/// change only.
struct SpendAILauncherControl: View {
    var glyphSize: CGFloat = 32
    var wordmarkHeight: CGFloat = 12
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                AskSpendSmartGlyph(size: glyphSize)
                SpendAIWordmark(height: wordmarkHeight)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("SpendAI")
    }
}

#Preview {
    SpendAILauncherControl(action: {})
        .padding()
        .background(Theme.backgroundGradient)
}
