import Foundation

enum TransactionDirection: String, Codable, CaseIterable, Identifiable {
    /// Money out — a purchase / withdrawal.
    case debit
    /// Money in — a payment, refund, deposit, or credit.
    case credit
    /// Couldn't be determined; flagged for the user to confirm.
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .debit: "Money out"
        case .credit: "Money in"
        case .unknown: "Unknown"
        }
    }
}

/// The account-type-aware interpretation of one bank amount.
struct NormalizedTransaction: Equatable {
    /// Spending value used by analytics: positive = spending, negative = a
    /// refund/credit that *reduces* spending, zero = a zero-amount row.
    var normalizedAmount: Decimal
    var direction: TransactionDirection
    /// **Always `true`.** Every transaction counts toward spending by default;
    /// only the user removes one, via the editor's "Counts as spending" toggle.
    /// Kept on the struct so callers don't change shape.
    var countsAsSpending: Bool
    /// The sign/description combination looks like a payment, transfer or
    /// deposit — the editor shows a soft hint so the user can un-count it if
    /// they want. It does **not** exclude the transaction on its own.
    var needsReview: Bool
}

/// Turns a bank-displayed signed amount into a consistent spending value using
/// the account type plus a refund cue. Purchases become positive regardless of
/// the bank's sign convention; refunds become negative. Nothing is excluded
/// automatically — `countsAsSpending` is always `true`.
struct TransactionNormalizer {
    func normalize(
        originalAmount: Decimal,
        accountType: AccountType,
        description: String
    ) -> NormalizedTransaction {
        let text = description.lowercased()
        let refundLike = Self.matches(text, Self.refundKeywords)
        let magnitude = abs(originalAmount)

        if originalAmount == 0 {
            return NormalizedTransaction(normalizedAmount: 0, direction: .unknown, countsAsSpending: true, needsReview: false)
        }

        // A refund/credit reduces spending — the one automatic sign flip.
        if refundLike {
            return NormalizedTransaction(normalizedAmount: -magnitude, direction: .credit, countsAsSpending: true, needsReview: false)
        }

        // Everything else is spending at its magnitude. `direction` /
        // `needsReview` are informational hints for the editor — a sign that
        // doesn't match the account's convention (negative on a card, positive
        // on a chequing account) usually means a payment or deposit the user
        // may want to un-count. They never zero the row.
        switch accountType {
        case .creditCard:
            return NormalizedTransaction(
                normalizedAmount: magnitude,
                direction: originalAmount > 0 ? .debit : .credit,
                countsAsSpending: true,
                needsReview: originalAmount < 0
            )
        case .debit:
            return NormalizedTransaction(
                normalizedAmount: magnitude,
                direction: originalAmount < 0 ? .debit : .credit,
                countsAsSpending: true,
                needsReview: originalAmount > 0
            )
        case .other:
            return NormalizedTransaction(
                normalizedAmount: magnitude,
                direction: .debit,
                countsAsSpending: true,
                needsReview: false
            )
        }
    }

    // MARK: Keyword cues

    private static let refundKeywords = [
        "refund", "return", "reversal", "reversed", "credit voucher", "chargeback",
        "cashback", "cash back", "adjustment credit", "rebate", "price adjustment"
    ]

    private static func matches(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
