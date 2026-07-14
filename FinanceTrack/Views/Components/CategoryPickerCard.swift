import SwiftUI

/// A compact, collapsed drop-down for picking a transaction's category — shows the current
/// selection (or "Uncategorized") and reveals every eligible category, alphabetically sorted,
/// when tapped. Never mutates `categories`, never renames or re-relates anything; selecting an
/// item only ever updates the `selectedCategory` binding.
struct CategoryPickerCard: View {
    let categories: [Category]
    @Binding var selectedCategory: Category?

    private var sortedCategories: [Category] {
        CategorySorting.sortedAlphabetically(categories)
    }

    private var selectionLabel: String {
        selectedCategory?.name ?? "Uncategorized"
    }

    var body: some View {
        CardBackground(padding: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Category")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)

                if categories.isEmpty {
                    Text("None available")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    categoryMenu
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button {
                selectedCategory = nil
            } label: {
                if selectedCategory == nil {
                    Label("Uncategorized", systemImage: "checkmark")
                } else {
                    Text("Uncategorized")
                }
            }
            Divider()
            ForEach(sortedCategories) { category in
                Button {
                    selectedCategory = category
                } label: {
                    if selectedCategory?.id == category.id {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedCategory?.iconName ?? "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selectedCategory.map { Theme.categoryColor(named: $0.colorName) } ?? Theme.textTertiary)
                    .frame(width: 20, height: 20)

                Text(selectionLabel)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
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
        .accessibilityLabel("Category")
        .accessibilityValue(selectionLabel)
    }
}

#Preview {
    CategoryPickerCard(categories: Category.makeDefaultSet(), selectedCategory: .constant(Category.makeDefaultSet()[1]))
        .padding()
        .background(Theme.backgroundGradient)
}
