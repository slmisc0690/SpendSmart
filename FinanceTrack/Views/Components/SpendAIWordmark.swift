import SwiftUI

/// THE ONE canonical "SpendAI" wordmark component — renders Scott's supplied multicolor
/// `SpendAI_Text.png` artwork (`SpendAIWordmark` asset, byte-identical copy — verified via
/// checksum at import time). Image-based, never rendered as SwiftUI text and never an SF Symbol
/// approximation. `.renderingMode(.original)` and no tint modifier anywhere in this file preserve
/// the artwork's own colors exactly as supplied; `.scaledToFit()` preserves its native aspect
/// ratio (never stretched/cropped).
///
/// Weekly/Activity/Manual Accounts (`SpendAILauncherControl`, below) all share this single
/// component — never three separate per-screen implementations.
struct SpendAIWordmark: View {
    var height: CGFloat = 12

    var body: some View {
        Image("SpendAIWordmark")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("SpendAI")
    }
}

#Preview {
    SpendAIWordmark()
        .padding()
        .background(Theme.backgroundGradient)
}
