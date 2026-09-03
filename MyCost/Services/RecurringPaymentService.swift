import Foundation
import SwiftData

/// Series-level operations for `RecurringPayment`. Kept separate from the views
/// so the "a recurring series is just a schedule — never the owner of a
/// transaction" rule lives in one place.
///
/// Transactions are independent of recurring series: `isRecurring` is a plain
/// per-transaction flag, and `recurringPayment` is only a soft link. Deleting a
/// series therefore removes *only* the series record — every transaction stays
/// in the store with its amount, date, category and `isRecurring` flag exactly
/// as they were.
@MainActor
struct RecurringPaymentService {
    func setActive(_ isActive: Bool, for payment: RecurringPayment, modelContext: ModelContext) throws {
        payment.isActive = isActive
        payment.updatedAt = .now
        try modelContext.save()
    }

    /// Removes the series. Linked transactions are unlinked (`recurringPayment`
    /// set to `nil`) but otherwise untouched — nothing else on the transaction
    /// changes, and none are deleted.
    func delete(_ payment: RecurringPayment, modelContext: ModelContext) throws {
        for transaction in payment.transactions {
            transaction.recurringPayment = nil
        }
        modelContext.delete(payment)
        try modelContext.save()
    }
}
