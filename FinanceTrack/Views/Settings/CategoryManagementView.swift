import SwiftUI
import SwiftData

/// Full category management screen, opened from Settings. Lists active categories, and supports
/// adding, editing (name/icon/color), archiving, and — only for user-created categories with no
/// transactions attached — permanently deleting.
struct CategoryManagementView: View {
    @Query(sort: \Category.name) private var allCategories: [Category]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isPresentingAdd = false
    @State private var categoryPendingEdit: Category?
    @State private var categoryPendingArchive: Category?
    @State private var categoryPendingDelete: Category?
    @State private var isShowingArchivedCategories = false

    private var activeCategories: [Category] {
        allCategories.filter { !$0.isArchived }
    }

    private var archivedCategories: [Category] {
        allCategories.filter { $0.isArchived }
    }

    /// A category can only be permanently removed if it's user-created (defaults are protected
    /// from accidental deletion entirely) and nothing has ever used it — otherwise archiving is
    /// the only safe way to retire it, since existing transactions must keep displaying it.
    private func isSafeToDelete(_ category: Category) -> Bool {
        !category.isDefault && (category.transactions?.isEmpty ?? true)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header

                    if activeCategories.isEmpty {
                        EmptyStateCard(
                            systemIconName: "square.grid.2x2.fill",
                            message: "No categories yet. Add one to start organizing your expenses.",
                            actionTitle: "Add Category"
                        ) {
                            isPresentingAdd = true
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    } else {
                        categoriesSection
                    }

                    if !archivedCategories.isEmpty {
                        archivedSection
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $isPresentingAdd) {
                AddEditCategoryView()
            }
            .sheet(item: $categoryPendingEdit) { category in
                AddEditCategoryView(category: category)
            }
            .confirmationDialog(
                archiveConfirmationTitle,
                isPresented: Binding(
                    get: { categoryPendingArchive != nil },
                    set: { isPresented in if !isPresented { categoryPendingArchive = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Archive", role: .destructive) {
                    categoryPendingArchive?.isArchived = true
                    categoryPendingArchive = nil
                }
                Button("Cancel", role: .cancel) { categoryPendingArchive = nil }
            } message: {
                Text(archiveConfirmationMessage)
            }
            .confirmationDialog(
                "Delete \(categoryPendingDelete?.name ?? "Category") permanently?",
                isPresented: Binding(
                    get: { categoryPendingDelete != nil },
                    set: { isPresented in if !isPresented { categoryPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let category = categoryPendingDelete {
                        modelContext.delete(category)
                    }
                    categoryPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { categoryPendingDelete = nil }
            } message: {
                Text("This category has never been used by a transaction, so it can be removed completely. This cannot be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var archiveConfirmationTitle: String {
        "Archive \(categoryPendingArchive?.name ?? "Category")?"
    }

    private var archiveConfirmationMessage: String {
        guard let category = categoryPendingArchive else { return "" }
        var message = "This category will no longer appear when adding new expenses."
        if category.isDefault {
            message += " It's one of SpendSmart's default categories."
        }
        if !(category.transactions?.isEmpty ?? true) {
            message += " Existing transactions will keep showing it."
        }
        return message
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Categories")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Manage the categories you use for expenses")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Categories list

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Active Categories", actionTitle: "Add") {
                isPresentingAdd = true
            }

            CardBackground {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(activeCategories.enumerated()), id: \.element.id) { index, category in
                        CategoryManagementRow(
                            category: category,
                            isSafeToDelete: isSafeToDelete(category),
                            onEdit: { categoryPendingEdit = category },
                            onArchive: { categoryPendingArchive = category },
                            onDelete: { categoryPendingDelete = category }
                        )
                        if index < activeCategories.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Archived categories

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button {
                isShowingArchivedCategories.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(isShowingArchivedCategories ? "Hide Archived Categories" : "Show Archived Categories")
                        .font(Theme.captionFont)
                    Text("(\(archivedCategories.count))")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: isShowingArchivedCategories ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.lg)

            if isShowingArchivedCategories {
                CardBackground {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(archivedCategories.enumerated()), id: \.element.id) { index, category in
                            ArchivedCategoryRow(category: category) {
                                category.isArchived = false
                            }
                            if index < archivedCategories.count - 1 {
                                Divider().overlay(Theme.cardStroke)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }
}

private struct ArchivedCategoryRow: View {
    let category: Category
    var onRestore: () -> Void

    private var tint: Color { Theme.categoryColor(named: category.colorName) }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: category.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint.opacity(0.6))
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.1)))

            Text(category.name)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Button(action: onRestore) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Restore")
                        .font(Theme.captionFont)
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct CategoryManagementRow: View {
    let category: Category
    let isSafeToDelete: Bool
    var onEdit: () -> Void
    var onArchive: () -> Void
    var onDelete: () -> Void

    private var tint: Color { Theme.categoryColor(named: category.colorName) }

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: category.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.opacity(0.16)))

                HStack(spacing: 6) {
                    Text(category.name)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)
                    if category.isDefault {
                        Text("Default")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.textTertiary.opacity(0.15)))
                    }
                }

                Spacer()

                Menu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Button("Archive", systemImage: "archivebox", role: .destructive, action: onArchive)
                    if isSafeToDelete {
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CategoryManagementView()
        .modelContainer(SampleData.previewContainer)
}
