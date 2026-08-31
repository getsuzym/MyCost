import Foundation
import SwiftData

struct MerchantRuleService {
    @MainActor
    func renameMerchant(
        currentName: String,
        to displayName: String,
        transactions: [Transaction],
        category: Category?,
        modelContext: ModelContext
    ) {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty else { return }

        let rule = MerchantRule(matchText: currentName, displayName: trimmedDisplayName, category: category)
        modelContext.insert(rule)

        for transaction in transactions where transaction.merchantName == currentName {
            transaction.merchantName = trimmedDisplayName
            if let category {
                transaction.category = category
            }
            transaction.updatedAt = .now
        }

        try? modelContext.save()
    }
}
