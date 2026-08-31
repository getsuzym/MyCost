import Foundation
import SwiftData

@Model
final class MerchantRule {
    @Attribute(.unique) var id: UUID
    var matchText: String
    var displayName: String
    var createdAt: Date
    var updatedAt: Date

    var category: Category?

    init(
        id: UUID = UUID(),
        matchText: String,
        displayName: String,
        category: Category? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.matchText = matchText
        self.displayName = displayName
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

