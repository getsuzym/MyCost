import Foundation
import SwiftData

@Model
final class Category {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    var colorHex: String
    /// SF Symbol name, or "" for no icon.
    var symbolName: String
    var sortOrder: Int
    /// Hidden categories stay on existing transactions but are not offered in
    /// pickers. The fallback category can never be hidden. Defaulted so the
    /// property is a lightweight migration on existing stores.
    var isActive: Bool = true
    /// The single protected "Uncategorized" category: cannot be deleted and is
    /// where references go when a category is removed without a chosen target.
    var isFallback: Bool = false
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction] = []

    @Relationship(deleteRule: .nullify, inverse: \MerchantRule.category)
    var merchantRules: [MerchantRule] = []

    @Relationship(deleteRule: .nullify, inverse: \RecurringPayment.category)
    var recurringPayments: [RecurringPayment] = []

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        symbolName: String,
        sortOrder: Int = 0,
        isActive: Bool = true,
        isFallback: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.isActive = isActive
        self.isFallback = isFallback
        self.createdAt = createdAt
    }
}

extension Category {
    static let fallbackName = "Uncategorized"

    static var defaults: [Category] {
        [
            Category(name: "Groceries", colorHex: "#2A9D8F", symbolName: "cart", sortOrder: 0),
            Category(name: "Dining", colorHex: "#E76F51", symbolName: "fork.knife", sortOrder: 1),
            Category(name: "Transport", colorHex: "#457B9D", symbolName: "car", sortOrder: 2),
            Category(name: "Shopping", colorHex: "#B56576", symbolName: "bag", sortOrder: 3),
            Category(name: "Bills", colorHex: "#6D597A", symbolName: "doc.text", sortOrder: 4),
            Category(name: "Subscriptions", colorHex: "#3A86FF", symbolName: "repeat", sortOrder: 5),
            Category(name: "Health", colorHex: "#4D908E", symbolName: "cross.case", sortOrder: 6),
            Category(name: fallbackName, colorHex: "#6C757D", symbolName: "tag", sortOrder: 7, isFallback: true)
        ]
    }
}
