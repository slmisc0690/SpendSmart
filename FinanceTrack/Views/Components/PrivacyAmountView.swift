import SwiftUI

/// Wraps `AmountText`: shows the real amount normally, or a row of masking dots when privacy
/// mode is on. Labels around it stay visible — only the figure itself is hidden.
struct PrivacyAmountView: View {
    let amount: Decimal
    var isPrivacyModeEnabled: Bool
    var font: Font = Theme.headlineFont
    var color: Color = Theme.textPrimary
    var prefix: String = ""

    var body: some View {
        if isPrivacyModeEnabled {
            Text("•••••")
                .font(font)
                .foregroundStyle(color)
                .accessibilityLabel("Amount hidden")
        } else {
            AmountText(amount: amount, font: font, color: color, prefix: prefix)
        }
    }
}
