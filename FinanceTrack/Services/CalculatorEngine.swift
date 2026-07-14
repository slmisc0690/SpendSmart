import Foundation

/// A small, deterministic four-function calculator — the standard "accumulator + pending
/// operation + current entry" algorithm (the same shape as a basic pocket calculator), never
/// `NSExpression` or any text-parsing evaluator. A pure value type with zero dependency on
/// SwiftUI, `Account`, `FinanceTransaction`, or `TransactionPreferenceStore` — it has no way to
/// read or write any of those, so using it can never change a balance, create/modify a
/// transaction, or affect remembered transaction preferences.
struct CalculatorEngine: Equatable {
    enum Operation: String, Equatable {
        case add = "+"
        case subtract = "−"
        case multiply = "×"
        case divide = "÷"
    }

    /// What the display should currently show — the value being typed, or the most recent result.
    private(set) var entryText: String = "0"
    private var accumulatedValue: Decimal = 0
    private var pendingOperation: Operation?
    private var isEnteringFreshValue = true
    /// Set only when `divide` was attempted with a zero divisor; cleared by any subsequent input.
    private(set) var errorMessage: String?

    private var currentValue: Decimal {
        Decimal(string: entryText) ?? 0
    }

    mutating func inputDigit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        errorMessage = nil
        if isEnteringFreshValue || entryText == "0" {
            entryText = "\(digit)"
            isEnteringFreshValue = false
        } else {
            entryText += "\(digit)"
        }
    }

    mutating func inputDecimalPoint() {
        errorMessage = nil
        if isEnteringFreshValue {
            entryText = "0."
            isEnteringFreshValue = false
        } else if !entryText.contains(".") {
            entryText += "."
        }
    }

    /// Sets `operation` as pending. If another operation was already pending and the user has
    /// typed a new value since, that earlier operation runs first (standard calculator chaining,
    /// e.g. `2 + 3 ×` computes `5` before queuing the multiply).
    mutating func setOperation(_ operation: Operation) {
        if let pendingOperation, !isEnteringFreshValue {
            performPendingOperation(pendingOperation)
        } else {
            accumulatedValue = currentValue
        }
        self.pendingOperation = operation
        isEnteringFreshValue = true
    }

    mutating func equals() {
        guard let pendingOperation else { return }
        performPendingOperation(pendingOperation)
        self.pendingOperation = nil
        isEnteringFreshValue = true
    }

    mutating func clear() {
        entryText = "0"
        accumulatedValue = 0
        pendingOperation = nil
        isEnteringFreshValue = true
        errorMessage = nil
    }

    private mutating func performPendingOperation(_ operation: Operation) {
        let rhs = currentValue
        let result: Decimal
        switch operation {
        case .add: result = accumulatedValue + rhs
        case .subtract: result = accumulatedValue - rhs
        case .multiply: result = accumulatedValue * rhs
        case .divide:
            guard rhs != 0 else {
                errorMessage = "Cannot divide by zero"
                entryText = "0"
                accumulatedValue = 0
                return
            }
            result = accumulatedValue / rhs
        }
        accumulatedValue = result
        entryText = Self.format(result)
    }

    private static func format(_ value: Decimal) -> String {
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 8, .plain)
        var text = NSDecimalNumber(decimal: rounded).stringValue
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}
