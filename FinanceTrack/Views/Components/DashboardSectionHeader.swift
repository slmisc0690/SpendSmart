import SwiftUI

/// Consistent section title used across the dashboard ("Accounts", "Recent Activity", etc.),
/// with an optional trailing text action.
struct DashboardSectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
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
