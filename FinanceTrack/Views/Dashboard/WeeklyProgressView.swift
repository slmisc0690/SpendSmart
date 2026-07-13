import SwiftUI

/// Circular progress ring showing spend-vs-limit for the current week.
struct WeeklyProgressView: View {
    let spent: Decimal
    let limit: Decimal
    let status: SpendingStatus

    private var progress: Double {
        BudgetCalculator.progress(spent: spent, limit: limit)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.statusColor(for: status).opacity(0.10))
                .blur(radius: 18)

            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 14)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Theme.statusColor(for: status),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.statusColor(for: status).opacity(0.45), radius: 5)
                .animation(.easeOut(duration: 0.6), value: progress)

            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(Theme.amountFont(28))
                    .foregroundStyle(Theme.textPrimary)
                Text("of limit")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 140, height: 140)
    }
}

#Preview {
    WeeklyProgressView(spent: 210, limit: 350, status: .warning)
        .padding()
        .background(Theme.backgroundGradient)
}
