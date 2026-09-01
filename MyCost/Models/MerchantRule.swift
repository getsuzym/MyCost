import Foundation
import SwiftData

@Model
final class MerchantRule {
    @Attribute(.unique) var id: UUID
    var matchText: String
    var normalizedMatchText: String
    var displayName: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    var category: Category?

    init(
        id: UUID = UUID(),
        matchText: String,
        normalizedMatchText: String? = nil,
        displayName: String,
        isEnabled: Bool = true,
        category: Category? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.matchText = matchText
        self.normalizedMatchText = normalizedMatchText ?? MerchantRuleNormalizer.normalizedMerchantKey(for: matchText)
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
