import Foundation
import SwiftData

enum TransactionStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case posted

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum TransactionReviewState: String, Codable, CaseIterable, Identifiable {
    case needsReview
    case reviewed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsReview: "Needs Review"
        case .reviewed: "Reviewed"
        }
    }
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable {
    case none
    case weekly
    case biweekly
    case monthly
    case quarterly
    case yearly
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .weekly: "Weekly"
        case .biweekly: "Biweekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        case .custom: "Custom"
        }
    }
}

extension RecurrenceFrequency {
    var defaultIntervalDays: Int {
        switch self {
        case .none: 0
        case .weekly: 7
        case .biweekly: 14
        case .monthly: 30
        case .quarterly: 91
        case .yearly: 365
        case .custom: 30
        }
    }

    func nextDate(after date: Date, calendar: Calendar = Calendar(identifier: .gregorian), customIntervalDays: Int = 30) -> Date? {
        switch self {
        case .none:
            nil
        case .weekly:
            calendar.date(byAdding: .day, value: 7, to: date)
        case .biweekly:
            calendar.date(byAdding: .day, value: 14, to: date)
        case .monthly:
            calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly:
            calendar.date(byAdding: .month, value: 3, to: date)
        case .yearly:
            calendar.date(byAdding: .year, value: 1, to: date)
        case .custom:
            calendar.date(byAdding: .day, value: max(1, customIntervalDays), to: date)
        }
    }

    func monthlyMultiplier(customIntervalDays: Int = 30) -> Double {
        switch self {
        case .none:
            0
        case .weekly:
            52.0 / 12.0
        case .biweekly:
            26.0 / 12.0
        case .monthly:
            1
        case .quarterly:
            1.0 / 3.0
        case .yearly:
            1.0 / 12.0
        case .custom:
            30.4375 / Double(max(1, customIntervalDays))
        }
    }
}

enum DuplicateState: String, Codable, CaseIterable, Identifiable {
    case unique
    case possibleDuplicate
    case duplicateIgnored

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unique: "Unique"
        case .possibleDuplicate: "Possible Duplicate"
        case .duplicateIgnored: "Ignored"
        }
    }
}

@Model
final class Transaction {
    @Attribute(.unique) var id: UUID
    var accountName: String
    var merchantName: String
    var originalDescription: String
    var amount: Decimal
    var transactionDate: Date
    var postedDate: Date?
    var status: TransactionStatus
    var isExcluded: Bool
    var excludedReason: String
    var isRecurring: Bool
    var duplicateState: DuplicateState
    var note: String
    var createdAt: Date
    var updatedAt: Date

    var category: Category?
    var recurringPayment: RecurringPayment?

    init(
        id: UUID = UUID(),
        accountName: String = "Default",
        merchantName: String,
        originalDescription: String = "",
        amount: Decimal,
        transactionDate: Date,
        postedDate: Date? = nil,
        status: TransactionStatus = .posted,
        isExcluded: Bool = false,
        excludedReason: String = "",
        isRecurring: Bool = false,
        duplicateState: DuplicateState = .unique,
        note: String = "",
        category: Category? = nil,
        recurringPayment: RecurringPayment? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accountName = accountName
        self.merchantName = merchantName
        self.originalDescription = originalDescription.isEmpty ? merchantName : originalDescription
        self.amount = amount
        self.transactionDate = transactionDate
        self.postedDate = postedDate
        self.status = status
        self.isExcluded = isExcluded
        self.excludedReason = excludedReason
        self.isRecurring = isRecurring
        self.duplicateState = duplicateState
        self.note = note
        self.category = category
        self.recurringPayment = recurringPayment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
