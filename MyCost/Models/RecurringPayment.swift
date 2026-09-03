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
    /// `.everyNMonths`: the month gap (2 = bi-monthly, 6 = semi-annual, …).
    var monthInterval: Int = 1
    /// `.nthWeekday` / `.nthBusinessDay`: 1…5 = first…fifth, -1 = last.
    var weekdayOrdinal: Int = 1
    /// `.nthWeekday`: `Calendar` weekday, 1 = Sunday … 7 = Saturday.
    var weekday: Int = 2
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
        monthInterval: Int = 1,
        weekdayOrdinal: Int = 1,
        weekday: Int = 2,
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
        self.monthInterval = monthInterval
        self.weekdayOrdinal = weekdayOrdinal
        self.weekday = weekday
        self.nextExpectedDate = nextExpectedDate
        self.isActive = isActive
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension RecurringPayment {
    /// The date the occurrence cadence is phased from: the most recent linked
    /// transaction, else the stored `nextExpectedDate`, else `createdAt`.
    var occurrenceAnchor: Date {
        if let latest = transactions.map(\.transactionDate).max() {
            return latest
        }
        return nextExpectedDate ?? createdAt
    }

    /// The concrete schedule this series follows — the one place occurrence
    /// dates and the human-readable cadence label are generated.
    func schedule(calendar: Calendar = Calendar(identifier: .gregorian)) -> RecurrenceSchedule {
        RecurrenceSchedule(
            frequency: frequency,
            anchorDate: occurrenceAnchor,
            customIntervalDays: customIntervalDays,
            monthInterval: monthInterval,
            weekdayOrdinal: weekdayOrdinal,
            weekday: weekday,
            calendar: calendar
        )
    }
}
