import SwiftUI

/// A compact, collapsed drop-down for picking a transaction's reusable description — mirrors
/// `CategoryPickerCard`'s sizing exactly so the two can sit side by side. Never mutates
/// `descriptions`; selecting an item only ever updates the `selectedDescription` binding. Adding
/// a new description is handled by the parent (via `onRequestAddDescription`) rather than
/// presenting a sheet directly from inside the `Menu`, since SwiftUI `Menu` cannot reliably
/// trigger a sheet presentation from one of its own actions.
struct DescriptionPickerCard: View {
    let descriptions: [String]
    @Binding var selectedDescription: String?
    var onRequestAddDescription: () -> Void

    private var selectionLabel: String {
        selectedDescription?.isEmpty == false ? selectedDescription! : "Select"
    }

    var body: some View {
        CardBackground(padding: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Description")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)

                descriptionMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var descriptionMenu: some View {
        Menu {
            Button {
                selectedDescription = nil
            } label: {
                if selectedDescription == nil {
                    Label("None", systemImage: "checkmark")
                } else {
                    Text("None")
                }
            }
            if !descriptions.isEmpty {
                Divider()
                ForEach(descriptions, id: \.self) { description in
                    Button {
                        selectedDescription = description
                    } label: {
                        if selectedDescription == description {
                            Label(description, systemImage: "checkmark")
                        } else {
                            Text(description)
                        }
                    }
                }
            }
            Divider()
            Button {
                onRequestAddDescription()
            } label: {
                Label("Add Description", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectionLabel)
                    .font(Theme.bodyFont)
                    .foregroundStyle(selectedDescription?.isEmpty == false ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.cardSurface)
            )
        }
        .accessibilityLabel("Description")
        .accessibilityValue(selectionLabel)
    }
}

#Preview {
    DescriptionPickerCard(
        descriptions: DescriptionSorting.sortedAlphabetically(DescriptionStore.defaultDescriptions),
        selectedDescription: .constant("Amazon"),
        onRequestAddDescription: {}
    )
    .padding()
    .background(Theme.backgroundGradient)
}
