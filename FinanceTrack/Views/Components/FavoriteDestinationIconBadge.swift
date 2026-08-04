import SwiftUI

/// Shared colored icon treatment for a favorite destination — used identically by
/// `FavoritesConfigurationView`'s list rows and `FavoritesBarView`'s Dashboard pill, so the two
/// screens read from the SAME canonical color/icon source (`FavoriteDestinationID.accentColor`/
/// `.systemImageName`) rather than each defining its own color switch. `diameter`/`symbolSize` are
/// caller-supplied so each screen can size the visible badge independently of any surrounding tap
/// target — the Dashboard pill's own 44×44 tap target is a SEPARATE, larger invisible frame the
/// caller applies around this view; this badge is never stretched to fill it (locked "do not
/// enlarge the symbol to fill the entire 44-point tap target" requirement).
struct FavoriteDestinationIconBadge: View {
    let destination: FavoriteDestinationID
    var diameter: CGFloat = 32
    var symbolSize: CGFloat = 15

    var body: some View {
        Image(systemName: destination.systemImageName)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(destination.accentColor)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(destination.accentColor.opacity(0.18)))
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
