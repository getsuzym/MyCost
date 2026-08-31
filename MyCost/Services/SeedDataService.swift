import Foundation
import SwiftData

enum SeedDataService {
    @MainActor
    static func seedDefaultCategoriesIfNeeded(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Category>()
        let existingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        Category.defaults.forEach(modelContext.insert)
        try? modelContext.save()
    }
}
