import Combine
import Foundation
import UIKit

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
    let parsedMerchantName: String
    let sourceText: String
    let originalOCRText: String
    let validationFlags: Set<TransactionCandidateValidationFlag>
    let confidence: TransactionCandidateFieldConfidences
    /// The screenshot this draft was detected from (batch import).
    let sourceScreenshotID: UUID?

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
    var shouldRememberMerchantRule: Bool

    init(candidate: TransactionCandidate, referenceDate: Date = .now) {
        id = candidate.id
        parsedMerchantName = candidate.rawMerchantDescription
        sourceText = candidate.sourceText
        originalOCRText = candidate.originalOCRText
        validationFlags = candidate.validationFlags
        confidence = candidate.confidence
        sourceScreenshotID = candidate.sourceScreenshotID
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
        shouldRememberMerchantRule = false
    }

    mutating func applyMerchantRule(_ application: MerchantRuleApplication) {
        merchantName = application.displayName
        if let category = application.category {
            selectedCategoryID = category.id
        }
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
                validationFlags.contains(.ambiguousLayout) ||
                confidence.merchantDescription < 0.75
        case .amount:
            validationFlags.contains(.missingAmount) ||
                validationFlags.contains(.multipleAmounts) ||
                validationFlags.contains(.ambiguousLayout) ||
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

/// Summary of the batch that produced the current review session, so the
/// Review screen can show "18 transactions detected from 5 screenshots" and
/// name any screenshots that failed to process.
struct OCRBatchSessionInfo: Equatable {
    var screenshotCount: Int = 0
    var failedScreenshots: [String] = []

    var isBatch: Bool { screenshotCount > 1 || !failedScreenshots.isEmpty }
}

final class OCRTransactionReviewStore: ObservableObject {
    @Published var drafts: [OCRTransactionDraft] = []

    /// Downscaled preview images keyed by `sourceScreenshotID`, so the Review
    /// screen can show which screenshot a transaction came from. Full-resolution
    /// images are never retained here.
    @Published private(set) var sourceThumbnails: [UUID: UIImage] = [:]

    /// Metadata about the batch import that produced `drafts`.
    @Published private(set) var batchInfo = OCRBatchSessionInfo()

    var selectedCount: Int {
        drafts.filter(\.isSelected).count
    }

    var importableSelectedCount: Int {
        drafts.filter { $0.isSelected && $0.canImport }.count
    }

    func replaceCandidates(_ candidates: [TransactionCandidate], referenceDate: Date = .now) {
        drafts = candidates.map { OCRTransactionDraft(candidate: $0, referenceDate: referenceDate) }
    }

    func replaceCandidates(_ candidates: [TransactionCandidate], merchantRules: [MerchantRule], referenceDate: Date = .now) {
        let service = MerchantRuleService()
        drafts = candidates.map { candidate in
            var draft = OCRTransactionDraft(candidate: candidate, referenceDate: referenceDate)
            if let application = service.application(for: candidate.sourceText, rules: merchantRules) {
                draft.applyMerchantRule(application)
            }
            return draft
        }
    }

    /// Installs the results of a batch screenshot import as one review session:
    /// the combined candidates (already tagged with `sourceScreenshotID`), the
    /// per-screenshot preview thumbnails, and the batch summary metadata.
    func replaceBatch(
        candidates: [TransactionCandidate],
        thumbnails: [UUID: UIImage],
        info: OCRBatchSessionInfo,
        merchantRules: [MerchantRule],
        referenceDate: Date = .now
    ) {
        replaceCandidates(candidates, merchantRules: merchantRules, referenceDate: referenceDate)
        sourceThumbnails = thumbnails
        batchInfo = info
    }

    func selectAll() {
        for index in drafts.indices where drafts[index].canImport {
            drafts[index].isSelected = true
        }
    }

    func deselectAll() {
        for index in drafts.indices {
            drafts[index].isSelected = false
        }
    }

    func sourceThumbnail(for draft: OCRTransactionDraft) -> UIImage? {
        guard let id = draft.sourceScreenshotID else { return nil }
        return sourceThumbnails[id]
    }

    func removeDraft(id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    /// Applies a confirmed AI (or rule) categorization onto a draft and marks it
    /// to be remembered as a `MerchantRule` when the batch is saved. The user
    /// can still edit the fields afterwards — corrections are captured at save.
    func applyCategorization(to id: UUID, merchantName: String, categoryID: UUID?) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            drafts[index].merchantName = trimmed
        }
        if let categoryID {
            drafts[index].selectedCategoryID = categoryID
        }
        drafts[index].shouldRememberMerchantRule = true
    }

    func removeDrafts(ids: Set<UUID>) {
        drafts.removeAll { ids.contains($0.id) }
    }

    func flagDuplicates(
        existingTransactions: [DuplicateTransactionSnapshot],
        coordinator: OCRTransactionImportCoordinator = OCRTransactionImportCoordinator()
    ) -> OCRDuplicateScanResult {
        coordinator.flagDuplicateDrafts(
            drafts: &drafts,
            existingTransactions: existingTransactions
        )
    }

    func clear() {
        drafts = []
        sourceThumbnails = [:]
        batchInfo = OCRBatchSessionInfo()
    }
}
