import Combine
import Foundation

enum OCRReviewField {
    case account
    case date
    case merchant
    case amount
    case status
}

enum DuplicateReviewDecision: String, CaseIterable, Identifiable {
    case review
    case merge
    case keepBoth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .review: "Review"
        case .merge: "Merge"
        case .keepBoth: "Keep Both"
        }
    }
}

struct OCRTransactionDraft: Identifiable, Equatable {
    let id: UUID
    let sourceText: String
    let originalOCRText: String
    let validationFlags: Set<TransactionCandidateValidationFlag>
    let confidence: TransactionCandidateFieldConfidences

    var accountName: String
    var transactionDate: Date
    var merchantName: String
    var amountText: String
    var status: TransactionStatus
    var selectedCategoryID: UUID?
    var isSelected: Bool
    var duplicateDecision: DuplicateReviewDecision
    var duplicateMatchID: UUID?
    var duplicateSummary: String?

    init(candidate: TransactionCandidate, referenceDate: Date = .now) {
        id = candidate.id
        sourceText = candidate.sourceText
        originalOCRText = candidate.originalOCRText
        validationFlags = candidate.validationFlags
        confidence = candidate.confidence
        accountName = "Default"
        transactionDate = candidate.detectedDate ?? referenceDate
        merchantName = candidate.rawMerchantDescription
        amountText = candidate.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        status = candidate.status == .pending ? .pending : .posted
        selectedCategoryID = nil
        isSelected = true
        duplicateDecision = .review
        duplicateMatchID = nil
        duplicateSummary = nil
    }

    var trimmedMerchantName: String {
        merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAccountName: String {
        let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Default" : trimmed
    }

    var parsedAmount: Decimal? {
        Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var canImport: Bool {
        !trimmedMerchantName.isEmpty && parsedAmount != nil
    }

    func isUncertain(_ field: OCRReviewField) -> Bool {
        switch field {
        case .account:
            accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .date:
            validationFlags.contains(.missingDate) ||
                validationFlags.contains(.ambiguousDate) ||
                validationFlags.contains(.inferredYear) ||
                confidence.date < 0.8
        case .merchant:
            validationFlags.contains(.missingMerchantDescription) ||
                validationFlags.contains(.possibleNonTransactionLine) ||
                confidence.merchantDescription < 0.75
        case .amount:
            validationFlags.contains(.missingAmount) ||
                validationFlags.contains(.multipleAmounts) ||
                confidence.amount < 0.8
        case .status:
            validationFlags.contains(.missingStatus) ||
                confidence.status < 0.8
        }
    }

    func duplicateSnapshot() -> DuplicateTransactionSnapshot? {
        guard let amount = parsedAmount, !trimmedMerchantName.isEmpty else { return nil }
        return DuplicateTransactionSnapshot(
            id: id,
            accountName: trimmedAccountName,
            merchantName: trimmedMerchantName,
            originalDescription: sourceText,
            amount: amount,
            transactionDate: transactionDate,
            status: status
        )
    }
}

final class OCRTransactionReviewStore: ObservableObject {
    @Published var drafts: [OCRTransactionDraft] = []

    var selectedCount: Int {
        drafts.filter(\.isSelected).count
    }

    var importableSelectedCount: Int {
        drafts.filter { $0.isSelected && $0.canImport }.count
    }

    func replaceCandidates(_ candidates: [TransactionCandidate], referenceDate: Date = .now) {
        drafts = candidates.map { OCRTransactionDraft(candidate: $0, referenceDate: referenceDate) }
    }

    func removeDraft(id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    func removeDrafts(ids: Set<UUID>) {
        drafts.removeAll { ids.contains($0.id) }
    }

    func clear() {
        drafts = []
    }
}
