import SwiftUI
import UIKit

/// Shared labeled input for the auth screens — mirrors the `labeledField` pattern already used
/// elsewhere (e.g. `AddAccountView`), pulled into one place since every auth screen needs the
/// same email/password field styling and autofill wiring.
struct AuthTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(textContentType)
            .padding(Theme.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
            .foregroundStyle(Theme.textPrimary)
        }
    }
}
