import SwiftUI
import UIKit

/// PHASE 2B VISUAL FIX — produces correctly-sized bottom navigation tab icons from Scott's
/// supplied full-color artwork, entirely at runtime, without ever modifying/re-exporting any
/// artwork file.
///
/// ROOT CAUSE this exists to fix (confirmed via `UIImage(named:).size`, not guessed): each `NavX`/
/// `AccountsArtwork` imageset declares only a single "1x" scale slot, so UIKit reports the image's
/// `.size` as its raw PIXEL dimensions interpreted directly as POINTS (e.g. `NavDashboard` →
/// 208×174pt, `AccountsArtwork` → 512×458pt — verified empirically). `UITabBarItem.image` lays out
/// from that `.size` directly — unlike an SF Symbol, which carries its own point-size semantics —
/// and once SwiftUI's `.tabItem` content is bridged to a native `UITabBarItem`, ordinary
/// `.resizable()`/`.frame()` modifiers on the icon are not honored (they DO work correctly
/// elsewhere in this app — e.g. `FavoriteDestinationIconBadge` — which never goes through this
/// native tab-bar bridging). The only reliable fix is to hand UIKit an image whose OWN intrinsic
/// `.size` is already small and tab-bar-appropriate.
///
/// `icon(named:)` renders the source artwork into a new bitmap sized to `targetDimension` on its
/// longer edge, preserving the original aspect ratio exactly (never stretched, never cropped) via
/// `UIGraphicsImageRenderer` at the current screen scale — a pure in-memory transformation; the
/// underlying `.imageset` PNG on disk is never touched. `.withRenderingMode(.alwaysOriginal)`
/// preserves the artwork's real colors (matching every other Phase 2B asset's
/// `template-rendering-intent: original`), never tinted/templated. Results are cached per asset
/// name since `label(_:assetName:)` is called on every `TabView` re-render.
enum TabBarIconRenderer {
    /// Approximately the same visual footprint as the SF Symbols this replaced (Apple's own tab
    /// bar icons render at roughly this point size) — within the requested 22–26pt range.
    static let targetDimension: CGFloat = 24

    private static var cache: [String: UIImage] = [:]

    /// Pure geometry — extracted from `icon(named:)` so the aspect-preserving math is directly
    /// unit-testable against known, controlled inputs, independent of any real asset's runtime-
    /// resolved size (asset lookup can vary subtly by trait collection/bundle context, which would
    /// otherwise make a test comparing against a separately-fetched `UIImage(named:).size` fragile).
    static func aspectFitSize(for sourceSize: CGSize, target: CGFloat) -> CGSize {
        sourceSize.width >= sourceSize.height
            ? CGSize(width: target, height: target * sourceSize.height / sourceSize.width)
            : CGSize(width: target * sourceSize.width / sourceSize.height, height: target)
    }

    static func icon(named name: String) -> UIImage {
        if let cached = cache[name] { return cached }
        guard let source = UIImage(named: name) else {
            assertionFailure("Missing tab bar icon asset: \(name)")
            return UIImage()
        }
        let size = aspectFitSize(for: source.size, target: targetDimension)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        let original = resized.withRenderingMode(.alwaysOriginal)
        cache[name] = original
        return original
    }

    /// The one place every bottom-nav tab item is built — always routes through `icon(named:)`
    /// above, so no tab item can accidentally bypass the sizing fix.
    @ViewBuilder
    static func label(_ title: String, assetName: String) -> some View {
        Label(
            title: { Text(title) },
            icon: {
                Image(uiImage: icon(named: assetName))
                    .renderingMode(.original)
            }
        )
    }
}
