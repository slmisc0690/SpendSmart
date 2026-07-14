import SwiftUI
import UIKit

/// Pure, UIKit-independent state machine for cents-first currency entry — deliberately has no
/// dependency on `UITextField`/SwiftUI so it can be unit tested directly. A digit typed at the
/// keyboard shifts existing digits left (cents-first: typing "1234" produces $12.34, never
/// requiring a decimal key); a complete formatted amount handed to `applyPastedText` (paste,
/// autofill, external multi-character insert) is instead interpreted literally as that amount,
/// never as raw cents. `Decimal` is the only source of truth for the bound/saved value — no
/// `Double` is involved anywhere in this type.
struct CurrencyInputState: Equatable {
    private(set) var magnitudeCents: UInt64 = 0
    private(set) var isNegative: Bool = false
    /// True once the field has ANY digits, including a typed "0" — false only when genuinely
    /// empty (never touched, or backspaced/cleared down to nothing). This is what makes `amount`
    /// `nil` while empty rather than fabricating a `Decimal(0)`.
    private(set) var hasContent: Bool = false

    var allowsNegative: Bool
    var allowsZero: Bool
    var minimum: Decimal?
    var maximum: Decimal?

    /// Hard ceiling independent of `maximum` — purely to keep `magnitudeCents` representable and
    /// prevent runaway digit entry from ever overflowing, not a product constraint.
    private static let hardCeilingCents: UInt64 = 999_999_999_999 // $9,999,999,999.99

    init(allowsNegative: Bool = false, allowsZero: Bool = true, minimum: Decimal? = nil, maximum: Decimal? = nil) {
        self.allowsNegative = allowsNegative
        self.allowsZero = allowsZero
        self.minimum = minimum
        self.maximum = maximum
    }

    /// The bound value — `nil` exactly when the field is empty.
    var amount: Decimal? {
        guard hasContent else { return nil }
        let magnitude = Decimal(magnitudeCents) / 100
        return isNegative ? -magnitude : magnitude
    }

    /// Loads an existing value for editing (e.g. a sheet opening in edit mode) — splits it into
    /// magnitude/sign so a digit typed immediately afterward continues cents-first FROM this
    /// value: loading $123.45 then typing "6" produces $1,234.56, never erasing what was loaded.
    mutating func load(_ value: Decimal?) {
        guard let value else {
            magnitudeCents = 0
            isNegative = false
            hasContent = false
            return
        }
        isNegative = value < 0
        magnitudeCents = min((abs(value) * 100).roundedToPlainCents(), Self.hardCeilingCents)
        hasContent = true
    }

