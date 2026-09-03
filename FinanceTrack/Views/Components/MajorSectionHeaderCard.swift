import SwiftUI

/// THE ONE shared "major section" header for Settings — Account/Tools/Developer Options/About —
/// matching Scott's reference screenshot: a rounded dark glass card (`CardBackground`, the exact
/// same component every other card in this app already uses — never a one-off style) containing
/// a monochrome section icon on the left, the section title in the app's existing major-heading
/// font (`Theme.titleFont`), an optional collapse/expand chevron (Developer Options only — the
/// only one of the four that is itself collapsible), and the standard "i" info button on the
/// right. One shared component keeps all four major headers visually identical.
///
/// No horizontal screen-margin is baked in here, matching this app's own established
/// `CardBackground` convention — every call site supplies its own `.padding(.horizontal, ...)`.
///
/// CARD HEIGHT CORRECTION — `CardBackground`'s own default `padding` (`Theme.Spacing.lg`, 24pt)
/// is uniform on all four sides, which is right for a full content card but reads as far too
/// thick for a header-only row (Scott's physical-device feedback). Rather than touch
/// `CardBackground` itself (shared by every other card in the app, where 24pt is correct), this
/// component passes `padding: 0` to it and applies its OWN directional padding instead — the
/// standard `Theme.Spacing.lg` horizontal inset (unchanged from before), but only 13pt vertical
/// (roughly half), a deliberate literal rather than a `Theme.Spacing` case since none of the
/// existing steps (10/16) land in the requested 12–14pt target.
struct MajorSectionHeaderCard: View {
    let icon: String
    let title: String
    var infoTitle: String? = nil
    var infoExplanation: String? = nil
    /// `nil` (the default) renders no chevron — Account/Tools/About are not themselves
    /// collapsible. A non-nil value renders a rotating chevron (Developer Options only).
    var isExpanded: Bool? = nil

    var body: some View {
        CardBackground(padding: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24)
                Text(title)
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.textPrimary)
                if let isExpanded {
                    // Same corrected chevron (14pt bold, close to the label, rotates on
                    // expand/collapse) established for the Tools children — reused here so
                    // Developer Options' own disclosure indicator stays visually consistent.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Spacer()
                if let infoTitle, let infoExplanation {
                    InfoButton(title: infoTitle, explanation: infoExplanation)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, 13)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        MajorSectionHeaderCard(icon: "person.fill", title: "Account", infoTitle: "About Account", infoExplanation: "Example.")
        MajorSectionHeaderCard(icon: "wrench.fill", title: "Tools", infoTitle: "About Tools", infoExplanation: "Example.")
        MajorSectionHeaderCard(icon: "chevron.left.forwardslash.chevron.right", title: "Developer Options", isExpanded: false)
        MajorSectionHeaderCard(icon: "info.circle.fill", title: "About", infoTitle: "About This Section", infoExplanation: "Example.")
    }
    .padding()
    .background(Theme.backgroundGradient)
}
