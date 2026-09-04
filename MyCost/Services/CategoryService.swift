import Foundation
import SwiftData

enum CategoryError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case cannotDeleteFallback
    case cannotHideFallback
    case cannotReassignToSelf

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a category name."
        case .duplicateName(let name):
            "A category named \u{201C}\(name)\u{201D} already exists."
        case .cannotDeleteFallback:
            "The Uncategorized category can't be deleted."
        case .cannotHideFallback:
            "The Uncategorized category can't be hidden."
        case .cannotReassignToSelf:
            "Choose a different category to move items to."
        }
    }
}

extension Sequence where Element == Category {
    /// Localized, case-insensitive alphabetical order by `name`. Use this in the
    /// places where the user is *selecting or managing* categories (Review
    /// category picker, Category Management list, editor pickers) — never on the
    /// Dashboard, which keeps its spending-ranked order.
    func alphabetizedByName() -> [Category] {
        sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// How many things point at a category — shown before a destructive delete so
/// references are never dropped silently.
struct CategoryReferenceCounts: Equatable {
    var transactions: Int
    var merchantRules: Int
    var recurringPayments: Int

    var total: Int { transactions + merchantRules + recurringPayments }
    var isInUse: Bool { total > 0 }
}

/// All category mutations go through here so name-uniqueness, the protected
/// fallback, and reference reassignment are enforced in one place.
struct CategoryService {
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func isNameAvailable(_ name: String, in categories: [Category], excluding: Category? = nil) -> Bool {
        let key = Self.normalizedName(name)
        guard !key.isEmpty else { return false }
        return !categories.contains { $0.id != excluding?.id && Self.normalizedName($0.name) == key }
    }

    func fallbackCategory(in categories: [Category]) -> Category? {
        categories.first(where: \.isFallback)
            ?? categories.first { Self.normalizedName($0.name) == Self.normalizedName(Category.fallbackName) }
    }

    func referenceCounts(
        for category: Category,
        transactions: [Transaction],
        merchantRules: [MerchantRule],
        recurringPayments: [RecurringPayment]
    ) -> CategoryReferenceCounts {
        CategoryReferenceCounts(
            transactions: transactions.filter { $0.category?.id == category.id }.count,
            merchantRules: merchantRules.filter { $0.category?.id == category.id }.count,
            recurringPayments: recurringPayments.filter { $0.category?.id == category.id }.count
        )
    }

    // MARK: Mutations

    @MainActor
    @discardableResult
    func createCategory(
        name: String,
        symbolName: String,
        colorHex: String,
        in categories: [Category],
        modelContext: ModelContext
    ) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CategoryError.emptyName }
        guard isNameAvailable(trimmed, in: categories) else { throw CategoryError.duplicateName(trimmed) }

        let category = Category(
            name: trimmed,
            colorHex: colorHex,
            symbolName: symbolName.trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: (categories.map(\.sortOrder).max() ?? -1) + 1
        )
        modelContext.insert(category)
        try modelContext.save()
        return category
    }

    @MainActor
    func updateCategory(
        _ category: Category,
        name: String,
        symbolName: String,
        colorHex: String,
        in categories: [Category],
        budgets: [Budget] = [],
        modelContext: ModelContext
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CategoryError.emptyName }
        guard isNameAvailable(trimmed, in: categories, excluding: category) else {
            throw CategoryError.duplicateName(trimmed)
        }
        let oldName = category.name
        category.name = trimmed
        category.symbolName = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        category.colorHex = colorHex
        // `Transaction.category` follows automatically (relationship); `Budget`
        // matches by name, so it needs the rename applied explicitly.
        if oldName != trimmed {
            BudgetService().renameCategory(from: oldName, to: trimmed, in: budgets)
        }
        try modelContext.save()
    }

    @MainActor
    func reorder(_ orderedCategories: [Category], modelContext: ModelContext) {
        for (index, category) in orderedCategories.enumerated() {
            category.sortOrder = index
        }
        modelContext.saveOrLog("reorder categories")
    }

    @MainActor
    func setActive(_ category: Category, _ isActive: Bool, modelContext: ModelContext) throws {
        if category.isFallback, !isActive { throw CategoryError.cannotHideFallback }
        category.isActive = isActive
        try modelContext.save()
    }

    /// Deletes `category`, first moving every transaction / merchant rule /
    /// recurring payment that referenced it to `target` (a chosen category) or,
    /// when `target` is nil, clearing the reference (→ Uncategorized).
    @MainActor
    func deleteCategory(
        _ category: Category,
        reassigningTo target: Category?,
        transactions: [Transaction],
        merchantRules: [MerchantRule],
        recurringPayments: [RecurringPayment],
        modelContext: ModelContext
    ) throws {
        guard !category.isFallback else { throw CategoryError.cannotDeleteFallback }
        if let target, target.id == category.id { throw CategoryError.cannotReassignToSelf }

        for transaction in transactions where transaction.category?.id == category.id {
            transaction.category = target
            transaction.updatedAt = .now
        }
        for rule in merchantRules where rule.category?.id == category.id {
            rule.category = target
            rule.updatedAt = .now
        }
        for payment in recurringPayments where payment.category?.id == category.id {
            payment.category = target
            payment.updatedAt = .now
        }

        modelContext.delete(category)
        try modelContext.save()
    }

    /// Guarantees a protected fallback category exists, even if the user has
    /// deleted or renamed everything. Safe to call on every launch.
    @MainActor
    @discardableResult
    func ensureFallbackCategory(in categories: [Category], modelContext: ModelContext) -> Category {
        if let existing = fallbackCategory(in: categories) {
            var changed = false
            if !existing.isFallback { existing.isFallback = true; changed = true }
            if !existing.isActive { existing.isActive = true; changed = true }
            if changed { modelContext.saveOrLog("repair fallback category") }
            return existing
        }

        let fallback = Category(
            name: Category.fallbackName,
            colorHex: "#6C757D",
            symbolName: "tag",
            sortOrder: (categories.map(\.sortOrder).max() ?? -1) + 1,
            isFallback: true
        )
        modelContext.insert(fallback)
        modelContext.saveOrLog("create fallback category")
        return fallback
    }
}
