import SwiftUI

/// Small color-coded pill showing spending status (Good / Warning / Over).
struct StatusBadge: View {
    let status: SpendingStatus

    var body: some View {
        let color = Theme.statusColor(for: status)
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status.label)
                .font(Theme.captionFont)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(color.opacity(0.15))
        )
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusBadge(status: .good)
        StatusBadge(status: .warning)
        StatusBadge(status: .over)
    }
    .padding()
    .background(Theme.backgroundGradient)
}
