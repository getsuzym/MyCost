import Foundation
import SwiftData

enum SeedDataService {
    @MainActor
    static func seedDefaultCategoriesIfNeeded(modelContext: ModelContext) {
        let categories = (try? modelContext.fetch(FetchDescriptor<Category>())) ?? []

        if categories.isEmpty {
            Category.defaults.forEach(modelContext.insert)
            try? modelContext.save()
            return
        }

        // The app must always have a safe fallback, even if the user deleted
        // every other category.
        CategoryService().ensureFallbackCategory(in: categories, modelContext: modelContext)
    }
}
