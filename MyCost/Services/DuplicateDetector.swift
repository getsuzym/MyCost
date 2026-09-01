import Foundation

enum DuplicateMatchConfidence: String, Codable, Equatable {
    case none
    case medium
    case high
}

enum DuplicateMatchReason: String, Codable, Hashable {
    case differentAccount
    case exactOriginalDescription
    case exactMerchant
    case similarMerchant
    case sameAmount
    case sameTransactionDate
    case pendingToPostedDateWindow
    case sameStatus
}

struct DuplicateTransactionSnapshot: Identifiable, Equatable {
    let id: UUID
    var accountName: String
    var merchantName: String
    var originalDescription: String
    var amount: Decimal
    var transactionDate: Date
    var postedDate: Date?
    var status: TransactionStatus

    init(
        id: UUID = UUID(),
        accountName: String,
        merchantName: String,
        originalDescription: String = "",
        amount: Decimal,
        transactionDate: Date,
        postedDate: Date? = nil,
        status: TransactionStatus
    ) {
        self.id = id
        self.accountName = accountName
        self.merchantName = merchantName
        self.originalDescription = originalDescription
        self.amount = amount
        self.transactionDate = transactionDate
        self.postedDate = postedDate
        self.status = status
    }
}

struct DuplicateMatch: Identifiable, Equatable {
    let id = UUID()
    let incoming: DuplicateTransactionSnapshot
    let existing: DuplicateTransactionSnapshot
    let confidence: DuplicateMatchConfidence
    let reasons: Set<DuplicateMatchReason>
}

struct DuplicateMatchingService {
    private let calendar: Calendar
    private let pendingPostedWindowDays: Int

    init(calendar: Calendar = Calendar(identifier: .gregorian), pendingPostedWindowDays: Int = 4) {
        self.calendar = calendar
        self.pendingPostedWindowDays = pendingPostedWindowDays
    }

    func bestMatch(
        for incoming: DuplicateTransactionSnapshot,
        against existingTransactions: [DuplicateTransactionSnapshot]
    ) -> DuplicateMatch? {
        existingTransactions
            .compactMap { match(incoming, $0) }
            .sorted { lhs, rhs in
                score(lhs.confidence) > score(rhs.confidence)
            }
            .first
    }

    func highConfidenceDuplicate(
        for incoming: DuplicateTransactionSnapshot,
        against existingTransactions: [DuplicateTransactionSnapshot]
    ) -> DuplicateMatch? {
        bestMatch(for: incoming, against: existingTransactions.filter { $0.id != incoming.id })
            .flatMap { $0.confidence == .high ? $0 : nil }
    }

    func mediumConfidenceMatches(
        for incoming: DuplicateTransactionSnapshot,
        against existingTransactions: [DuplicateTransactionSnapshot]
    ) -> [DuplicateMatch] {
        existingTransactions
            .filter { $0.id != incoming.id }
            .compactMap { match(incoming, $0) }
            .filter { $0.confidence == .medium }
    }

    func markDuplicates(_ transactions: [Transaction]) {
        let snapshots = transactions.map(DuplicateTransactionSnapshot.init(transaction:))

        for transaction in transactions {
            let incoming = DuplicateTransactionSnapshot(transaction: transaction)
            if highConfidenceDuplicate(for: incoming, against: snapshots) != nil {
                transaction.duplicateState = .possibleDuplicate
            } else {
                transaction.duplicateState = .unique
            }
        }
    }

    func match(
        _ incoming: DuplicateTransactionSnapshot,
        _ existing: DuplicateTransactionSnapshot
    ) -> DuplicateMatch? {
        guard normalizedAccount(incoming.accountName) == normalizedAccount(existing.accountName) else {
            return nil
        }

        guard incoming.amount == existing.amount else {
            return nil
        }

        var reasons: Set<DuplicateMatchReason> = [.sameAmount]
        if isSameDay(incoming.transactionDate, existing.transactionDate) {
            reasons.insert(.sameTransactionDate)
        }
        if incoming.status == existing.status {
            reasons.insert(.sameStatus)
        }

        let exactOriginalDescription = hasExactOriginalDescription(incoming, existing)
        let exactMerchant = normalizedMerchant(incoming.merchantName) == normalizedMerchant(existing.merchantName)
        let similarMerchant = merchantSimilarity(incoming.merchantName, existing.merchantName) >= 0.78 ||
            originalDescriptionSimilarity(incoming, existing) >= 0.78
        let pendingPostedWindow = isPendingToPostedWindow(incoming, existing)

        if exactOriginalDescription {
            reasons.insert(.exactOriginalDescription)
        }
        if exactMerchant {
            reasons.insert(.exactMerchant)
        } else if similarMerchant {
            reasons.insert(.similarMerchant)
        }
        if pendingPostedWindow {
            reasons.insert(.pendingToPostedDateWindow)
        }

        if exactOriginalDescription && isSameDay(incoming.transactionDate, existing.transactionDate) && incoming.status == existing.status {
            return DuplicateMatch(incoming: incoming, existing: existing, confidence: .high, reasons: reasons)
        }

        if exactMerchant && isSameDay(incoming.transactionDate, existing.transactionDate) && incoming.status == existing.status &&
            incoming.originalDescription.isEmpty && existing.originalDescription.isEmpty {
            return DuplicateMatch(incoming: incoming, existing: existing, confidence: .high, reasons: reasons)
        }

        if pendingPostedWindow && (exactOriginalDescription || exactMerchant || similarMerchant) {
            return DuplicateMatch(incoming: incoming, existing: existing, confidence: .medium, reasons: reasons)
        }

        if isSameDay(incoming.transactionDate, existing.transactionDate) && similarMerchant {
            return DuplicateMatch(incoming: incoming, existing: existing, confidence: .medium, reasons: reasons)
        }

        return nil
    }

