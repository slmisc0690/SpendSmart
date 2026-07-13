import Foundation
import SwiftData

/// A spending category used to group and visualize transactions (e.g. Groceries, Dining, Transit).
/// `colorName` is a semantic key (e.g. "blue", "orange") resolved by `Theme.categoryColor(named:)`,
/// rather than a raw hex value, so category color stays consistent with the app's palette.
@Model
final class Category {
    var id: UUID
    var name: String
    /// SF Symbol name for the category icon.
    var iconName: String
    var colorName: String
    var isDefault: Bool
    var isArchived: Bool
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \FinanceTransaction.category)
    var transactions: [FinanceTransaction]? = []

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "circle.fill",
        colorName: String = "blue",
        isDefault: Bool = false,
        isArchived: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorName = colorName
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    /// The standard category set every user starts with. Seeded once on first launch by
    /// `RootView` — never inserted more than once, and never includes any transactions.
    static func makeDefaultSet() -> [Category] {
        [
            Category(name: "Food", iconName: "fork.knife", colorName: "orange", isDefault: true),
            Category(name: "Groceries", iconName: "cart.fill", colorName: "green", isDefault: true),
            Category(name: "Gas", iconName: "fuelpump.fill", colorName: "yellow", isDefault: true),
            Category(name: "Bills", iconName: "doc.text.fill", colorName: "red", isDefault: true),
            Category(name: "Shopping", iconName: "bag.fill", colorName: "purple", isDefault: true),
            Category(name: "Entertainment", iconName: "play.tv.fill", colorName: "pink", isDefault: true),
            Category(name: "Health", iconName: "heart.fill", colorName: "teal", isDefault: true),
            Category(name: "Subscriptions", iconName: "arrow.triangle.2.circlepath", colorName: "indigo", isDefault: true),
            Category(name: "Travel", iconName: "airplane", colorName: "mint", isDefault: true),
            Category(name: "Home", iconName: "house.fill", colorName: "indigo", isDefault: true),
            Category(name: "Security", iconName: "lock.shield.fill", colorName: "gray", isDefault: true),
            Category(name: "Car", iconName: "car.fill", colorName: "blue", isDefault: true),
            Category(name: "Loans", iconName: "building.columns.fill", colorName: "purple", isDefault: true),
            Category(name: "Furniture", iconName: "sofa.fill", colorName: "orange", isDefault: true),
            Category(name: "Clothing", iconName: "tshirt.fill", colorName: "pink", isDefault: true),
            Category(name: "Internet/TV", iconName: "wifi", colorName: "teal", isDefault: true),
            Category(name: "Cellular", iconName: "antenna.radiowaves.left.and.right", colorName: "mint", isDefault: true),
            Category(name: "Electric", iconName: "bolt.fill", colorName: "yellow", isDefault: true),
            Category(name: "Water/Sewage", iconName: "drop.fill", colorName: "blue", isDefault: true),
            Category(name: "Retail", iconName: "storefront.fill", colorName: "purple", isDefault: true),
            Category(name: "Credit Card", iconName: "creditcard.fill", colorName: "red", isDefault: true),
            Category(name: "Other", iconName: "ellipsis.circle.fill", colorName: "gray", isDefault: true),
        ]
    }

    /// The default categories from `makeDefaultSet()` that aren't already present in `existing`
    /// (matched case-insensitively and trimmed, so "food ", "Food", and "FOOD" all count as the
    /// same category). Used both for first-run seeding and for backfilling installs that predate
    /// a later addition to the default set — never touches, renames, or removes anything in
    /// `existing`, including categories the user created themselves.
    static func missingDefaultCategories(existing: [Category]) -> [Category] {
        let existingNames = Set(existing.map { normalizedName($0.name) })
        return makeDefaultSet().filter { !existingNames.contains(normalizedName($0.name)) }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
