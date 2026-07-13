import SwiftUI
import SwiftData

/// Add or edit a `Category`: name, SF Symbol icon, and color. Passing `category` switches this
/// into edit mode, mirroring `AddAccountView`'s add/edit pattern.
struct AddEditCategoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let editingCategory: Category?

    @State private var name: String
    @State private var iconName: String
    @State private var colorName: String
    @State private var hasAttemptedSave = false

    /// A small, curated set of SF Symbols relevant to spending categories — kept simple rather
    /// than exposing the entire SF Symbols catalog.
    private static let iconOptions = [
        "fork.knife", "cart.fill", "fuelpump.fill", "doc.text.fill", "bag.fill",
        "play.tv.fill", "heart.fill", "arrow.triangle.2.circlepath", "airplane",
        "house.fill", "lock.shield.fill", "car.fill", "building.columns.fill",
        "sofa.fill", "tshirt.fill", "wifi", "antenna.radiowaves.left.and.right",
        "bolt.fill", "drop.fill", "storefront.fill", "creditcard.fill",
        "gift.fill", "pawprint.fill", "graduationcap.fill", "cross.case.fill",
        "gamecontroller.fill", "wrench.and.screwdriver.fill", "ellipsis.circle.fill",
    ]

    /// Theme's known semantic color names — `Theme.categoryColor(named:)` maps each of these to
    /// an actual color, so any name outside this list would silently fall back to `accent`.
    private static let colorOptions = [
        "blue", "indigo", "purple", "green", "mint", "teal", "yellow", "orange", "red", "pink", "gray",
    ]

    init(category: Category? = nil) {
        self.editingCategory = category
        _name = State(initialValue: category?.name ?? "")
        _iconName = State(initialValue: category?.iconName ?? Self.iconOptions[0])
        _colorName = State(initialValue: category?.colorName ?? Self.colorOptions[0])
    }

    private var isEditing: Bool { editingCategory != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { !trimmedName.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    nameSection
                    iconSection
                    colorSection

                    if hasAttemptedSave, !isValid {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Category name is required.")
                                .font(Theme.captionFont)
                        }
                        .foregroundStyle(Theme.statusOver)
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.statusOver.opacity(0.12)))
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Category" : "Add Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PremiumActionButton(title: isEditing ? "Save Changes" : "Add Category", systemIconName: "checkmark") {
                    save()
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xs)
                .background(.ultraThinMaterial)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var nameSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                TextField("e.g. Kids Activities", text: $name)
                    .textFieldStyle(.plain)
                    .padding(Theme.Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cardSurface))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var iconSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Icon")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: Theme.Spacing.sm)], spacing: Theme.Spacing.sm) {
                    ForEach(Self.iconOptions, id: \.self) { option in
                        Button {
                            iconName = option
                        } label: {
                            Image(systemName: option)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(iconName == option ? .white : Theme.categoryColor(named: colorName))
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(iconName == option ? Theme.categoryColor(named: colorName) : Theme.categoryColor(named: colorName).opacity(0.16)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var colorSection: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Color")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: Theme.Spacing.sm)], spacing: Theme.Spacing.sm) {
                    ForEach(Self.colorOptions, id: \.self) { option in
                        Button {
                            colorName = option
                        } label: {
                            Circle()
                                .fill(Theme.categoryColor(named: option))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Circle().strokeBorder(Theme.textPrimary, lineWidth: colorName == option ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func save() {
        hasAttemptedSave = true
        guard isValid else { return }

        if let editingCategory {
            editingCategory.name = trimmedName
            editingCategory.iconName = iconName
            editingCategory.colorName = colorName
        } else {
            let category = Category(name: trimmedName, iconName: iconName, colorName: colorName, isDefault: false)
            modelContext.insert(category)
        }

        dismiss()
    }
}

#Preview("Add") {
    AddEditCategoryView()
}

#Preview("Edit") {
    AddEditCategoryView(category: Category(name: "Groceries", iconName: "cart.fill", colorName: "green", isDefault: true))
}
