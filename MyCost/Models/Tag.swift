import Foundation
import SwiftData

/// A free-form label the user attaches to transactions, orthogonal to
/// `Category` (a transaction has exactly one category but any number of tags).
/// Many-to-many with `Transaction`; deleting a tag just detaches it (`.nullify`).
@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    /// Optional accent, `Color(hex:)` form. `nil` → the app accent.
    var colorHex: String?
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Transaction.tags)
    var transactions: [Transaction] = []

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}
