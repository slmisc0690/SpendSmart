import SwiftUI

/// Standard currency display used everywhere a dollar amount is shown.
struct AmountText: View {
    let amount: Decimal
    var font: Font = Theme.headlineFont
    var color: Color = Theme.textPrimary
    /// e.g. "-" or "+" for signed rows like transaction lists.
    var prefix: String = ""

    var body: some View {
        Text(prefix + CurrencyFormat.string(from: amount))
            .font(font)
            .foregroundStyle(color)
    }
}

enum CurrencyFormat {
    static func string(from amount: Decimal) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
