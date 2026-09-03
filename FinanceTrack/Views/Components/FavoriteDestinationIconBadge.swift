import SwiftUI

/// Shared full-color artwork treatment for a favorite destination — used identically by
/// `FavoritesConfigurationView`'s list rows and `FavoritesBarView`'s Dashboard pill, so the two
/// screens read from the SAME canonical artwork source (`FavoriteDestinationID.imageAssetName`)
/// rather than each defining its own icon lookup. `diameter` is caller-supplied so each screen can
/// size the visible badge independently of any surrounding tap target — the Dashboard pill's own
/// 44×44 tap target is a SEPARATE, larger invisible frame the caller applies around this view; this
/// badge is never stretched to fill it (locked "do not enlarge the symbol to fill the entire
/// 44-point tap target" requirement).
///
/// PHASE 2B VISUAL ASSETS — replaces the prior SF-Symbol-in-a-tinted-circle treatment with Scott's
/// supplied full-color PNG artwork. `.scaledToFit()` preserves each image's original aspect ratio
/// (never stretched); `.renderingMode(.original)` plus each asset's own `template-rendering-intent:
/// original` Contents.json property together guarantee the artwork's real colors render as
/// supplied — never tinted, never treated as an SF-Symbol-style template mask. `symbolSize` is
/// intentionally unused now (kept as a parameter only for source compatibility with existing call
/// sites) — a real photographic/illustrated asset is sized by `diameter` alone, not by a separate
/// glyph-vs-frame distinction that only made sense for a monochrome SF Symbol.
struct FavoriteDestinationIconBadge: View {
    let destination: FavoriteDestinationID
    var diameter: CGFloat = 32
    var symbolSize: CGFloat = 15

    var body: some View {
        Image(destination.imageAssetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: diameter, height: diameter)
    }
}

#Preview {
    VStack(spacing: 16) {
        ForEach(FavoriteDestinationID.allCases) { destination in
            HStack(spacing: 12) {
                FavoriteDestinationIconBadge(destination: destination)
                Text(destination.displayName)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }
    .padding()
    .background(Theme.backgroundGradient)
}
