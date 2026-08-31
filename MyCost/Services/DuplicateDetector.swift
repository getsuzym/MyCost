import Foundation

struct DuplicateDetector {
    func fingerprint(
        merchantName: String,
        amount: Decimal,
        transactionDate: Date,
        status: TransactionStatus
    ) -> String {
        let normalizedMerchant = merchantName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        let day = Calendar.current.startOfDay(for: transactionDate).timeIntervalSince1970
        return "\(normalizedMerchant)|\(amount)|\(Int(day))|\(status.rawValue)"
    }

    func markDuplicates(_ transactions: [Transaction]) {
        var seenFingerprints: Set<String> = []

        for transaction in transactions {
            let fingerprint = fingerprint(
                merchantName: transaction.merchantName,
                amount: transaction.amount,
                transactionDate: transaction.transactionDate,
                status: transaction.status
            )

            if seenFingerprints.contains(fingerprint) {
                transaction.duplicateState = .possibleDuplicate
            } else {
                transaction.duplicateState = .unique
                seenFingerprints.insert(fingerprint)
            }
        }
    }
}
