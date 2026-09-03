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
    /// The amount exactly as the bank displayed it, sign preserved. Kept for
    /// reference and for duplicate detection; analytics use `spendingAmount`.
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

    // MARK: Account-type-aware normalization (defaulted → lightweight migration)

    /// Consistent spending value: positive = spending, negative = refund/credit
    /// that reduces spending, zero = not spending. Only meaningful when
    /// `countsAsSpending`. Zero on legacy rows that predate normalization —
    /// `spendingAmount` falls back to `amount` for those.
    var normalizedAmount: Decimal = 0
    var transactionDirectionRawValue: String = TransactionDirection.unknown.rawValue
    var accountTypeRawValue: String = AccountType.other.rawValue
    /// Whether this transaction is counted in spending totals at all.
    var countsAsSpending: Bool = true
    /// The bank's sign/description was unusual for the account type; the user
    /// should confirm the direction.
    var needsDirectionReview: Bool = false

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
        normalizedAmount: Decimal? = nil,
        transactionDirection: TransactionDirection = .unknown,
        accountType: AccountType = .other,
        countsAsSpending: Bool = true,
        needsDirectionReview: Bool = false,
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
        self.normalizedAmount = normalizedAmount ?? amount
        self.transactionDirectionRawValue = transactionDirection.rawValue
        self.accountTypeRawValue = accountType.rawValue
        self.countsAsSpending = countsAsSpending
        self.needsDirectionReview = needsDirectionReview
        self.category = category
        self.recurringPayment = recurringPayment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The bank's original signed amount (alias for `amount`, kept for clarity
    /// at call sites that contrast it with `normalizedAmount`).
    var originalAmount: Decimal { amount }

    var transactionDirection: TransactionDirection {
        get { TransactionDirection(rawValue: transactionDirectionRawValue) ?? .unknown }
        set { transactionDirectionRawValue = newValue.rawValue }
    }

    var accountType: AccountType {
        get { AccountType(rawValue: accountTypeRawValue) ?? .other }
        set { accountTypeRawValue = newValue.rawValue }
    }

    /// The value analytics should sum. Zero when the transaction doesn't count
    /// as spending (payments, deposits). Rows that never went through
    /// `TransactionNormalizer` (legacy data, or a direct `amount` edit) have
    /// `transactionDirection == .unknown` and fall back to the raw `amount`.
    var spendingAmount: Decimal {
        guard countsAsSpending else { return 0 }
        if transactionDirection == .unknown { return amount }
        return normalizedAmount
    }

    /// Applies a `TransactionNormalizer` result to the stored fields.
    func applyNormalization(_ normalized: NormalizedTransaction, accountType: AccountType) {
        self.normalizedAmount = normalized.normalizedAmount
        self.transactionDirection = normalized.direction
        self.accountType = accountType
        self.countsAsSpending = normalized.countsAsSpending
        self.needsDirectionReview = normalized.needsReview
    }
}
