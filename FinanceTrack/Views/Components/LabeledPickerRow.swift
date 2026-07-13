import SwiftUI

/// A labeled dropdown-style picker styled to match the app's other input fields (e.g. in
/// `AddAccountView`). Used where a segmented control doesn't fit — too many options (frequency,
/// timing) or an optional selection (category, payment account).
struct LabeledPickerRow<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Picker(title, selection: $selection) {
                content()
            }
            .pickerStyle(.menu)
            .tint(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.cardSurface)
            )
        }
    }
}
