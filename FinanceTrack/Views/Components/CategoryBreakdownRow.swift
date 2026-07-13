import SwiftUI

/// One row in a category spending breakdown: icon, name, net amount, and a percent-of-total bar.
/// Takes a `BudgetCalculator.CategoryTotal` directly so the view never recomputes spending math.
struct CategoryBreakdownRow: View {
    let categoryTotal: BudgetCalculator.CategoryTotal
    /// The period's total net spend, used only to size the percent bar/label.
    let periodTotal: Decimal
    var isPrivacyModeEnabled: Bool = false

    private var percent: Double {
        guard periodTotal > 0 else { return 0 }
        let ratio = NSDecimalNumber(decimal: categoryTotal.total / periodTotal).doubleValue
        return min(max(ratio, 0), 1)
    }

    private var color: Color {
        Theme.categoryColor(named: categoryTotal.category?.colorName ?? "gray")
    }

    /// "Uncategorized" is a display-only label — `categoryTotal.category` is `nil` for these,
    /// never a real `Category` record (none is ever created or persisted for this bucket).
    private var displayName: String {
        categoryTotal.category?.name ?? "Uncategorized"
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: categoryTotal.category?.iconName ?? "questionmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(color.opacity(0.16)))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    PrivacyAmountView(
                        amount: categoryTotal.total,
                        isPrivacyModeEnabled: isPrivacyModeEnabled,
                        font: Theme.bodyFont,
                        color: Theme.textPrimary
                    )
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(color)
                            .frame(width: max(geometry.size.width * percent, percent > 0 ? 4 : 0))
                    }
                }
                .frame(height: 6)

                Text("\(Int(percent * 100))% of weekly spending")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

#Preview {
    let category = Category(name: "Groceries", iconName: "cart.fill", colorName: "green")
    return CategoryBreakdownRow(
        categoryTotal: .init(category: category, total: 98.50),
        periodTotal: 350
    )
    .padding()
    .background(Theme.backgroundGradient)
}
