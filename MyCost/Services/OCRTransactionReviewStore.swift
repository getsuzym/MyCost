import Combine
import Foundation
import UIKit

/// The draft fields the Review UI highlights for attention. Pending/Posted was
/// removed from the Review screen (it added no review value); `status` is still
/// on the draft and the imported `Transaction` for duplicate detection.
enum OCRReviewField {
    case account
    case date
    case merchant
    case amount
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

/// Why a draft has (or doesn't have) a category — drives the Review row's
/// rule-status indicator so rows needing attention stand out.
enum DraftCategorizationStatus: Equatable {
    /// A user `MerchantRule` matched and set the category.
    case ruleMatched
    /// Has a category the user picked (or a local suggestion applied).
    case categorized
    /// No category yet — needs the user's attention.
    case uncategorized

    var label: String {
        switch self {
        case .ruleMatched: "Rule matched"
        case .categorized: "Categorized"
        case .uncategorized: "Needs a category"
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
    /// Bank pending/posted metadata — kept for duplicate detection and stored on
    /// the imported `Transaction`, but no longer shown in the Review UI.
    var status: TransactionStatus
    var selectedCategoryID: UUID?
    var isSelected: Bool
    /// User-controlled recurring flag for this transaction (any category).
    var isRecurring: Bool
    /// "Also mark future transactions from this merchant as recurring."
    var markFutureRecurring: Bool
    var duplicateDecision: DuplicateReviewDecision
    var duplicateMatchID: UUID?
    var duplicateSummary: String?
    var shouldRememberMerchantRule: Bool
    /// The `MerchantRule` that auto-set this draft's category, if any.
    var appliedRuleID: UUID?
    /// The user changed the category away from what a rule / suggestion set.
    var didUserSetCategory: Bool

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
        isRecurring = false
        markFutureRecurring = false
        duplicateDecision = .review
        duplicateMatchID = nil
        duplicateSummary = nil
        shouldRememberMerchantRule = false
        appliedRuleID = nil
        didUserSetCategory = false
    }

    mutating func applyMerchantRule(_ application: MerchantRuleApplication) {
        merchantName = application.displayName
        if let category = application.category {
            selectedCategoryID = category.id
        }
        appliedRuleID = application.ruleID
        if application.isRecurring {
            isRecurring = true
        }
    }

    /// The rule-status indicator shown in the Review row.
    var categorizationStatus: DraftCategorizationStatus {
        if appliedRuleID != nil, !didUserSetCategory { return .ruleMatched }
        return selectedCategoryID == nil ? .uncategorized : .categorized
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
        }
    }

    /// A neutral draft the Review list can bind to for the brief window a row
    /// is being torn down after its draft was removed — avoids indexing a stale
    /// position into `drafts` (`ContiguousArrayBuffer` crash).
    static let placeholder = OCRTransactionDraft(
        candidate: TransactionCandidate(
            detectedDate: nil, rawMerchantDescription: "", amount: nil, status: nil,
            originalOCRText: "", sourceText: "",
            confidence: .empty, validationFlags: []
        )
    )

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

    /// A review session is "active" whenever there are drafts still on the
    /// bench. Drives the review banner / shortcut and the "import already in
    /// progress" prompt.
    var hasActiveSession: Bool { !drafts.isEmpty }

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

    /// Applies a deterministic (rule or known-merchant) categorization onto a
    /// draft. When `ruleID` is non-nil the draft is marked "Rule matched";
    /// otherwise it's a manual/known-merchant categorization.
    func applyCategorization(
        to id: UUID,
        merchantName: String,
        categoryID: UUID?,
        ruleID: UUID? = nil,
        isRecurring: Bool = false
    ) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            drafts[index].merchantName = trimmed
        }
        if let categoryID {
            drafts[index].selectedCategoryID = categoryID
        }
        if let ruleID {
            drafts[index].appliedRuleID = ruleID
            drafts[index].didUserSetCategory = false
        } else {
            drafts[index].didUserSetCategory = true
        }
        if isRecurring {
            drafts[index].isRecurring = true
        }
        drafts[index].shouldRememberMerchantRule = true
    }

    /// Record that the user picked a category by hand (drives the rule-status
    /// indicator: a rule-matched row becomes "Categorized" once overridden).
    func markCategoryUserSet(id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].didUserSetCategory = true
    }

    /// Clear a draft's rule attribution (e.g. after its rule was deleted).
    func clearAppliedRule(id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].appliedRuleID = nil
    }

    /// Whether `rule` matches the draft's merchant name, its original OCR
    /// (`sourceText`), or the parsed merchant.
    private func ruleMatches(_ rule: MerchantRule, _ draft: OCRTransactionDraft, _ service: MerchantRuleService) -> Bool {
        service.matches(rule, merchantName: draft.merchantName, originalDescription: draft.sourceText)
            || service.matches(rule, merchantName: draft.parsedMerchantName, originalDescription: draft.sourceText)
    }

    /// Applies `rule` to one draft if it matches — updating merchant/category/
    /// recurring and marking the row "Rule matched".
    @discardableResult
    func applyRule(_ rule: MerchantRule, toDraft id: UUID, service: MerchantRuleService = MerchantRuleService()) -> Bool {
        guard let index = drafts.firstIndex(where: { $0.id == id }), ruleMatches(rule, drafts[index], service) else { return false }
        drafts[index].applyMerchantRule(MerchantRuleApplication(displayName: rule.displayName, category: rule.category, rule: rule))
        drafts[index].didUserSetCategory = false
        return true
    }

    /// Ids of other drafts (not `excluding`) that `rule` also matches.
    func draftsMatching(_ rule: MerchantRule, excluding id: UUID, service: MerchantRuleService = MerchantRuleService()) -> [UUID] {
        drafts.filter { $0.id != id && ruleMatches(rule, $0, service) }.map(\.id)
    }

    /// Applies `rule` to every matching draft in the batch; returns the count.
    @discardableResult
    func applyRuleToBatch(_ rule: MerchantRule, service: MerchantRuleService = MerchantRuleService()) -> Int {
        var count = 0
        for index in drafts.indices where ruleMatches(rule, drafts[index], service) {
            drafts[index].applyMerchantRule(MerchantRuleApplication(displayName: rule.displayName, category: rule.category, rule: rule))
            drafts[index].didUserSetCategory = false
            count += 1
        }
        return count
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
