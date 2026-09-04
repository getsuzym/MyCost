import Foundation
import SwiftData

/// A recoverable snapshot of a transaction after `TrashBin`'s undo grace
/// period has elapsed — the live `Transaction` really is deleted (so it
/// disappears from every existing `@Query` without needing a `deletedAt`
/// filter threaded through the whole app), but enough of it is archived here
/// to restore it for `retentionDays` (default 30) before this record itself
/// is purged. Mirrors the flat-DTO shape `DataPortabilityService` already
/// uses for backup/restore.
///
/// Deliberately doesn't preserve everything: a restored transaction comes
/// back with its category and tags (re-linked by id/name, same as CSV
/// import) but never its splits or its recurring-series link — this is a
/// safety net for "I deleted the wrong thing a day ago", not a full-fidelity
/// undo, and restoring nested split/series data isn't worth the complexity
/// for that.
@Model
final class DeletedTransactionRecord {
    @Attribute(.unique) var id: UUID
    var accountName: String
    var merchantName: String
    var originalDescription: String
    var amount: Decimal
    var transactionDate: Date
    var postedDate: Date?
    var statusRawValue: String
    var isExcluded: Bool
    var excludedReason: String
    var isRecurring: Bool
    var isIncome: Bool
    var note: String
    var normalizedAmount: Decimal
    var transactionDirectionRawValue: String
    var accountTypeRawValue: String
    var countsAsSpending: Bool
    /// The category at the time of deletion, kept by both id (to re-link if
    /// it still exists) and name (shown even if it doesn't).
    var categoryID: UUID?
    var categoryName: String?
    var tagNames: [String]
    var deletedAt: Date

    init(
        id: UUID,
        accountName: String,
        merchantName: String,
        originalDescription: String,
        amount: Decimal,
        transactionDate: Date,
        postedDate: Date?,
        statusRawValue: String,
        isExcluded: Bool,
        excludedReason: String,
        isRecurring: Bool,
        isIncome: Bool,
        note: String,
        normalizedAmount: Decimal,
        transactionDirectionRawValue: String,
        accountTypeRawValue: String,
        countsAsSpending: Bool,
        categoryID: UUID?,
        categoryName: String?,
        tagNames: [String],
        deletedAt: Date
    ) {
        self.id = id
        self.accountName = accountName
        self.merchantName = merchantName
        self.originalDescription = originalDescription
        self.amount = amount
        self.transactionDate = transactionDate
        self.postedDate = postedDate
        self.statusRawValue = statusRawValue
        self.isExcluded = isExcluded
        self.excludedReason = excludedReason
        self.isRecurring = isRecurring
        self.isIncome = isIncome
        self.note = note
        self.normalizedAmount = normalizedAmount
        self.transactionDirectionRawValue = transactionDirectionRawValue
        self.accountTypeRawValue = accountTypeRawValue
        self.countsAsSpending = countsAsSpending
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.tagNames = tagNames
        self.deletedAt = deletedAt
    }

    convenience init(archiving transaction: Transaction, deletedAt: Date = .now) {
        self.init(
            id: transaction.id,
            accountName: transaction.accountName,
            merchantName: transaction.merchantName,
            originalDescription: transaction.originalDescription,
            amount: transaction.amount,
            transactionDate: transaction.transactionDate,
            postedDate: transaction.postedDate,
            statusRawValue: transaction.status.rawValue,
            isExcluded: transaction.isExcluded,
            excludedReason: transaction.excludedReason,
            isRecurring: transaction.isRecurring,
            isIncome: transaction.isIncome,
            note: transaction.note,
            normalizedAmount: transaction.normalizedAmount,
            transactionDirectionRawValue: transaction.transactionDirectionRawValue,
            accountTypeRawValue: transaction.accountTypeRawValue,
            countsAsSpending: transaction.countsAsSpending,
            categoryID: transaction.category?.id,
            categoryName: transaction.category?.name,
            tagNames: transaction.tags.map(\.name),
            deletedAt: deletedAt
        )
    }
}
