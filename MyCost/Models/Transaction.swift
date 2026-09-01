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
