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
    /// TWO-LINE FAVORITES PHASE — the button's own vertical floor, kept SEPARATE from
    /// `minimumTapTargetSize` (which stays 44 and still governs WIDTH — see `buttonWidth(forLabel:)`
    /// — so the verified 8-item horizontal layout is completely untouched by this). A modest
    /// increase (not a redesign into a large card) so a two-line label (icon + two 9pt text lines)
    /// never feels cramped: `iconDiameter` (30) + `iconLabelSpacing` (3) + two lines of
    /// `labelFontSize` text comfortably fit within 56, with a little breathing room, while a
    /// single-line destination simply centers within the same modest height rather than looking
    /// tiny inside it.
    static let minimumButtonHeight: CGFloat = 56
    /// The icon badge's own visual diameter — smaller than `minimumTapTargetSize` by design (never
    /// enlarged to fill the tap target).
    ///
    /// PHASE 2B VISUAL ASSETS — restored to the original icon-only design's 30pt (up from the 26pt
    /// this had been trimmed to) now that `FavoriteDestinationIconBadge` renders Scott's supplied
    /// full-color artwork directly with no tinted circle backing — the richer artwork reads better
    /// with a touch more size, and this is purely a vertical/icon-size change: `buttonWidth(
    /// forLabel:)` is driven entirely by label text width, never icon diameter, so this has zero
    /// effect on the Favorites Bar's width-fit budget (still verified by
    /// `testAllSixDashboardLabelsFitWithinAvailableWidthAtSmallestSupportedDevice`).
    static let iconDiameter: CGFloat = 30
    /// No longer read by `FavoriteDestinationIconBadge` (a real artwork asset is sized by
    /// `diameter` alone, not a separate SF-Symbol point size) — left defined and still passed at
    /// the call site below for source compatibility, matching this phase's "visual-asset
    /// integration only" scope (no API-surface deletions).
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
    /// FAVORITES LAYOUT CORRECTION (physical-device feedback, 8-item selection) — tightened from
    /// the icon-only design's original `Theme.Spacing.xs` (6pt) to 4pt: Scott reported the 8-item
    /// bar felt loose and wanted items "slightly closer together," never touching. Still a real,
    /// fixed gap — never a `Spacer()`, never scales with favorite count.
    static let spacing: CGFloat = 4
    /// Equal on both sides of the internal icon HStack — see `FavoritesBarView`'s own structure.
    /// FAVORITES LAYOUT CORRECTION — tightened alongside `spacing` above, same physical-device
    /// feedback and same reasoning (a modest reduction, not a redesign).
    static let horizontalPadding: CGFloat = 4
    /// iPhone SE (2nd/3rd generation) — 375×667pt — the narrowest iPhone screen this app currently
    /// supports under `deploymentTarget: iOS 17.0`.
    static let smallestSupportedDeviceWidth: CGFloat = 375
    /// FAVORITES LAYOUT CORRECTION — reduced from `Theme.Spacing.lg` (24pt) to `Theme.Spacing.md`
    /// (16pt), specifically for the Favorites bar's own leading/trailing inset (never the
    /// "Favorites" heading label above it, which keeps the standard 24pt every other Dashboard
    /// section title uses) — Scott's explicit "content should start slightly farther left, reduce
    /// unnecessary leading inset" instruction. `DashboardView`'s own `favoritesBarSection` call
    /// site references this exact constant so the two can never drift apart.
    static let dashboardHorizontalPadding: CGFloat = Theme.Spacing.md

    /// STABLE-CENTERING ARCHITECTURE — the capsule's own fixed, content-driven HEIGHT: a button's
    /// vertical floor (`minimumButtonHeight`) plus the capsule's own top/bottom padding
    /// (`Theme.Spacing.xs`, matching `FavoritesBarView.capsule`'s own `.padding(.vertical:)`).
    /// `FavoritesBarView.body` constrains its outer `GeometryReader` to exactly this height — a
    /// `GeometryReader` is otherwise greedy in every unconstrained dimension, and this is the one
    /// dimension that must stay fixed/compact (never growing to fill the Dashboard's remaining
    /// vertical space) while WIDTH is deliberately left flexible for the `ScrollView` beneath it.
    static var pillHeight: CGFloat {
        minimumButtonHeight + 2 * Theme.Spacing.xs
    }

    static var availableFavoritesWidth: CGFloat {
        smallestSupportedDeviceWidth - 2 * dashboardHorizontalPadding
    }

    /// A single button's real rendered width: at least `minimumTapTargetSize`, or its label's own
    /// measured text width if that's wider (labels here — e.g. "Monthly Plan" — routinely are).
    ///
    /// TWO-LINE FAVORITES PHASE — `label` may now contain an embedded "\n" (see
    /// `FavoriteDestinationID.dashboardLabel`'s own header) for a destination that renders on two
    /// centered lines. Splitting on "\n" and measuring the WIDEST individual line — never the full
    /// joined string — matches how the two lines actually render (stacked, each centered, never
    /// side by side), so a two-line label's button is never wider than it visually needs to be. For
    /// any label with no "\n" (every pre-existing single-line destination), this splits into exactly
    /// one piece equal to the original string, so the measured width is byte-identical to before
    /// this phase — the locked, physically-verified 8-item width behavior is untouched.
    static func buttonWidth(forLabel label: String) -> CGFloat {
        let widestLineWidth = label
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { (String($0) as NSString).size(withAttributes: [.font: labelMeasuringFont]).width }
            .max() ?? 0
        return max(minimumTapTargetSize, ceil(widestLineWidth))
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

    /// FAVORITES-8 PHASE — raised from 6 to 8, matching the full 8-destination eligible catalog
    /// (every `FavoriteDestinationID` except the retired `.addToSavings` — see `isEligible`), so a
    /// user can now pin every available destination at once, including SpendAI. Unlike the earlier
    /// 6-item maximum, all 8 real labels together do NOT fit within `availableFavoritesWidth` at
    /// the smallest supported device (measured: ~421pt required vs. 327pt available — see
    /// `needsHorizontalScroll(labels:)` below and `testAllEightFavoritesRequireHorizontalScrollAtSmallestSupportedDevice`).
    /// Per Scott's explicit instruction, the fix is NOT to shrink icons/text further (they were
    /// already reduced once for the 6-item case — see `labelFontSize`'s own header) but to make the
    /// bar horizontally scrollable exactly when the real content requires it, while leaving the
    /// existing centered, non-scrolling presentation completely unchanged for any count that still
    /// fits (1 through 6, as before, and most real-world 7/8 selections that skip "Monthly Plan").
    static let maximumFavoritesCount = 8

    /// FAVORITES-8 PHASE — pure, directly testable predicate: does this exact set of labels
    /// theoretically need horizontal scrolling to avoid clipping at the SMALLEST SUPPORTED device?
    /// A width-BUDGET check only — informational/regression-testing (e.g. "the widest possible
    /// 8-selection still needs to scroll somewhere") — never consulted by `FavoritesBarView`'s own
    /// rendering anymore (see `STABLE-CENTERING ARCHITECTURE` on that type's own header: rendering
    /// uses a single `GeometryReader`-driven layout that scrolls or centers itself natively, with no
    /// boolean branch decision at all, on ANY device width, not just this one fixed baseline).
    static func needsHorizontalScroll(labels: [String]) -> Bool {
        capsuleWidth(labels: labels) > availableFavoritesWidth
    }
}

