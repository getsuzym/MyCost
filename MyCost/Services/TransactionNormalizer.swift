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
    /// Consistent spending value used by analytics: positive = spending,
    /// negative = a refund/credit that *reduces* spending, zero = not spending.
    /// Only meaningful when `countsAsSpending` is true.
    var normalizedAmount: Decimal
    var direction: TransactionDirection
    /// Whether this transaction should be included in spending totals at all.
    /// Payments, transfers, deposits, and payroll are `false`.
    var countsAsSpending: Bool
    /// The sign/description combination was unusual for the account type — the
    /// UI should ask the user to confirm.
    var needsReview: Bool
}

/// Turns a bank-displayed signed amount into a consistent spending value using
/// the account type plus keyword cues in the description. Never blindly flips
/// every amount — an amount whose sign already matches the expected convention
/// for its account type is taken at face value.
struct TransactionNormalizer {
    func normalize(
        originalAmount: Decimal,
        accountType: AccountType,
        description: String
    ) -> NormalizedTransaction {
        let text = description.lowercased()
        let paymentLike = Self.matches(text, Self.paymentKeywords)
        let refundLike = Self.matches(text, Self.refundKeywords)
        let incomeLike = Self.matches(text, Self.incomeKeywords)
        let isPositive = originalAmount > 0
        let isNegative = originalAmount < 0
        let magnitude = abs(originalAmount)

        switch accountType {
        case .creditCard:
            if originalAmount == 0 {
                return NormalizedTransaction(normalizedAmount: 0, direction: .unknown, countsAsSpending: false, needsReview: false)
            }
            if isPositive {
                // Purchases are shown positive on a credit card.
                // A positive amount that reads like a refund is contradictory.
                return NormalizedTransaction(
                    normalizedAmount: magnitude,
                    direction: .debit,
                    countsAsSpending: true,
                    needsReview: refundLike || paymentLike
                )
            }
            // Negative on a credit card: a payment, a refund/credit, or unclear.
            if paymentLike {
                return NormalizedTransaction(normalizedAmount: 0, direction: .credit, countsAsSpending: false, needsReview: false)
            }
            if refundLike {
                // A refund reduces spending.
                return NormalizedTransaction(normalizedAmount: -magnitude, direction: .credit, countsAsSpending: true, needsReview: false)
            }
            return NormalizedTransaction(normalizedAmount: 0, direction: .credit, countsAsSpending: false, needsReview: true)

        case .debit:
            if originalAmount == 0 {
                return NormalizedTransaction(normalizedAmount: 0, direction: .unknown, countsAsSpending: false, needsReview: false)
            }
            if isNegative {
                // Purchases/withdrawals are shown negative on a chequing account.
                return NormalizedTransaction(
                    normalizedAmount: magnitude,
                    direction: .debit,
                    countsAsSpending: true,
                    needsReview: incomeLike
                )
            }
            // Positive on debit: a deposit / payroll (income), a refund, or unclear.
            if incomeLike {
                return NormalizedTransaction(normalizedAmount: 0, direction: .credit, countsAsSpending: false, needsReview: false)
            }
            if refundLike {
                return NormalizedTransaction(normalizedAmount: -magnitude, direction: .credit, countsAsSpending: true, needsReview: false)
            }
            return NormalizedTransaction(normalizedAmount: 0, direction: .credit, countsAsSpending: false, needsReview: true)

        case .other:
            if originalAmount == 0 {
                return NormalizedTransaction(normalizedAmount: 0, direction: .unknown, countsAsSpending: false, needsReview: false)
            }
            if paymentLike {
                return NormalizedTransaction(normalizedAmount: 0, direction: .credit, countsAsSpending: false, needsReview: isPositive)
            }
            if incomeLike {
                return NormalizedTransaction(normalizedAmount: 0, direction: .credit, countsAsSpending: false, needsReview: isNegative)
            }
            if refundLike {
                return NormalizedTransaction(normalizedAmount: -magnitude, direction: .credit, countsAsSpending: true, needsReview: false)
            }
            if isNegative {
                // Best guess: negative = spending, but the convention is unknown.
                return NormalizedTransaction(normalizedAmount: magnitude, direction: .debit, countsAsSpending: true, needsReview: false)
            }
            // Positive with no cues on an unknown account type — ambiguous.
            return NormalizedTransaction(normalizedAmount: magnitude, direction: .debit, countsAsSpending: true, needsReview: true)
        }
    }

    // MARK: Keyword cues

    /// Deliberately narrow: only phrasings that clearly mean "a credit-card
    /// balance was paid off" (or its French form). A generic "bill payment",
    /// "pre-authorized payment", "autopay", or "e-transfer to <person>" is a
    /// real recurring expense (a phone bill, a mortgage, rent) and must **not**
    /// be zeroed out.
    private static let paymentKeywords = [
        "payment thank you", "payment - thank you", "thank you for your payment",
        "paiement - merci", "merci de votre paiement", "paiement recu - merci",
        "credit card payment", "cc payment", "payment received - thank",
        "pmt received - thank"
    ]

    private static let refundKeywords = [
        "refund", "return", "reversal", "reversed", "credit voucher", "chargeback",
        "cashback", "cash back", "adjustment credit", "rebate", "price adjustment"
    ]

    private static let incomeKeywords = [
        "payroll", "direct deposit", "direct dep", "dir dep", "deposit",
        "salary", "interest paid", "interest earned", "dividend", "gc deposit",
        "e-transfer from", "transfer from", "govt", "gov canada", "irs", "cra",
        "reimbursement"
    ]

    private static func matches(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
