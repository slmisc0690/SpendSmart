import SwiftUI

/// Small selectable pill used for display-only filters (e.g. the Weekly screen's
/// All Counted / Pending / Excluded transaction list filters). Purely a UI filter — never
/// changes what `BudgetCalculator` counts, only what's shown in a list.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    Capsule().fill(isSelected ? Theme.accent.opacity(0.2) : Theme.cardSurface)
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Theme.accent : Theme.cardStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HStack(spacing: 8) {
        FilterChip(title: "All Counted", isSelected: true) {}
        FilterChip(title: "Pending", isSelected: false) {}
        FilterChip(title: "Excluded", isSelected: false) {}
    }
    .padding()
    .background(Theme.backgroundGradient)
}
