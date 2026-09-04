import Foundation
import SwiftData

/// Restore / purge logic for `DeletedTransactionRecord`. `TrashBin` is what
/// creates the records (see `deleteTransactions`); this is what a "Recently
/// Deleted" screen does with them afterward.
struct RecentlyDeletedService {
    /// Records older than this are no longer shown or restorable — purged the
    /// next time `purgeExpired` runs (More → Manage → Recently Deleted's
    /// `.task`, once per appearance).
    static let retentionDays = 30

    static func isExpired(_ record: DeletedTransactionRecord, now: Date = .now, retentionDays: Int = retentionDays) -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return false }
        return record.deletedAt < cutoff
    }

    /// Days left before a record is purged (0 = purges today).
    static func daysRemaining(for record: DeletedTransactionRecord, now: Date = .now, retentionDays: Int = retentionDays) -> Int {
        guard let expiresAt = Calendar.current.date(byAdding: .day, value: retentionDays, to: record.deletedAt) else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: now, to: expiresAt).day ?? 0
        return max(0, days)
    }

    @MainActor
    func purgeExpired(_ records: [DeletedTransactionRecord], modelContext: ModelContext, now: Date = .now) {
        let expired = records.filter { Self.isExpired($0, now: now) }
        guard !expired.isEmpty else { return }
        expired.forEach(modelContext.delete)
        modelContext.saveOrLog("purge expired deleted-transaction records")
    }

    /// Re-creates a live `Transaction` from the archived record (re-linking
    /// its category by id if it still exists, and its tags by name — creating
    /// a tag that no longer exists, same as CSV import does), then removes the
    /// record. Splits and any recurring-series link are not restored (see
    /// `DeletedTransactionRecord`'s doc comment).
    @MainActor
    @discardableResult
    func restore(
        _ record: DeletedTransactionRecord,
        categories: [Category],
        tags: [Tag],
        modelContext: ModelContext
    ) -> Transaction {
        let category = record.categoryID.flatMap { id in categories.first { $0.id == id } }
        let tagService = TagService()
        var knownTags = tags
        let resolvedTags: [Tag] = record.tagNames.compactMap { name in
            guard let tag = tagService.upsert(name: name, in: knownTags, modelContext: modelContext) else { return nil }
            if !knownTags.contains(where: { $0.id == tag.id }) { knownTags.append(tag) }
            return tag
        }

        let transaction = Transaction(
            id: record.id,
            accountName: record.accountName,
            merchantName: record.merchantName,
            originalDescription: record.originalDescription,
            amount: record.amount,
            transactionDate: record.transactionDate,
            postedDate: record.postedDate,
            status: TransactionStatus(rawValue: record.statusRawValue) ?? .posted,
            isExcluded: record.isExcluded,
            excludedReason: record.excludedReason,
            isRecurring: record.isRecurring,
            isIncome: record.isIncome,
            note: record.note,
            normalizedAmount: record.normalizedAmount,
            transactionDirection: TransactionDirection(rawValue: record.transactionDirectionRawValue) ?? .unknown,
            accountType: AccountType(rawValue: record.accountTypeRawValue) ?? .other,
            countsAsSpending: record.countsAsSpending,
            category: category
        )
        modelContext.insert(transaction)
        if !resolvedTags.isEmpty { transaction.tags = resolvedTags }
        modelContext.delete(record)
        modelContext.saveOrLog("restore deleted transaction")
        return transaction
    }

    /// Permanently forgets a record without restoring it.
    @MainActor
    func deletePermanently(_ record: DeletedTransactionRecord, modelContext: ModelContext) {
        modelContext.delete(record)
        modelContext.saveOrLog("permanently delete a deleted-transaction record")
    }
}
