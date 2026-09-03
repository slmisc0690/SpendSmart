import SwiftUI

/// SETTINGS HIERARCHY CORRECTION — replaces the default `DisclosureGroup` presentation for
/// Settings' Tools subsections (Auto Calculate/Quick Stats/Data Tools) and Developer Options.
/// Scott's physical-device feedback on the native `DisclosureGroup` chevron was specific: too
/// small, too far from the label, sitting almost against the trailing screen edge. SwiftUI's
/// built-in disclosure indicator is system-drawn and not repositionable/resizable, so this custom,
/// reusable row replaces it — a plain tappable row whose own chevron sits immediately after the
/// title (never far-right), is a comfortable, clearly visible size, and rotates with the expand/
/// collapse animation. One shared component keeps all four collapsible rows visually and
/// behaviorally consistent, rather than four independent implementations.
///
/// `isMajorSection` selects between two presentations sharing the same interaction model:
/// - `false` (Auto Calculate/Quick Stats/Data Tools): the existing row text size (`Theme.
///   headlineFont`, matching every other Settings row title) plus a leading indent, so the row
///   visually reads as a CHILD of the "Tools" heading above it — never enlarged, per Scott's
///   explicit "children remain approximately their existing text size" instruction.
/// - `true` (Developer Options): renders the shared `MajorSectionHeaderCard` (SETTINGS MAJOR-
///   SECTION CARDS phase) — the same rounded dark-glass card Account/Tools/About use — with no
///   extra indent, since it must visually read as ITS OWN major section, not a Tools child, while
///   still being collapsed-by-default content. `majorSectionIcon` is required whenever
///   `isMajorSection` is `true`.
struct SettingsCollapsibleSection<Content: View>: View {
    let title: String
    var infoTitle: String? = nil
    var infoExplanation: String? = nil
    var isMajorSection: Bool = false
    var majorSectionIcon: String? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    private var indent: CGFloat { isMajorSection ? 0 : Theme.Spacing.md }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if isMajorSection {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    MajorSectionHeaderCard(
                        icon: majorSectionIcon ?? "questionmark",
                        title: title,
                        infoTitle: infoTitle,
                        infoExplanation: infoExplanation,
                        isExpanded: isExpanded
                    )
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(title)
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.textPrimary)
                        // Chevron sits immediately after the title (never far-right), is clearly
                        // visible (14pt bold, up from the system default), and rotates to
                        // communicate expanded/collapsed state — addresses Scott's exact three
                        // complaints in one control: size, distance from label, screen-edge
                        // placement.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Spacer()
                        if let infoTitle, let infoExplanation {
                            InfoButton(title: infoTitle, explanation: infoExplanation)
                        }
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }

            if isExpanded {
                content()
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.leading, indent)
    }
}
