import Foundation
import SwiftData

@Model
final class RecurringPayment {
    @Attribute(.unique) var id: UUID
    var accountName: String
    var merchantName: String
    var expectedAmount: Decimal
    var frequency: RecurrenceFrequency
    var customIntervalDays: Int
    var nextExpectedDate: Date?
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    var category: Category?

    @Relationship(deleteRule: .nullify, inverse: \Transaction.recurringPayment)
    var transactions: [Transaction] = []

    init(
        id: UUID = UUID(),
        accountName: String = "Default",
        merchantName: String,
        expectedAmount: Decimal,
        frequency: RecurrenceFrequency = .monthly,
        customIntervalDays: Int = 30,
        nextExpectedDate: Date? = nil,
        isActive: Bool = true,
        category: Category? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accountName = accountName
        self.merchantName = merchantName
        self.expectedAmount = expectedAmount
        self.frequency = frequency
        self.customIntervalDays = customIntervalDays
        self.nextExpectedDate = nextExpectedDate
        self.isActive = isActive
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
