import SwiftUI

extension View {
    /// Tapping anywhere this modifier is attached resigns the first responder — used on a form's
    /// background/scroll content now that `CurrencyAmountField` has no keyboard accessory of its
    /// own. SwiftUI only delivers this gesture when nothing else (a button, toggle, picker) claims
    /// the tap first, so it never interferes with other controls.
    func dismissKeyboardOnBackgroundTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}