/// Icon-over-label, translucent, capsule-shaped Dashboard Favorites Bar. Content-driven width by
/// construction: the internal `HStack` sizes itself from its buttons (each now its own natural,
/// label-driven width) and `FavoritesBarLayout.spacing` alone (never a `Spacer`).
///
/// STABLE-CENTERING ARCHITECTURE — replaces the earlier two-branch design (a boolean
/// `needsHorizontalScroll` deciding between an explicitly-centered capsule and a plain
/// `ScrollView`, fed by a preference-key-based `.onPreferenceChange` round-trip from
/// `DashboardView`). That design had a real, physically-confirmed bug: the preference-key value
/// arrives ONE LAYOUT PASS AFTER the view's first render, so the boolean branch could flip (or the
/// centering inset could silently recompute against a stale width) AFTER the pill had already drawn
/// centered — Scott saw this as the pill visibly jumping left shortly after Dashboard finished
/// loading. There is no way to fully eliminate that class of bug while ANY rendering decision here
/// depends on a value that only becomes available after an extra render/callback round-trip.
///
/// The fix removes the round-trip entirely: `body` below reads its own available width directly
/// from a `GeometryReader` in the SAME layout pass that draws the content — never from Dashboard
/// state, never from a `PreferenceKey`, never updated a frame late. There is also no more boolean
/// branch to flip: ONE view tree (`ScrollView` wrapping `capsule.frame(minWidth:alignment:.center)`)
/// handles both cases natively via `.frame(minWidth:)`'s own well-defined behavior — expand-and-
/// center when content is narrower than the viewport, or report its own larger natural size (which
/// `ScrollView` then makes scrollable) when content is wider. Since both cases are the SAME code
/// path (not two mutually-exclusive branches), there is no transition between them to visibly jump
/// during. The visible capsule (background + internal padding) is unaffected either way — only the
/// INVISIBLE outer frame that positions it changes size.
struct FavoritesBarView: View {
    let destinations: [FavoriteDestinationID]
    var onSelect: (FavoriteDestinationID) -> Void

    private var capsule: some View {
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
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                // STABLE-CENTERING ARCHITECTURE — `.frame(minWidth:alignment:)` does the entire
                // "center if it fits, otherwise let it scroll" job in one declarative step:
                // - If `capsule`'s own natural width is NARROWER than `geometry.size.width`, this
                //   frame expands the INVISIBLE layout box to `geometry.size.width` and centers
                //   `capsule` (with its visible background) within that box — the pill itself never
                //   grows to fill the space, only the empty margin around it does.
                // - If `capsule`'s own natural width is WIDER, `minWidth` is already satisfied by
                //   the natural size, so this is a no-op and the capsule reports its true (larger)
                //   width — which `ScrollView` then makes scrollable, exactly like before.
                capsule
                    .frame(minWidth: geometry.size.width, alignment: .center)
            }
        }
        // The `GeometryReader` above is greedy in every dimension it isn't told otherwise, so its
        // HEIGHT must be pinned to the capsule's own real height (`FavoritesBarLayout.pillHeight`)
        // or it would silently expand to fill whatever vertical space its parent offers. WIDTH is
        // deliberately left unconstrained here — the `GeometryReader` reports whatever width ITS
        // parent proposes (the same "always fills its full proposed width" behavior the "Favorites"
        // heading's own `.frame(maxWidth: .infinity)` relies on), which is exactly the real,
        // synchronous, same-layout-pass width `geometry.size.width` above reads from.
        .frame(height: FavoritesBarLayout.pillHeight)
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
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: FavoritesBarLayout.minimumTapTargetSize, minHeight: FavoritesBarLayout.minimumButtonHeight)
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
