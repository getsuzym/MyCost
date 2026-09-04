import Foundation
import SwiftData

/// One portion of a transaction whose spending is divided across categories —
/// e.g. a single $120 Costco charge split into $80 Groceries + $40 Household.
/// Owned by its `Transaction` (`.cascade` — a split has no meaning without its
/// parent); its `category` is a plain to-one reference (`.nullify` default, like
/// `Transaction.category`) so deleting a category never deletes a split.
@Model
final class TransactionSplit {
    @Attribute(.unique) var id: UUID
    /// Positive magnitude, in the same units as `Transaction.spendingAmount`.
    /// The sum of a transaction's splits must equal its `spendingAmount` — the
    /// editor enforces this; `Transaction.isSplitBalanced` re-checks it.
    var amount: Decimal
    var note: String
    var category: Category?
    var transaction: Transaction?

    init(
        id: UUID = UUID(),
        amount: Decimal,
        note: String = "",
        category: Category? = nil,
        transaction: Transaction? = nil
    ) {
        self.id = id
        self.amount = amount
        self.note = note
        self.category = category
        self.transaction = transaction
    }
}