    private func isPendingToPostedWindow(
        _ lhs: DuplicateTransactionSnapshot,
        _ rhs: DuplicateTransactionSnapshot
    ) -> Bool {
        guard lhs.status != rhs.status else { return false }

        let pending = lhs.status == .pending ? lhs : rhs
        let posted = lhs.status == .posted ? lhs : rhs
        let pendingDate = calendar.startOfDay(for: pending.transactionDate)
        let postedDate = calendar.startOfDay(for: posted.postedDate ?? posted.transactionDate)

        guard let days = calendar.dateComponents([.day], from: pendingDate, to: postedDate).day else {
            return false
        }

        return days >= 0 && days <= pendingPostedWindowDays
    }

    private func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    private func hasExactOriginalDescription(
        _ lhs: DuplicateTransactionSnapshot,
        _ rhs: DuplicateTransactionSnapshot
    ) -> Bool {
        let lhsDescription = normalizedDescription(lhs.originalDescription)
        let rhsDescription = normalizedDescription(rhs.originalDescription)
        return !lhsDescription.isEmpty && lhsDescription == rhsDescription
    }

    private func originalDescriptionSimilarity(
        _ lhs: DuplicateTransactionSnapshot,
        _ rhs: DuplicateTransactionSnapshot
    ) -> Double {
        let lhsDescription = lhs.originalDescription.isEmpty ? lhs.merchantName : lhs.originalDescription
        let rhsDescription = rhs.originalDescription.isEmpty ? rhs.merchantName : rhs.originalDescription
        return merchantSimilarity(lhsDescription, rhsDescription)
    }

    private func merchantSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(normalizedMerchant(lhs).split(separator: " ").map(String.init))
        let rhsTokens = Set(normalizedMerchant(rhs).split(separator: " ").map(String.init))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }

        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        let tokenScore = Double(intersection) / Double(union)
        let editScore = normalizedEditSimilarity(
            normalizedMerchant(lhs).replacingOccurrences(of: " ", with: ""),
            normalizedMerchant(rhs).replacingOccurrences(of: " ", with: "")
        )

        return max(tokenScore, editScore)
    }

    private func normalizedEditSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let distance = levenshtein(lhs, rhs)
        return 1 - (Double(distance) / Double(max(lhs.count, rhs.count)))
    }

    private func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs)
        let rhs = Array(rhs)
        var previous = Array(0...rhs.count)

        for (lhsIndex, lhsCharacter) in lhs.enumerated() {
            var current = [lhsIndex + 1]
            for (rhsIndex, rhsCharacter) in rhs.enumerated() {
                if lhsCharacter == rhsCharacter {
                    current.append(previous[rhsIndex])
                } else {
                    current.append(min(previous[rhsIndex], previous[rhsIndex + 1], current[rhsIndex]) + 1)
                }
            }
            previous = current
        }

        return previous[rhs.count]
    }

    private func normalizedAccount(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedDescription(_ description: String) -> String {
        description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func normalizedMerchant(_ merchant: String) -> String {
        merchant
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignoredMerchantTokens.contains($0) }
            .joined(separator: " ")
    }

    private var ignoredMerchantTokens: Set<String> {
        ["inc", "llc", "co", "store", "pos", "purchase", "card", "debit", "visa", "auth"]
    }

    private func score(_ confidence: DuplicateMatchConfidence) -> Int {
        switch confidence {
        case .none: 0
        case .medium: 1
        case .high: 2
        }
    }
}

extension DuplicateTransactionSnapshot {
    init(transaction: Transaction) {
        self.init(
            id: transaction.id,
            accountName: transaction.accountName,
            merchantName: transaction.merchantName,
            originalDescription: transaction.originalDescription,
            amount: transaction.amount,
            transactionDate: transaction.transactionDate,
            postedDate: transaction.postedDate,
            status: transaction.status
        )
    }
}
