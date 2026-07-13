import SwiftUI

/// Thin progress bar showing a credit card's utilization (balance vs. limit), color-coded by
/// `CreditUtilizationCalculator.status` — a threshold deliberately separate from the weekly
/// budget's `SpendingStatus`.
struct CreditUtilizationView: View {
    let balance: Decimal
    let limit: Decimal?

    private var ratio: Double {
        CreditUtilizationCalculator.utilization(balance: balance, limit: limit)
    }

    private var status: CreditUtilizationStatus {
        CreditUtilizationCalculator.status(balance: balance, limit: limit)
    }

    private var color: Color {
        switch status {
        case .good: return Theme.statusGood
        case .caution: return Theme.statusWarning
        case .high: return Theme.statusOver
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Credit Utilization")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(Int(ratio * 100))% \u{00B7} \(status.label)")
                    .font(Theme.captionFont)
                    .foregroundStyle(color)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(geometry.size.width * ratio, ratio > 0 ? 6 : 0))
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.4), value: ratio)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        CreditUtilizationView(balance: 200, limit: 8000)
        CreditUtilizationView(balance: 3200, limit: 8000)
        CreditUtilizationView(balance: 7200, limit: 8000)
    }
    .padding()
    .background(Theme.backgroundGradient)
}
