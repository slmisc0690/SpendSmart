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
    /// Set `true` only by a screen that wants THIS specific field to receive keyboard focus the
    /// instant it appears (e.g. Create Account's Email field) — `false` everywhere else, which
    /// leaves focus behavior exactly as it was. Applied once via `.task` (which runs once per
    /// appearance), never re-forced after the user moves to another field, since focus is only
    /// ever set here — nothing re-applies it on subsequent state changes.
    var requestsInitialFocus: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
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
            .focused($isFocused)
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.cardSurfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.textTertiary.opacity(0.4), lineWidth: 1)
            )
            .foregroundStyle(Theme.textPrimary)
        }
        .task {
            if requestsInitialFocus {
                isFocused = true
            }
        }
    }
}