    /// A single digit typed at the keyboard. Silently ignored once already at the configured
    /// ceiling (own hard cap, or `maximum` if set) rather than overflowing or wrapping.
    mutating func enterDigit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        let candidate = magnitudeCents &* 10 &+ UInt64(digit)
        guard candidate >= magnitudeCents, candidate <= effectiveCeilingCents else { return }
        magnitudeCents = candidate
        hasContent = true
    }

    /// Removes the last entered digit, shifting the rest down one decimal place.
    mutating func backspace() {
        guard hasContent else { return }
        magnitudeCents /= 10
        if magnitudeCents == 0 {
            hasContent = false
            isNegative = false
        }
    }

    /// Full reset — the keyboard toolbar's Clear action.
    mutating func clear() {
        magnitudeCents = 0
        isNegative = false
        hasContent = false
    }

    /// Interprets `text` as a COMPLETE, already-formatted amount — paste, autofill, external
    /// multi-character insert, or a select-all replace — never as cents-first digits. Returns
    /// `false` (leaving the field entirely unchanged) if `text` doesn't parse as a valid amount,
    /// or if it's negative and this field doesn't allow negatives.
    @discardableResult
    mutating func applyPastedText(_ text: String, locale: Locale = .current) -> Bool {
        guard let parsed = Self.parseFormattedAmount(text, locale: locale) else { return false }
        if parsed.isNegative && !allowsNegative { return false }
        magnitudeCents = min(parsed.cents, effectiveCeilingCents)
        isNegative = parsed.isNegative
        hasContent = true
        return true
    }

    private var effectiveCeilingCents: UInt64 {
        guard let maximum, maximum >= 0 else { return Self.hardCeilingCents }
        return min((maximum * 100).roundedToPlainCents(), Self.hardCeilingCents)
    }

    /// Parses a pasted/autofilled string like `"123.45"`, `"$123.45"`, `"1,234.56"`, `"1234"`
    /// (→ $1,234.00, never $12.34), tolerating surrounding whitespace and the given locale's own
    /// decimal/grouping separators. Returns `nil` for anything unparseable — never guesses.
    static func parseFormattedAmount(_ text: String, locale: Locale = .current) -> (cents: UInt64, isNegative: Bool)? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var isNegative = false
        if trimmed.hasPrefix("-") {
            isNegative = true
            trimmed.removeFirst()
        } else if trimmed.hasPrefix("("), trimmed.hasSuffix(")"), trimmed.count > 2 {
            // Accounting-style negative, e.g. "(123.45)" — accepted defensively even though no
            // current screen produces this format, since it's an unambiguous representation.
            isNegative = true
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        let currencySymbols = Set([locale.currencySymbol, "$", "€", "£", "¥"].compactMap { $0 }.filter { !$0.isEmpty })
        for symbol in currencySymbols {
            trimmed = trimmed.replacingOccurrences(of: symbol, with: "")
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let groupingSeparator = locale.groupingSeparator ?? ","
        let decimalSeparator = locale.decimalSeparator ?? "."
        if !groupingSeparator.isEmpty, groupingSeparator != decimalSeparator {
            trimmed = trimmed.replacingOccurrences(of: groupingSeparator, with: "")
        }
        if decimalSeparator != "." {
            trimmed = trimmed.replacingOccurrences(of: decimalSeparator, with: ".")
        }

        guard trimmed.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        guard trimmed.filter({ $0 == "." }).count <= 1 else { return nil }
        guard trimmed != "." else { return nil }

        guard let decimalValue = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return ((decimalValue * 100).roundedToPlainCents(), isNegative)
    }

    /// Rendered display text — always exactly two decimal places, thousands-grouped, locale
    /// currency formatting. Empty when the field has no content; the placeholder handles that
    /// visually rather than this fabricating a "$0.00".
    func displayText(locale: Locale = .current) -> String {
        guard hasContent else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let magnitude = Decimal(magnitudeCents) / 100
        let signedValue = isNegative ? -magnitude : magnitude
        return formatter.string(from: NSDecimalNumber(decimal: signedValue)) ?? ""
    }

    /// Whether the current value satisfies this field's OWN configured constraints
    /// (`allowsZero`/`allowsNegative`/`minimum`/`maximum`). Deliberately excludes "is this field
    /// required" — that stays each screen's own concern, exactly as today (some screens treat an
    /// empty/nil amount as invalid, others as a valid "no value set" state).
    var satisfiesOwnConstraints: Bool {
        guard let amount else { return true }
        if amount < 0 && !allowsNegative { return false }
        if amount == 0 && !allowsZero { return false }
        if let minimum, amount < minimum { return false }
        if let maximum, amount > maximum { return false }
        return true
    }
}

private extension Decimal {
    /// Rounds to the nearest integer using plain (round-half-up) rounding, then converts to an
    /// unsigned cents count — used to turn a dollars-and-cents `Decimal` into integer cents
    /// without banker's-rounding surprises. Clamped defensively against negative/overflow inputs;
    /// callers are expected to pass a non-negative magnitude already.
    func roundedToPlainCents() -> UInt64 {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        if rounded <= 0 { return 0 }
        if rounded > Decimal(UInt64.max) { return UInt64.max }
        return NSDecimalNumber(decimal: rounded).uint64Value
    }
}

// MARK: - UIKit text field

/// `UITextField` subclass that reports paste operations EXPLICITLY, rather than only inferring
/// them from replacement-text length — the robust mechanism this component needs instead of a
/// timing/length heuristic. `paste(_:)`/`pasteAndMatchStyle(_:)` are the two entry points UIKit
/// always routes an actual clipboard paste through (menu, Cmd+V on an external keyboard, or the
/// system edit-menu callout); setting `isPasteInFlight` immediately before calling `super` and
/// clearing it immediately after is safe with no race, because `super.paste(_:)` synchronously
/// triggers this field's `shouldChangeCharactersIn` delegate callback within that same call.
final class CurrencyUITextField: UITextField {
    fileprivate var isPasteInFlight = false

