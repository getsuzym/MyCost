import Foundation
import SwiftData

/// A recurring monthly spending limit. `categoryName == nil` is the overall
/// month budget; otherwise it's scoped to that category (matched by name, the
/// same key `SpendingAnalytics` groups on, so it follows renames via
/// `BudgetService`).
@Model
final class Budget {
    @Attribute(.unique) var id: UUID
    /// `nil` = the whole month; otherwise a category name (or "Uncategorized").
    var categoryName: String?
    var monthlyLimit: Decimal
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        categoryName: String? = nil,
        monthlyLimit: Decimal,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.categoryName = categoryName
        self.monthlyLimit = monthlyLimit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isOverall: Bool { categoryName == nil }
    var displayName: String { categoryName ?? "Overall" }
}
