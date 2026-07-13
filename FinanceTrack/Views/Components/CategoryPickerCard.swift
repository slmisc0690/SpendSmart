import SwiftUI

/// A card containing a grid of selectable category chips (icon + name + selected state).
struct CategoryPickerCard: View {
    let categories: [Category]
    @Binding var selectedCategory: Category?

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: Theme.Spacing.sm)]

    var body: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Category (Optional)")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                if categories.isEmpty {
                    Text("No categories available yet.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                        ForEach(categories) { category in
                            CategoryChip(
                                category: category,
                                isSelected: selectedCategory?.id == category.id
                            ) {
                                // Tapping an already-selected chip deselects it — the only way
                                // back to "no category" once one has been picked.
                                selectedCategory = (selectedCategory?.id == category.id) ? nil : category
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CategoryChip: View {
    let category: Category
    let isSelected: Bool
    var action: () -> Void

    private var color: Color { Theme.categoryColor(named: category.colorName) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: category.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : color)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(isSelected ? color : color.opacity(0.16)))

                Text(category.name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? color.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isSelected ? color : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CategoryPickerCard(categories: Category.makeDefaultSet(), selectedCategory: .constant(Category.makeDefaultSet()[1]))
        .padding()
        .background(Theme.backgroundGradient)
}
