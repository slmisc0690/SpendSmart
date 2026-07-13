import SwiftUI

/// Autosave lifecycle for a single add/edit form. `.idle` renders nothing, so screens stay quiet
/// until there's actually something worth telling the user.
enum AutosaveStatus: Equatable {
    case idle
    case saving
    case saved
    case invalidDraft
}

/// Small, subtle inline autosave feedback shown near an add/edit screen's primary action button.
struct AutosaveStatusView: View {
    let status: AutosaveStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .saving:
            label("Saving\u{2026}", color: Theme.textTertiary, showsSpinner: true)
        case .saved:
            label("Saved", color: Theme.statusGood, systemIconName: "checkmark.circle.fill")
        case .invalidDraft:
            label("Draft not saved yet \u{2014} complete required fields to save", color: Theme.statusWarning, systemIconName: "exclamationmark.circle.fill")
        }
    }

    @ViewBuilder
    private func label(_ text: String, color: Color, systemIconName: String? = nil, showsSpinner: Bool = false) -> some View {
        HStack(spacing: 4) {
            if showsSpinner {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else if let systemIconName {
                Image(systemName: systemIconName)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    VStack(spacing: 12) {
        AutosaveStatusView(status: .idle)
        AutosaveStatusView(status: .saving)
        AutosaveStatusView(status: .saved)
        AutosaveStatusView(status: .invalidDraft)
    }
    .padding()
    .background(Theme.backgroundGradient)
}