    override func paste(_ sender: Any?) {
        isPasteInFlight = true
        super.paste(sender)
        isPasteInFlight = false
    }

    override func pasteAndMatchStyle(_ sender: Any?) {
        isPasteInFlight = true
        super.pasteAndMatchStyle(sender)
        isPasteInFlight = false
    }
}

/// Bridges `CurrencyUITextField` into SwiftUI. Keeps ALL cents-first/paste/backspace decisions in
/// `CurrencyInputState`; this type's only job is wiring UIKit's delegate callbacks to that state
/// machine and keeping the field's displayed text and the SwiftUI `Decimal?` binding in sync
/// without fighting the user mid-edit (the classic `UIViewRepresentable` cursor-jump/update-loop
/// trap this was built specifically to avoid).
struct CurrencyTextFieldRepresentable: UIViewRepresentable {
    @Binding var amount: Decimal?
    var allowsNegative: Bool
    var allowsZero: Bool
    var minimum: Decimal?
    var maximum: Decimal?
    var isDisabled: Bool
    var placeholder: String
    var accessibilityLabel: String?
    var font: UIFont
    var textAlignment: NSTextAlignment
    var textColor: UIColor
    var placeholderColor: UIColor
    var autoFocusOnAppear: Bool

    func makeUIView(context: Context) -> CurrencyUITextField {
        let field = CurrencyUITextField()
        field.delegate = context.coordinator
        field.font = font
        field.textAlignment = textAlignment
        field.textColor = textColor
        field.tintColor = textColor
        field.keyboardType = .numberPad
        field.adjustsFontForContentSizeCategory = true
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor]
        )
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged), for: .editingChanged)
        context.coordinator.textField = field
        return field
    }

    func updateUIView(_ uiView: CurrencyUITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.amountBinding = $amount
        coordinator.state.allowsNegative = allowsNegative
        coordinator.state.allowsZero = allowsZero
        coordinator.state.minimum = minimum
        coordinator.state.maximum = maximum

        uiView.isEnabled = !isDisabled
        uiView.accessibilityLabel = accessibilityLabel
        if uiView.attributedPlaceholder?.string != placeholder {
            uiView.attributedPlaceholder = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: placeholderColor]
            )
        }

        // Only pull an externally-changed `amount` into the field when it genuinely differs from
        // what the state machine already holds AND the user isn't actively editing — otherwise
        // every SwiftUI re-render while typing would clobber in-progress input and fight the
        // cursor. This is the one place external state (e.g. a caller resetting the binding to
        // nil, or loading a different record) is allowed to override current text.
        if !uiView.isFirstResponder, coordinator.state.amount != amount {
            coordinator.state.load(amount)
            coordinator.syncDisplay(animated: false)
        }

        if autoFocusOnAppear, !coordinator.hasAutoFocused {
            coordinator.hasAutoFocused = true
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: CurrencyInputState(
                allowsNegative: allowsNegative,
                allowsZero: allowsZero,
                minimum: minimum,
                maximum: maximum
            ),
            initialAmount: amount
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var state: CurrencyInputState
        var amountBinding: Binding<Decimal?>?
        weak var textField: CurrencyUITextField?
        var hasAutoFocused = false

        init(state: CurrencyInputState, initialAmount: Decimal?) {
            var seeded = state
            seeded.load(initialAmount)
            self.state = seeded
        }

        /// No-op target for `.editingChanged` — all real work happens in
        /// `shouldChangeCharactersIn`, which fires BEFORE the field's text actually changes. This
        /// target exists only so `.editingChanged` is observed for VoiceOver/UIKit bookkeeping;
        /// it deliberately reads no state.
        @objc func editingChanged() {}

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            guard let currencyField = textField as? CurrencyUITextField else { return true }

            if string.isEmpty {
                if range.length > 0 {
                    state.backspace()
                    syncDisplay(animated: false)
                }
                return false
            }

            let currentLength = textField.text?.utf16.count ?? 0
            let isFullReplacement = range.length >= currentLength && currentLength > 0
            let isPaste = currencyField.isPasteInFlight || string.count > 1 || isFullReplacement

            if isPaste {
                state.applyPastedText(string)
            } else if string.count == 1, let digit = Int(string) {
                state.enterDigit(digit)
            } else {
                // A non-digit, non-paste keystroke (e.g. "." or "-" from an external keyboard,
                // which the on-screen number pad never offers) — cents-first entry never accepts
                // a literal decimal point or sign as a standalone keystroke.
                return false
            }

            syncDisplay(animated: false)
            return false
        }

        func syncDisplay(animated: Bool) {
            guard let textField else { return }
            let newText = state.displayText()
            if textField.text != newText {
                textField.text = newText
            }
            moveCursorToEnd(textField)
            amountBinding?.wrappedValue = state.amount
        }

        private func moveCursorToEnd(_ textField: UITextField) {
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: end, to: end)
        }
    }
}

