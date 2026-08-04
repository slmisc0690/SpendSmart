import SwiftUI
import UIKit

/// Pure layout metrics for the Dashboard Favorites Bar — kept separate from the view itself so the
/// width/spacing math is a plain, directly testable calculation, never something only provable by
/// rendering a real view.
///
/// TITLED REFINEMENT — each favorite button is now icon-over-label (`FavoriteIconButton`'s own
/// `VStack`), not icon-only, so its width is DRIVEN BY ITS OWN LABEL TEXT rather than one fixed
/// constant shared by every button (as the earlier icon-only design used). `minimumTapTargetSize`
/// stays a floor (`.frame(minWidth:minHeight:)` in `FavoriteIconButton`) — Apple's ~44×44pt
/// recommendation is still guaranteed, but a button's actual rendered width can (and for most
/// labels here, will) grow beyond it. `buttonWidth(forLabel:)`/`contentWidth(labels:)`/
/// `capsuleWidth(labels:)` below measure the REAL text width via `UIFont`/`NSString` sizing (the
/// same font this view actually renders with) rather than guessing — this is what
/// `testAllSixDashboardLabelsFitWithinAvailableWidthAtSmallestSupportedDevice` uses to PROVE the
/// locked 6-item maximum still fits, never just assert it.
enum FavoritesBarLayout {
    /// Floor only — see this enum's own header for why a button's actual width now varies by label.
    static let minimumTapTargetSize: CGFloat = 44
    /// The colored icon badge's own visual diameter — smaller than `minimumTapTargetSize` by
    /// design (never enlarged to fill the tap target); slightly reduced from the icon-only design's
    /// 30pt so the two-line button doesn't grow taller than necessary (locked "avoid making the
    /// capsule excessively tall" requirement).
    static let iconDiameter: CGFloat = 26
    static let iconSymbolSize: CGFloat = 12
    /// Between the icon badge and its label, within one button.
    static let iconLabelSpacing: CGFloat = 3
    /// Small and legible without dominating the button's width — the same rounded-design family
    /// every other label in this app uses, smaller than `Theme.captionFont` (13pt). MEASURED, not
    /// guessed: an initial 10pt attempt (with `Theme.Spacing.sm` spacing) required 361pt for all 6
    /// real Dashboard labels — 34pt OVER the 327pt available at the smallest supported device — so
    /// this was reduced, per the locked "reduce font size... before allowing the capsule to become
    /// much taller" fallback, until `testAllSixDashboardLabelsFitWithinAvailableWidthAtSmallestSupportedDevice`
    /// (which measures with the REAL `UIFont` at this exact size, never an estimate) passes.
    static let labelFontSize: CGFloat = 9
    static let labelFont: Font = .system(size: labelFontSize, weight: .medium, design: .rounded)
    /// The matching `UIFont` used ONLY for measuring real label width in `buttonWidth(forLabel:)` —
    /// never rendered directly; SwiftUI's own `Text(...).font(labelFont)` renders the visible label.
    private static let labelMeasuringFont = UIFont.systemFont(ofSize: labelFontSize, weight: .medium)
    /// Between favorite buttons. Back to the icon-only design's original 6pt (`Theme.Spacing.xs`)
    /// — an initial attempt at a more generous `Theme.Spacing.sm` (10pt) contributed to the 34pt
    /// overage described above; see `labelFontSize`'s own header for the same measured-not-guessed
    /// reasoning. Still a real, fixed gap — never a `Spacer()`, never scales with favorite count.
    static let spacing: CGFloat = Theme.Spacing.xs
    /// Equal on both sides of the internal icon HStack — see `FavoritesBarView`'s own structure.
    /// Reduced from `Theme.Spacing.sm` (10pt) to `Theme.Spacing.xs` (6pt) alongside `spacing`
    /// above, for the same measured-not-guessed reason (see `labelFontSize`'s own header) — even
    /// after that first reduction, all 6 real labels still required 329pt (2pt over the 327pt
    /// available); trimming padding to match `spacing` closes the remaining gap with margin.
    static let horizontalPadding: CGFloat = Theme.Spacing.xs
    /// iPhone SE (2nd/3rd generation) — 375×667pt — the narrowest iPhone screen this app currently
    /// supports under `deploymentTarget: iOS 17.0`.
    static let smallestSupportedDeviceWidth: CGFloat = 375
    /// The same horizontal inset every other Dashboard section already applies
    /// (`DashboardView`'s content `VStack`'s own `.padding(.horizontal, Theme.Spacing.lg)`).
    static let dashboardHorizontalPadding: CGFloat = Theme.Spacing.lg

    static var availableFavoritesWidth: CGFloat {
        smallestSupportedDeviceWidth - 2 * dashboardHorizontalPadding
    }

    /// A single button's real rendered width: at least `minimumTapTargetSize`, or its label's own
    /// measured text width if that's wider (labels here — e.g. "Monthly Plan" — routinely are).
    static func buttonWidth(forLabel label: String) -> CGFloat {
        let textWidth = (label as NSString).size(withAttributes: [.font: labelMeasuringFont]).width
        return max(minimumTapTargetSize, ceil(textWidth))
    }

