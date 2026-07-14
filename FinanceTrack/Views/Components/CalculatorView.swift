import SwiftUI

/// A standalone four-function calculator, opened as a sheet from a Manual Account's detail
/// screen. Purely a scratchpad: it never touches any `Account`, `FinanceTransaction`, or
/// `TransactionPreferenceStore` — closing it returns to that same Manual Account screen exactly
/// as it was. Each presentation starts from a clean zero state, since `@State private var
/// engine = CalculatorEngine()` is evaluated fresh every time SwiftUI instantiates this view for
/// a new `.sheet` presentation.
struct CalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CalculatorEngine()

    private let keyRows: [[String]] = [
        ["7", "8", "9", "÷"],
        ["4", "5", "6", "×"],
        ["1", "2", "3", "−"],
        ["C", "0", ".", "+"],
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                displaySection
                keypad
                    .padding(.horizontal, Theme.Spacing.lg)
            }
            .padding(.top, Theme.Spacing.lg)
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var displaySection: some View {
        CardBackground {
            VStack(alignment: .trailing, spacing: 4) {
                if let errorMessage = engine.errorMessage {
                    Text(errorMessage)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.statusOver)
                }
                Text(engine.entryText)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Result")
            .accessibilityValue(engine.entryText)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var keypad: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(keyRows, id: \.self) { row in
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(row, id: \.self) { key in
                        calculatorButton(key)
                    }
                }
            }
            calculatorButton("=")
        }
    }

    private func calculatorButton(_ key: String) -> some View {
        Button {
            handleKey(key)
        } label: {
            Text(key)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(key == "=" ? Color.white : Theme.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(key == "=" ? Theme.accent : Theme.cardSurface)
                )
        }
        .accessibilityLabel(accessibilityLabel(for: key))
    }

    private func accessibilityLabel(for key: String) -> String {
        switch key {
        case "C": return "Clear"
        case "=": return "Equals"
        case "÷": return "Divide"
        case "×": return "Multiply"
        case "−": return "Subtract"
        case "+": return "Add"
        case ".": return "Decimal point"
        default: return key
        }
    }

    private func handleKey(_ key: String) {
        switch key {
        case "C": engine.clear()
        case "=": engine.equals()
        case ".": engine.inputDecimalPoint()
        case "+": engine.setOperation(.add)
        case "−": engine.setOperation(.subtract)
        case "×": engine.setOperation(.multiply)
        case "÷": engine.setOperation(.divide)
        default:
            if let digit = Int(key) { engine.inputDigit(digit) }
        }
    }
}

#Preview {
    CalculatorView()
}