// MARK: - Public SwiftUI component

/// Reusable currency-entry field used everywhere in SpendSmart a dollar amount is typed. Normal
/// number-pad digit entry is cents-first (typing "1234" produces $12.34 — the decimal key is
/// never needed); pasting, autofilling, or otherwise inserting a complete formatted amount (e.g.
/// "$1,234.56") is instead interpreted as that literal amount. `amount` is `nil` exactly when the
/// field is empty. See `CurrencyInputState` for the independently-unit-tested underlying logic.
struct CurrencyAmountField: View {
    enum Style { case hero, inline }

    @Binding var amount: Decimal?
    var style: Style = .hero
    var allowsNegative: Bool = false
    var allowsZero: Bool = true
    var minimum: Decimal? = nil
    var maximum: Decimal? = nil
    var isDisabled: Bool = false
    var label: String? = nil
    var placeholder: String = "$0.00"
    var isInvalid: Bool = false
    var accessibilityLabel: String? = nil

    var body: some View {
        switch style {
        case .hero: heroBody
        case .inline: inlineBody
        }
    }

    private var heroBody: some View {
        VStack(spacing: Theme.Spacing.xs) {
            CurrencyTextFieldRepresentable(
                amount: $amount,
                allowsNegative: allowsNegative,
                allowsZero: allowsZero,
                minimum: minimum,
                maximum: maximum,
                isDisabled: isDisabled,
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel ?? label,
                font: Self.heroUIFont,
                textAlignment: .center,
                textColor: UIColor(Theme.textPrimary),
                placeholderColor: UIColor(Theme.textSecondary),
                autoFocusOnAppear: true
            )
            .frame(height: 48)

            Rectangle()
                .fill(isInvalid ? Theme.statusOver : Theme.cardStroke)
                .frame(width: 140, height: 2)
                .animation(.easeInOut(duration: 0.15), value: isInvalid)
        }
    }

    private var inlineBody: some View {
        HStack {
            if let label {
                Text(label)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            CurrencyTextFieldRepresentable(
                amount: $amount,
                allowsNegative: allowsNegative,
                allowsZero: allowsZero,
                minimum: minimum,
                maximum: maximum,
                isDisabled: isDisabled,
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel ?? label,
                font: UIFont.preferredFont(forTextStyle: .body),
                textAlignment: label == nil ? .left : .right,
                textColor: UIColor(Theme.textSecondary),
                placeholderColor: UIColor(Theme.textTertiary),
                autoFocusOnAppear: false
            )
            .frame(maxWidth: label == nil ? .infinity : nil)
            .fixedSize(horizontal: label != nil, vertical: true)
        }
    }

    private static var heroUIFont: UIFont {
        let base = UIFont.systemFont(ofSize: 36, weight: .bold)
        guard let roundedDescriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: roundedDescriptor, size: 36)
    }
}

#Preview("Hero") {
    VStack(spacing: 24) {
        CurrencyAmountField(amount: .constant(42.18), style: .hero, label: "Amount")
        CurrencyAmountField(amount: .constant(nil), style: .hero, placeholder: "0.00", isInvalid: true)
    }
    .padding()
    .background(Theme.backgroundGradient)
}

#Preview("Inline") {
    VStack(spacing: 12) {
        CurrencyAmountField(amount: .constant(350), style: .inline, label: "Weekly Spending Limit")
        CurrencyAmountField(amount: .constant(nil), style: .inline, label: "Monthly Goal (optional)")
    }
    .padding()
    .background(Theme.backgroundGradient)
}
