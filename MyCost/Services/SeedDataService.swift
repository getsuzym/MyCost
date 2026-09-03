import Foundation
import SwiftData

enum SeedDataService {
    /// One-time reset of `Transaction.spendingCountOverridden`, which an earlier
    /// build set on **every** edit (not just when the user toggled "Counts as
    /// spending"). Clearing it lets the recurring re-check in
    /// `Transaction.contributesToSpending` govern again; a genuine later toggle
    /// re-sets it.
    @MainActor
    static func resetStaleSpendingOverridesIfNeeded(modelContext: ModelContext) {
        let key = "mycost.migration.clearSpendingOverride.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        let transactions = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        var changed = false
        for transaction in transactions where transaction.spendingCountOverridden {
            transaction.spendingCountOverridden = false
            changed = true
        }
        if changed { modelContext.saveOrLog("migration clearSpendingOverride.v1") }
    }

    @MainActor
    static func seedDefaultCategoriesIfNeeded(modelContext: ModelContext) {
        let categories = (try? modelContext.fetch(FetchDescriptor<Category>())) ?? []

        if categories.isEmpty {
            Category.defaults.forEach(modelContext.insert)
            modelContext.saveOrLog("seed default categories")
            return
        }

        // The app must always have a safe fallback, even if the user deleted
        // every other category.
        CategoryService().ensureFallbackCategory(in: categories, modelContext: modelContext)
    }
}
