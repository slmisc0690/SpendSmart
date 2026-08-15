import SwiftUI

/// Consistent section title used across the dashboard ("Accounts", "Recent Activity", etc.),
/// with an optional trailing text action and an optional "i" info button.
struct DashboardSectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// Plain-language title/explanation for this section's "i" button — `nil` (the default) shows
    /// no info button at all, so every existing call site keeps its exact prior appearance.
    var infoTitle: String? = nil
    var infoExplanation: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let infoTitle, let infoExplanation {
                InfoButton(title: infoTitle, explanation: infoExplanation)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }
}
