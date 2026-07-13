import SwiftUI

/// A titled toggle with a small explanatory subtitle, used for the Add Expense screen's
/// "Counts Toward Weekly Budget" / "Exclude From Reports" / "Pending" options.
struct TransactionToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .tint(Theme.accent)
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.md) {
        TransactionToggleRow(title: "Counts Toward Weekly Budget", subtitle: "Include this in your weekly spending total", isOn: .constant(true))
        TransactionToggleRow(title: "Exclude From Reports", subtitle: "Hide this from weekly and monthly totals entirely", isOn: .constant(false))
    }
    .padding()
    .background(Theme.backgroundGradient)
}