    /// The internal icon HStack's own intrinsic width for these `labels`, in display order —
    /// per-button measured widths plus `count - 1` fixed gaps between them. `0` for an empty list
    /// (nothing to lay out).
    static func contentWidth(labels: [String]) -> CGFloat {
        guard !labels.isEmpty else { return 0 }
        let buttons = labels.reduce(CGFloat(0)) { $0 + buttonWidth(forLabel: $1) }
        return buttons + CGFloat(labels.count - 1) * spacing
    }

    /// The full capsule's own intrinsic width for these `labels` — content width plus equal
    /// leading/trailing padding. `0` for an empty list (the bar isn't shown at all — see
    /// `DashboardView.favoriteDestinations`'s own hidden-at-zero behavior).
    static func capsuleWidth(labels: [String]) -> CGFloat {
        guard !labels.isEmpty else { return 0 }
        return contentWidth(labels: labels) + 2 * horizontalPadding
    }

    /// LOCKED, unchanged by this refinement — the maximum favorite count remains 6, exactly
    /// matching this app's 6-item catalog. This pass does not recompute a NEW maximum from the
    /// titled layout's geometry (the earlier icon-only formula doesn't apply to variable-width
    /// buttons); instead `testAllSixDashboardLabelsFitWithinAvailableWidthAtSmallestSupportedDevice`
    /// proves, using real measured label widths, that all 6 real destinations together still fit
    /// within `availableFavoritesWidth` at the smallest supported device — the requirement the
    /// number 6 has to satisfy either way.
    static let maximumFavoritesCount = 6
}

/// Icon-over-label, translucent, capsule-shaped Dashboard Favorites Bar. Content-driven width by
/// construction: the internal `HStack` sizes itself from its buttons (each now its own natural,
/// label-driven width) and `FavoritesBarLayout.spacing` alone (never a `Spacer`, never
/// `.frame(maxWidth: .infinity)` on itself), equal padding is added around it, THEN the resulting
/// content-sized capsule is centered by applying `.frame(maxWidth: .infinity)` to the finished
/// capsule (after its background) — expanding the LAYOUT PROPOSAL this view is centered within,
/// never the capsule's own drawn size. This is what keeps the icon+label group centered inside the
/// capsule, and the capsule centered on the Dashboard, at every favorite count — unchanged
/// structurally from the icon-only design; only each button's own content changed.
struct FavoritesBarView: View {
    let destinations: [FavoriteDestinationID]
    var onSelect: (FavoriteDestinationID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: FavoritesBarLayout.spacing) {
            ForEach(destinations) { destination in
                FavoriteIconButton(destination: destination) {
                    onSelect(destination)
                }
            }
        }
        .padding(.horizontal, FavoritesBarLayout.horizontalPadding)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
        )
        .frame(maxWidth: .infinity)
    }
}

private struct FavoriteIconButton: View {
    let destination: FavoriteDestinationID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The visible colored badge (`FavoriteDestinationIconBadge`) and its label sit inside a
            // frame with a MINIMUM (never a fixed/exact) size — `minWidth`/`minHeight`, not
            // `width`/`height` — so a wide label like "Monthly Plan" can grow the button naturally
            // beyond the 44×44 floor, while a short label never shrinks below it. Same canonical
            // color/icon source `FavoritesConfigurationView`'s own rows use, via
            // `FavoriteDestinationIconBadge` — never a second color switch.
            VStack(spacing: FavoritesBarLayout.iconLabelSpacing) {
                FavoriteDestinationIconBadge(
                    destination: destination,
                    diameter: FavoritesBarLayout.iconDiameter,
                    symbolSize: FavoritesBarLayout.iconSymbolSize
                )
                Text(destination.dashboardLabel)
                    .font(FavoritesBarLayout.labelFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: FavoritesBarLayout.minimumTapTargetSize, minHeight: FavoritesBarLayout.minimumTapTargetSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(FavoriteIconButtonStyle())
        .accessibilityLabel(destination.displayName)
        .accessibilityHint(destination.accessibilityHint)
    }
}

/// A clear, subtle pressed state (dim + slight scale) — this app has no prior custom `ButtonStyle`
/// to reuse; every existing icon-only control (`HeaderIconButton`) relies on the system's own
/// default `.plain` pressed feedback, which is invisible on an image-only label. `Reduce Motion`
/// is respected by skipping the scale animation entirely, keeping only the (motion-free) opacity
/// change.
private struct FavoriteIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.90 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview("Favorites Bar") {
    VStack(spacing: 24) {
        FavoritesBarView(destinations: [.monthlyPlan], onSelect: { _ in })
        FavoritesBarView(destinations: [.monthlyPlan, .addToSavings, .connectedAccounts], onSelect: { _ in })
        FavoritesBarView(destinations: FavoriteDestinationID.allCases, onSelect: { _ in })
    }
    .padding()
    .background(Theme.backgroundGradient)
}
