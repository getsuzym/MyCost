import Foundation
import SwiftData

@Model
final class RecurringPayment {
    @Attribute(.unique) var id: UUID
    var merchantName: String
    var expectedAmount: Decimal
    var frequency: RecurrenceFrequency
    var nextExpectedDate: Date?
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    var category: Category?

    @Relationship(deleteRule: .nullify, inverse: \Transaction.recurringPayment)
    var transactions: [Transaction] = []

    init(
        id: UUID = UUID(),
        merchantName: String,
        expectedAmount: Decimal,
        frequency: RecurrenceFrequency = .monthly,
        nextExpectedDate: Date? = nil,
        isActive: Bool = true,
        category: Category? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.merchantName = merchantName
        self.expectedAmount = expectedAmount
        self.frequency = frequency
        self.nextExpectedDate = nextExpectedDate
        self.isActive = isActive
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
